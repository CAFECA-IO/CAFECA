"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { formatEther, hashMessage, type Hex } from "viem";
import { DEPLOYMENT, Req } from "@/lib/config";
import { preview, type Preview } from "@/lib/client";
import { runOp } from "@/lib/actions";
import { encode1271, execBatch, execCall } from "@/lib/userop";
import { signWithPasskey } from "@/lib/webauthn";
import {
  ALLOWED_SUMMARY_KINDS,
  guardCalls,
  guardTypedData,
  open,
  seal,
  validateRequest,
  type Box,
  type ChannelRequest,
  type ChannelResponse,
} from "@/lib/channel";
import { channelKey, getChannel, guardContext, markSeen, type ChannelRecord } from "@/lib/channel-store";
import { summaryLine } from "./card-provider";
import { useCardConfirm } from "./card-provider";
import { PasskeyIcon } from "./icons";
import { useNow } from "./signin-approve";
import { useWallet } from "./wallet-provider";
import { Badge, Button, Notice, Spinner, cx, errMsg, short } from "./ui";

type Analysis = { hash?: Hex; callData?: Hex; preview?: Preview; warnings: string[]; blocked?: string };
type State =
  | { phase: "loading" }
  | { phase: "error"; message: string }
  | { phase: "ready"; req: ChannelRequest; key: CryptoKey; a: Analysis }
  | { phase: "done"; ok: boolean; text: string };

const METHOD_LABEL = { sign_message: "簽署訊息", sign_typed_data: "簽署結構化資料（EIP-712）", send_calls: "執行鏈上操作" } as const;

/**
 * 簽章通道請求確認（規格 §15.8）
 * - 彈出視窗：通知 opener 已就緒，接收同源（通道網域）送來的密文
 * - 中繼：從 /api/channel 讀取密文
 * 解密後並列顯示「網站說明」與錢包自行解析的「實際內容」，使用者確認才簽。
 */
export function ChannelApprove({ channelId, requestId }: { channelId: string; requestId?: string }) {
  const { wallet } = useWallet();
  const w = wallet!;
  const confirmOnCard = useCardConfirm();
  const rec = useMemo(() => getChannel(w.address, channelId), [w.address, channelId]);
  const [st, setSt] = useState<State>({ phase: "loading" });
  const [busy, setBusy] = useState<"approve" | "reject" | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const boxId = useRef<string | null>(null);
  const mode = requestId ? "relay" : "popup";
  const now = useNow();

  // 取得並解開請求
  useEffect(() => {
    if (!rec) {
      if (mode === "popup" && window.opener) (window.opener as Window).postMessage({ type: "cafeca:channel-closed", v: 1, ch: channelId }, "*");
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setSt({ phase: "error", message: "找不到這個簽章通道：可能已過期、已關閉，或是在另一台裝置上開啟的。" });
      return;
    }
    let stop = false;
    const handle = async (box: Box) => {
      if (stop || box.ch !== rec.id) return;
      boxId.current = box.id;
      try {
        const key = await channelKey(rec);
        const req = validateRequest(await open<ChannelRequest>(key, box, "req"), box.id);
        if (rec.seen.includes(req.id)) throw new Error("這個請求已經處理過了");
        const a = await analyze(req, w.address);
        if (!stop) setSt({ phase: "ready", req, key, a });
      } catch (e) {
        if (stop) return;
        setSt({ phase: "error", message: errMsg(e) });
        await sendError(rec, box.id, "invalid_request", errMsg(e), mode).catch(() => undefined);
      }
    };

    if (mode === "relay") {
      fetch(`/api/channel?ch=${rec.id}&r=${requestId}`)
        .then((r) => (r.ok ? r.json() : Promise.reject(new Error("請求不存在或已處理（可能已過期）"))))
        .then((j: { box: Box }) => handle(j.box))
        .catch((e) => !stop && setSt({ phase: "error", message: errMsg(e) }));
      return () => {
        stop = true;
      };
    }

    const opener = window.opener as Window | null;
    if (!opener) {
      setSt({ phase: "error", message: "找不到原本的網站視窗，請回到網站重新操作。" });
      return;
    }
    const onMsg = (e: MessageEvent) => {
      if (e.origin !== rec.domain || e.source !== opener) return;
      const d = e.data as { type?: string; box?: Box };
      if (d?.type === "cafeca:channel-request" && d.box && !boxId.current) handle(d.box);
    };
    window.addEventListener("message", onMsg);
    opener.postMessage({ type: "cafeca:channel-ready", v: 1, ch: rec.id }, rec.domain);
    return () => {
      stop = true;
      window.removeEventListener("message", onMsg);
    };
  }, [rec, channelId, requestId, mode, w.address]);

  const respond = async (res: ChannelResponse, key: CryptoKey) => {
    const box = await seal(key, rec!.id, res.id, "res", res);
    await deliver(rec!, box, mode);
  };

  const approve = async () => {
    if (st.phase !== "ready") return;
    const { req, key, a } = st;
    setBusy("approve");
    setErr(null);
    try {
      let res: ChannelResponse;
      if (req.method === "send_calls") {
        const r = await runOp(w, a.callData!, confirmOnCard);
        res = { v: 1, id: req.id, result: { txHash: r.txHash, success: r.success } };
      } else {
        const { keyId, sig } = await signWithPasskey(a.hash!, w.passkeys);
        res = { v: 1, id: req.id, result: { signature: encode1271(DEPLOYMENT.keyring, keyId, sig) } };
      }
      markSeen(w.address, rec!.id, req.id);
      await respond(res, key);
      setSt({ phase: "done", ok: true, text: req.method === "send_calls" ? "已送出" : "已簽署" });
    } catch (e) {
      setErr(errMsg(e));
    } finally {
      setBusy(null);
    }
  };

  const reject = async () => {
    if (st.phase !== "ready") return;
    setBusy("reject");
    try {
      markSeen(w.address, rec!.id, st.req.id);
      await respond({ v: 1, id: st.req.id, error: "rejected" }, st.key);
    } finally {
      setBusy(null);
      setSt({ phase: "done", ok: false, text: "已拒絕" });
    }
  };

  const host = rec ? new URL(rec.domain).host : "";

  if (st.phase === "loading") {
    return (
      <div className="flex items-center justify-center gap-2 py-10 text-sm text-ink-3">
        <Spinner className="text-brand" /> 正在接收 {host} 的請求…
      </div>
    );
  }
  if (st.phase === "error") return <Notice tone="danger">{st.message}</Notice>;
  if (st.phase === "done") {
    return (
      <div className="space-y-2 py-4 text-center" data-testid="channel-done">
        <div className="text-4xl">{st.ok ? "✓" : "✕"}</div>
        <div className="text-lg font-semibold">{st.text}</div>
        <p className="text-sm text-ink-2">已通知 {host}，這個頁面可以關閉了。</p>
      </div>
    );
  }

  const { req, a } = st;
  const exp = Math.max(0, req.exp - now);
  return (
    <div className="space-y-4" data-testid="channel-approve">
      <div className="flex items-center justify-between gap-3">
        <div className="min-w-0">
          <div className="truncate font-mono text-lg font-semibold" data-testid="channel-domain">{host}</div>
          <div className="text-xs text-ink-3">{rec!.name ? `網站自稱「${rec!.name}」 · ` : ""}透過簽章通道請求</div>
        </div>
        <Badge tone={req.method === "send_calls" ? "warn" : "brand"}>{METHOD_LABEL[req.method]}</Badge>
      </div>

      <section className="rounded-xl border border-line bg-surface-2 px-3 py-2.5" data-testid="channel-description">
        <div className="mb-1 text-[11px] text-ink-3">網站說明（由網站提供，請與下方實際內容核對）</div>
        <div className="font-semibold">{req.description.title}</div>
        {req.description.detail && <p className="mt-1 whitespace-pre-wrap text-sm text-ink-2">{req.description.detail}</p>}
      </section>

      <section data-testid="channel-content">
        <div className="mb-1.5 text-xs font-medium text-ink-3">實際內容（由 CAFECA 錢包解析）</div>
        <Content req={req} a={a} />
      </section>

      {a.warnings.map((x) => (
        <Notice key={x} tone="danger">⚠ {x}</Notice>
      ))}
      {a.blocked && <Notice tone="danger">{a.blocked}</Notice>}
      {err && <Notice tone="danger">{err}</Notice>}

      <p className="text-center text-xs text-ink-3">
        以身分 <span className="font-mono">{short(w.address, 6)}</span> 簽署 · 請在 {Math.floor(exp / 60)}:{String(exp % 60).padStart(2, "0")} 內完成
      </p>
      <div className="grid grid-cols-2 gap-2">
        <Button variant="secondary" onClick={reject} busy={busy === "reject"} disabled={!!busy} testId="channel-reject">拒絕</Button>
        <Button onClick={approve} busy={busy === "approve"} disabled={!!busy || !!a.blocked} testId="channel-approve-btn">
          <PasskeyIcon className="size-5" /> {req.method === "send_calls" ? (a.preview?.req === Req.MASTER ? "以卡片確認" : "確認執行") : "簽署"}
        </Button>
      </div>
    </div>
  );
}

async function analyze(req: ChannelRequest, account: `0x${string}`): Promise<Analysis> {
  const g = guardContext(account);
  if (req.method === "sign_message") return { hash: hashMessage(req.params.message!), warnings: [] };
  if (req.method === "sign_typed_data") return guardTypedData(req.params.typedData!, g);
  const calls = req.params.calls!;
  guardCalls(calls, g);
  const execs = calls.map((c) => ({ target: c.to, value: c.value ? BigInt(c.value) : 0n, data: c.data ?? ("0x" as Hex) }));
  const callData = execs.length === 1 ? execCall(execs[0].target, execs[0].data, execs[0].value) : execBatch(execs);
  const pv = await preview(account, callData);
  const warnings: string[] = [];
  let blocked: string | undefined;
  if (pv.summaries.some((s) => !ALLOWED_SUMMARY_KINDS.includes(s.kind))) blocked = "這筆操作包含網站不允許要求的項目（例如變更金鑰或通道），錢包已封鎖。";
  if (pv.req === Req.REJECT) blocked ??= await rejectReason(execs.reduce((t, e) => t + e.value, 0n));
  if (pv.summaries.some((s) => s.kind === 2)) warnings.push("包含代幣授權：對方之後可以不經你確認就動用授權的額度。");
  if (pv.summaries.some((s) => s.kind === 0)) warnings.push("包含錢包無法解讀的合約呼叫，請確認你信任這個網站。");
  if (execs.some((e) => e.value > 0n)) warnings.push("這筆操作會轉出 BOLT。");
  return { callData, preview: pv, warnings, blocked };
}

/** 被合約拒絕的原因：轉出 BOLT 而帳戶還沒有 BOLT 額度時，指引到錢包開啟 */
async function rejectReason(value: bigint): Promise<string> {
  if (value > 0n) {
    const n = await fetch("/api/limits/native").then((r) => (r.ok ? r.json() : null)).catch(() => null);
    if (n && !n.enabled) return "你的帳戶還沒有開啟 BOLT 轉帳額度，所以不能轉出 BOLT。請到「錢包」開啟 BOLT 轉帳後再回到網站重試。";
    if (n) {
      const left = BigInt(n.daily) - BigInt(n.spent);
      if (value > BigInt(n.perTx)) return `這筆要轉出 ${formatEther(value)} BOLT，超過單筆上限 ${formatEther(BigInt(n.perTx))} BOLT。`;
      if (value > left) return `這筆要轉出 ${formatEther(value)} BOLT，超過今天剩餘的 BOLT 額度 ${formatEther(left > 0n ? left : 0n)} BOLT。`;
    }
  }
  return "這筆操作目前不被允許：可能超過單筆或每日額度。";
}

async function deliver(rec: ChannelRecord, box: Box, mode: "popup" | "relay") {
  if (mode === "popup") {
    const opener = window.opener as Window | null;
    if (!opener) throw new Error("原本的網站視窗已關閉");
    opener.postMessage({ type: "cafeca:channel-response", v: 1, box }, rec.domain);
    setTimeout(() => window.close(), 300);
    return;
  }
  const r = await fetch("/api/channel", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ op: "reply", box }) });
  if (!r.ok) throw new Error("回應送出失敗");
}

async function sendError(rec: ChannelRecord, id: string, error: ChannelResponse["error"], message: string, mode: "popup" | "relay") {
  const key = await channelKey(rec);
  const box = await seal(key, rec.id, id, "res", { v: 1, id, error, message } satisfies ChannelResponse);
  if (mode === "popup") {
    (window.opener as Window | null)?.postMessage({ type: "cafeca:channel-response", v: 1, box }, rec.domain);
  } else {
    await fetch("/api/channel", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ op: "reply", box }) });
  }
}

function Content({ req, a }: { req: ChannelRequest; a: Analysis }) {
  if (req.method === "sign_message") {
    return (
      <pre className="max-h-60 overflow-auto whitespace-pre-wrap break-words rounded-xl border border-line px-3 py-2 font-sans text-sm" data-testid="channel-message">
        {req.params.message}
      </pre>
    );
  }
  if (req.method === "sign_typed_data") {
    const td = req.params.typedData!;
    const dom = (td.domain ?? {}) as Record<string, unknown>;
    return (
      <div className="space-y-2 rounded-xl border border-line px-3 py-2 text-sm">
        <KV k="類型" v={String(td.primaryType)} />
        {["name", "version", "chainId", "verifyingContract"].filter((k) => dom[k] !== undefined).map((k) => (
          <KV key={k} k={{ name: "應用名稱", version: "版本", chainId: "鏈 ID", verifyingContract: "合約" }[k]!} v={String(dom[k])} mono={k === "verifyingContract"} />
        ))}
        <div className="border-t border-line pt-2">
          <Tree value={td.message} />
        </div>
      </div>
    );
  }
  const pv = a.preview;
  return (
    <div className="space-y-2">
      <ul className="divide-y divide-line rounded-xl border border-line text-sm">
        {(pv?.summaries ?? []).map((s, i) => {
          const l = summaryLine(s);
          return (
            <li key={i} className="px-3 py-2">
              <div className={cx("font-medium", l.warn && "text-danger")}>{l.title}</div>
              {l.detail && <div className="text-xs text-ink-3">{l.detail}</div>}
            </li>
          );
        })}
      </ul>
      <details className="text-xs text-ink-3">
        <summary className="cursor-pointer">原始呼叫資料（{req.params.calls!.length} 筆）</summary>
        <ul className="mt-1 space-y-1 font-mono">
          {req.params.calls!.map((c, i) => (
            <li key={i} className="break-all">
              → {c.to}
              {c.value && c.value !== "0" ? ` · value ${c.value}` : ""} · {c.data && c.data !== "0x" ? `${c.data.slice(0, 10)}…（${(c.data.length - 2) / 2} bytes）` : "無資料"}
            </li>
          ))}
        </ul>
      </details>
      {pv?.req === Req.MASTER && <Notice>金額超過每日額度內的免卡範圍，需要以 CAFECA 實體卡確認。</Notice>}
      <p className="text-[11px] text-ink-3">gas 由平台贊助；額度與實體卡規則與你自己操作時相同。</p>
    </div>
  );
}

function KV({ k, v, mono }: { k: string; v: string; mono?: boolean }) {
  return (
    <div className="flex justify-between gap-3">
      <span className="shrink-0 text-ink-3">{k}</span>
      <span className={cx("min-w-0 break-all text-right", mono && "font-mono text-xs")}>{v}</span>
    </div>
  );
}

function Tree({ value, depth = 0 }: { value: unknown; depth?: number }) {
  if (value === null || typeof value !== "object") return <span className="break-all">{String(value)}</span>;
  if (depth > 4) return <span className="text-ink-3">…</span>;
  const entries = Array.isArray(value) ? value.map((v, i) => [String(i), v] as const) : Object.entries(value as Record<string, unknown>);
  return (
    <div className={cx("space-y-1", depth > 0 && "border-l border-line pl-2")}>
      {entries.map(([k, v]) => (
        <div key={k} className={cx(typeof v === "object" && v !== null ? "" : "flex justify-between gap-3")}>
          <span className="shrink-0 text-ink-3">{k}</span>
          {typeof v === "object" && v !== null ? <Tree value={v} depth={depth + 1} /> : <span className="min-w-0 break-all text-right">{String(v)}</span>}
        </div>
      ))}
    </div>
  );
}
