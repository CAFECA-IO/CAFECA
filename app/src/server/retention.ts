import "server-only";
import { promises as fs } from "fs";
import path from "path";
import { writeAudit } from "./audit";
import { caseDir } from "./kyc-pipeline";
import { policy } from "./policy";
import { read, update, type KycCase } from "./store";

/**
 * 保存期限清除（P3-B5）：只清除「不是帳戶目前依據」的案件檔案。
 * - 未通過的案件：rejectedCaseDays 後清除證件影像、臉部影片與人臉特徵
 * - 已被較新核准案件取代的案件：新案件核准後 supersededCaseDays 清除
 * 保留案件的中繼資料與檔案雜湊（稽核與鏈上 claimsRoot 對照用），清除本身寫入稽核紀錄。
 * 目前依據的核准案件、審核中的案件一律不動。
 */

type Target = { account: string; caseId: string; why: "rejected" | "superseded"; age: number };

export async function retentionTargets(now = Date.now()): Promise<Target[]> {
  const p = policy().retention;
  const s = await read();
  const out: Target[] = [];
  for (const [account, rec] of Object.entries(s.kyc)) {
    const cases = rec.cases ?? [];
    const approved = cases.filter((c) => c.status === "approved").sort((a, b) => b.createdAt - a.createdAt);
    const current = approved[0];
    for (const c of cases) {
      if (c.purgedAt) continue;
      const decided = c.processedAt ?? c.createdAt;
      if (c.status === "rejected" && now - decided > p.rejectedCaseDays * 86400_000) out.push({ account, caseId: c.id, why: "rejected", age: now - decided });
      else if (c.status === "approved" && current && c.id !== current.id) {
        const since = current.processedAt ?? current.createdAt;
        if (now - since > p.supersededCaseDays * 86400_000) out.push({ account, caseId: c.id, why: "superseded", age: now - since });
      }
    }
  }
  return out;
}

async function purgeCase(account: string, c: KycCase) {
  const dir = caseDir(account, c.id);
  const removed: string[] = [];
  for (const k of ["front", "back", "face"] as const) {
    const f = path.join(dir, c.files[k]);
    if (await fs.rm(f).then(() => true, () => false)) removed.push(k);
  }
  const cj = path.join(dir, "case.json");
  const raw = await fs.readFile(cj, "utf8").catch(() => null);
  if (raw) {
    const j = JSON.parse(raw);
    delete j.embeddings;
    delete j.code;
    delete j.ocr;
    await fs.writeFile(cj, JSON.stringify(j, null, 2));
  }
  return removed;
}

export async function runRetention(who: string, now = Date.now()) {
  const targets = await retentionTargets(now);
  for (const t of targets) {
    const c = (await read()).kyc[t.account]?.cases?.find((x) => x.id === t.caseId);
    if (!c) continue;
    const removed = await purgeCase(t.account, c);
    await update((s) => {
      const x = s.kyc[t.account].cases!.find((y) => y.id === t.caseId)!;
      x.purgedAt = now;
    });
    await writeAudit({ who, action: "retention.purge", account: t.account, case: t.caseId, why: t.why, removed, policy: policy().version });
  }
  return { purged: targets.length };
}
