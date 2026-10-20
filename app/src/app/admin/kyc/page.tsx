"use client";

import { useCallback, useEffect, useState, type ReactNode } from "react";
import { AdminLogin, adminCall as call } from "@/components/admin-login";
import { Badge, Button, Notice, Panel, Spinner, cx, errMsg, inputCls, short } from "@/components/ui";

type Check = { ok: boolean; detail: string };
type Case = {
  account: string;
  id: string;
  purpose: "onboard" | "recover";
  createdAt: number;
  status: string;
  checks: Record<string, Check>;
  scores?: Record<string, unknown>;
  fields?: Record<string, string | undefined> | null;
  review?: { by: string; at: number; decision: string; note?: string };
  corrections?: { by: string; at: number; fields: string[]; note: string }[];
  result?: { txHash?: string; recoveryTx?: string; error?: string };
};

const CHECK_LABEL: Record<string, string> = {
  challengeOrder: "動作順序（裝置回報）",
  actionTiming: "動作時間（裝置回報）",
  ocr: "證件 OCR",
  fields: "欄位合理性",
  backSide: "證件反面",
  idFace: "證件人像",
  liveness: "活體動作（伺服器重算）",
  singleFace: "單一人臉",
  speech: "念數字（語音辨識）",
  faceMatch: "人臉比對",
  duplicate: "證號重複",
  sameSubject: "與開戶時同一人",
  models: "模型",
  pipeline: "後台錯誤",
  decision: "決策",
  prototype: "原型放行",
};
const FIELD_LABEL: Record<string, string> = { name: "姓名", birthday: "出生日期", sex: "性別", docType: "證件類型", issueDate: "發證日期", nationality: "國籍", idNumberHash: "統一編號 HMAC" };
const STATUS_TONE: Record<string, "warn" | "ok" | "danger" | "neutral"> = { review: "warn", approved: "ok", rejected: "danger", pending: "neutral", processing: "neutral" };


/**
 * KYC 人工複核後台（規格 §14.3「中信心 → 人工複核」）。
 * 只看得到浮水印版證件與臉部影像；每次檢視、決策與欄位更正都寫入稽核紀錄（data/audit/audit.jsonl）。
 */
export default function KycReviewPage() {
  const [reviewer, setReviewer] = useState<string | null>(null);
  const [needLogin, setNeedLogin] = useState(false);
  const [status, setStatus] = useState("review");
  const [cases, setCases] = useState<Case[] | null>(null);
  const [sel, setSel] = useState<Case | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const r = await call<{ reviewer: string; cases: Case[] }>(`/api/admin/kyc?status=${status}`);
      setReviewer(r.reviewer);
      setCases(r.cases);
      setNeedLogin(false);
    } catch (e) {
      if ((e as { status?: number }).status === 401) setNeedLogin(true);
      else setErr(errMsg(e));
    }
  }, [status]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load();
  }, [load]);

  if (needLogin) return <AdminLogin title="KYC 人工複核" onDone={load} />;

  return (
    <div className="mx-auto max-w-6xl space-y-4 px-5 py-8">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-bold">KYC 人工複核</h1>
        <div className="flex items-center gap-2 text-sm">
          {reviewer && <span className="text-ink-3">複核人：{reviewer}</span>}
          <select className={cx(inputCls, "h-9 w-auto")} value={status} onChange={(e) => { setSel(null); setStatus(e.target.value); }} data-testid="review-filter">
            <option value="review">待複核</option>
            <option value="pending">排隊中</option>
            <option value="approved">已核准</option>
            <option value="rejected">已退件</option>
            <option value="all">全部</option>
          </select>
          <Button size="sm" variant="secondary" onClick={load}>重新整理</Button>
        </div>
      </div>
      {err && <Notice tone="danger">{err}</Notice>}
      <div className="grid gap-4 lg:grid-cols-[320px_1fr]">
        <Panel>
          {!cases ? (
            <Spinner className="text-brand" />
          ) : cases.length === 0 ? (
            <p className="text-sm text-ink-3">沒有案件</p>
          ) : (
            <ul className="divide-y divide-line" data-testid="review-list">
              {cases.map((c) => (
                <li key={c.id}>
                  <button className={cx("w-full py-2.5 text-left", sel?.id === c.id && "text-brand")} onClick={() => setSel(c)} data-testid={`case-${c.id}`}>
                    <div className="flex items-center justify-between gap-2">
                      <span className="font-mono text-sm">{short(c.account, 6)}</span>
                      <Badge tone={STATUS_TONE[c.status] ?? "neutral"}>{c.status}</Badge>
                    </div>
                    <div className="text-xs text-ink-3">
                      {c.purpose === "recover" ? "恢復" : "開戶"} · {new Date(c.createdAt).toLocaleString("zh-TW")} · 未通過 {Object.values(c.checks).filter((x) => !x.ok).length} 項
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </Panel>
        {sel ? <Detail key={sel.id} c={sel} onDone={() => { setSel(null); load(); }} /> : <Panel><p className="text-sm text-ink-3">選擇左側案件</p></Panel>}
      </div>
    </div>
  );
}


type FieldForm = { name: string; birthday: string; issueDate: string; idNumber: string };
const emptyForm = (c: Case): FieldForm => ({ name: c.fields?.name ?? "", birthday: c.fields?.birthday ?? "", issueDate: c.fields?.issueDate ?? "", idNumber: "" });

/** 確認／更正欄位：對照浮水印版證件。統一編號只送出一次、伺服器只存 HMAC */
function FieldsEditor({ c, v, set }: { c: Case; v: FieldForm; set: (v: FieldForm) => void }) {
  const hasId = !!c.fields?.idNumberHash;
  const row = (label: string, el: ReactNode) => (
    <label className="grid grid-cols-[88px_1fr] items-center gap-2 text-sm">
      <span className="text-ink-3">{label}</span>
      {el}
    </label>
  );
  return (
    <div className="space-y-2" data-testid="fields-editor">
      {row("姓名", <input className={cx(inputCls, "h-9")} value={v.name} onChange={(e) => set({ ...v, name: e.target.value })} data-testid="field-name" />)}
      {row("出生日期", <input type="date" className={cx(inputCls, "h-9")} value={v.birthday} onChange={(e) => set({ ...v, birthday: e.target.value })} data-testid="field-birthday" />)}
      {row("發證日期", <input type="date" className={cx(inputCls, "h-9")} value={v.issueDate} onChange={(e) => set({ ...v, issueDate: e.target.value })} data-testid="field-issue" />)}
      {row(
        "統一編號",
        <input
          className={cx(inputCls, "h-9 font-mono uppercase")}
          value={v.idNumber}
          maxLength={10}
          autoComplete="off"
          placeholder={hasId ? "OCR 已擷取，留空沿用；輸入即更正" : "必填：對照證件輸入"}
          onChange={(e) => set({ ...v, idNumber: e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "") })}
          data-testid="field-id"
        />,
      )}
      <p className="text-xs text-ink-3">統一編號只用來計算 HMAC（重複開戶檢查、pairwise_id、身分恢復比對），原文不保存；性別與證件類型由統一編號推得。</p>
    </div>
  );
}

function OcrDump({ url }: { url: string }) {
  const [data, setData] = useState<Record<string, { text: string; score: number }[] | undefined> | null | "none">(null);
  const [open, setOpen] = useState(false);
  const toggle = async () => {
    setOpen(!open);
    if (!open && data === null) {
      const r = await call<{ ocr: Record<string, { text: string; score: number }[]> | null }>(url).catch(() => ({ ocr: null }));
      setData(r.ocr ?? "none");
    }
  };
  return (
    <div>
      <button className="text-xs text-brand" onClick={toggle} data-testid="ocr-toggle">{open ? "隱藏" : "顯示"} OCR 原始文字</button>
      {open && (
        <div className="mt-2 space-y-2 text-xs" data-testid="ocr-dump">
          {data === null ? (
            <Spinner className="text-brand" />
          ) : data === "none" ? (
            <p className="text-ink-3">這個案件沒有 OCR 診斷資料（較早的案件或已依保存期限清除）</p>
          ) : (
            (["front", "back", "zoom"] as const).filter((k) => data[k]).map((k) => (
              <div key={k}>
                <div className="font-medium">{k === "front" ? "正面" : k === "back" ? "反面" : "右下角放大重讀"}</div>
                <ul className="font-mono">
                  {data[k]!.map((l, i) => (
                    <li key={i} className={l.score < 0.5 ? "text-ink-3" : ""}>{l.score.toFixed(2)} {l.text}</li>
                  ))}
                </ul>
              </div>
            ))
          )}
        </div>
      )}
    </div>
  );
}

function Detail({ c, onDone }: { c: Case; onDone: () => void }) {
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [form, setForm] = useState<FieldForm>(() => emptyForm(c));
  const [correcting, setCorrecting] = useState(false);
  const f = (kind: string) => `/api/admin/kyc/file?account=${c.account}&case=${c.id}&kind=${kind}`;
  const onboard = c.purpose === "onboard";
  const fieldsBody = () => ({ name: form.name, birthday: form.birthday, issueDate: form.issueDate || undefined, idNumber: form.idNumber || undefined });
  const fieldsReady = !!form.name.trim() && !!form.birthday && (!!c.fields?.idNumberHash || form.idNumber.length === 10);
  const correct = async () => {
    setBusy("correct");
    setErr(null);
    try {
      await call("/api/admin/kyc", { action: "correct", account: c.account, caseId: c.id, fields: fieldsBody(), note });
      onDone();
    } catch (e) {
      setErr(errMsg(e));
    } finally {
      setBusy(null);
    }
  };
  const decide = async (decision: "approved" | "rejected") => {
    setBusy(decision);
    setErr(null);
    try {
      await call("/api/admin/kyc", { account: c.account, caseId: c.id, decision, note, ...(decision === "approved" && onboard ? { fields: fieldsBody() } : {}) });
      onDone();
    } catch (e) {
      setErr(errMsg(e));
    } finally {
      setBusy(null);
    }
  };
  return (
    <div className="space-y-4" data-testid="review-detail">
      <Panel title={`${c.purpose === "recover" ? "恢復" : "開戶"}案件 ${c.id}`} action={<Badge tone={STATUS_TONE[c.status] ?? "neutral"}>{c.status}</Badge>}>
        <div className="mb-3 font-mono text-xs text-ink-3">{c.account}</div>
        <div className="grid gap-3 md:grid-cols-3">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={f("front")} alt="證件正面（浮水印版）" className="w-full rounded-xl border border-line" />
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={f("back")} alt="證件反面（浮水印版）" className="w-full rounded-xl border border-line" />
          <video src={f("face")} controls className="w-full rounded-xl border border-line bg-black" />
        </div>
      </Panel>
      <div className="grid gap-4 md:grid-cols-2">
        <Panel title="自動檢查">
          <ul className="space-y-1.5 text-sm">
            {Object.entries(c.checks).map(([k, v]) => (
              <li key={k} className="flex gap-2">
                <span className={v.ok ? "text-ok" : "text-danger"}>{v.ok ? "✓" : "✕"}</span>
                <span>
                  <span className="font-medium">{CHECK_LABEL[k] ?? k}</span>
                  <span className="block text-xs text-ink-3">{v.detail}</span>
                </span>
              </li>
            ))}
          </ul>
        </Panel>
        <div className="space-y-4">
          <Panel title="擷取欄位">
            {c.fields ? (
              <dl className="space-y-1 text-sm">
                {Object.entries(c.fields).filter(([, v]) => v).map(([k, v]) => (
                  <div key={k} className="flex justify-between gap-3">
                    <dt className="text-ink-3">{FIELD_LABEL[k] ?? k}</dt>
                    <dd className={cx("text-right", k === "idNumberHash" && "truncate font-mono text-xs")}>{v}</dd>
                  </div>
                ))}
              </dl>
            ) : (
              <p className="text-sm text-ink-3">沒有擷取到欄位</p>
            )}
            <div className="mt-3 border-t border-line pt-2">
              <OcrDump url={f("ocr")} />
            </div>
          </Panel>
          <Panel title="分數">
            <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
              {Object.entries(c.scores ?? {}).map(([k, v]) => (
                <div key={k} className="flex justify-between gap-2">
                  <dt className="text-ink-3">{k}</dt>
                  <dd className="font-mono">{String(v)}</dd>
                </div>
              ))}
            </dl>
          </Panel>
        </div>
      </div>
      {c.review && <Notice>已由 {c.review.by} 於 {new Date(c.review.at).toLocaleString("zh-TW")} {c.review.decision === "approved" ? "核准" : "退件"}{c.review.note ? `：${c.review.note}` : ""}</Notice>}
      {c.result?.error && <Notice tone="danger">鏈上處理失敗：{c.result.error}</Notice>}
      {c.corrections?.map((x, i) => (
        <Notice key={i}>{x.by} 於 {new Date(x.at).toLocaleString("zh-TW")} 更正 {x.fields.join("、")}：{x.note}</Notice>
      ))}
      {c.status === "approved" && onboard && (
        <Panel title="更正欄位" action={!correcting && <Button size="sm" variant="secondary" onClick={() => setCorrecting(true)} testId="correct-open">更正</Button>}>
          {correcting ? (
            <div className="space-y-3">
              <FieldsEditor c={c} v={form} set={setForm} />
              <textarea className={cx(inputCls, "h-16 py-2")} placeholder="更正原因（必填，會寫入稽核紀錄）" value={note} onChange={(e) => setNote(e.target.value)} data-testid="correct-note" />
              {err && <Notice tone="danger">{err}</Notice>}
              <Button onClick={correct} busy={busy === "correct"} disabled={!!busy || !fieldsReady || !note.trim()} testId="correct-submit">儲存更正</Button>
            </div>
          ) : (
            <p className="text-sm text-ink-3">OCR 讀錯或缺漏時，對照證件更正姓名、出生日期或統一編號。{!c.fields?.idNumberHash && <span className="text-danger"> 這個案件沒有統一編號，重複開戶檢查、pairwise_id 與身分恢復都無法運作，請補上。</span>}</p>
          )}
        </Panel>
      )}
      {c.status === "review" && (
        <Panel title="決策">
          {onboard && (
            <div className="mb-3">
              <div className="mb-2 text-sm font-medium">確認欄位（核准時寫入；對照證件更正 OCR 錯誤）</div>
              <FieldsEditor c={c} v={form} set={setForm} />
            </div>
          )}
          <textarea className={cx(inputCls, "h-20 py-2")} placeholder="備註（退件原因會記錄在案件中）" value={note} onChange={(e) => setNote(e.target.value)} data-testid="review-note" />
          {err && <div className="mt-2"><Notice tone="danger">{err}</Notice></div>}
          <div className="mt-3 grid grid-cols-2 gap-2">
            <Button variant="danger" onClick={() => decide("rejected")} busy={busy === "rejected"} disabled={!!busy} testId="review-reject">退件</Button>
            <Button onClick={() => decide("approved")} busy={busy === "approved"} disabled={!!busy || (onboard && !fieldsReady)} testId="review-approve">核准並寫入 L2</Button>
          </div>
          <p className="mt-2 text-xs text-ink-3">{c.purpose === "recover" ? "核准恢復案件＝確認與開戶時是同一人，會以平台備援金鑰發起恢復（48 小時／有卡 7 天時間鎖）。" : "核准後寫入實名證明（v1＋v2），使用者端會接著安裝平台備援金鑰。"}</p>
        </Panel>
      )}
    </div>
  );
}
