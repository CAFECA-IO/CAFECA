import { isAddress } from "viem";
import { confirmFields, type FieldInput } from "@/server/kyc-fields";
import { finalize, findCase, saveCase } from "@/server/kyc-queue";
import { audit, requireReviewer } from "@/server/kyc-review";
import { handle, HttpError } from "@/server/session";
import { read, type KycCase } from "@/server/store";

/** GET：待複核（或指定狀態）的案件；POST：核准或退件 */
export const GET = handle(async (req: Request) => {
  const who = await requireReviewer("kyc");
  const status = new URL(req.url).searchParams.get("status") ?? "review";
  const s = await read();
  const list = Object.entries(s.kyc)
    .flatMap(([account, r]) => (r.cases ?? []).map((c) => ({ account, ...c })))
    .filter((c) => status === "all" || c.status === status)
    .sort((a, b) => b.createdAt - a.createdAt)
    .slice(0, 100);
  return Response.json({ reviewer: who, cases: list });
});

/**
 * POST { account, caseId, decision: "approved"|"rejected", note?, fields? }
 *   開戶案件核准時一併確認欄位（姓名、出生日期、統一編號…）；OCR 沒擷取到的必須由複核人員對照證件輸入
 * POST { action: "correct", account, caseId, fields, note } → 更正已核准案件的欄位（必填原因）
 */
export const POST = handle(async (req: Request) => {
  const who = await requireReviewer("kyc");
  const b = (await req.json().catch(() => ({}))) as { action?: string; account?: string; caseId?: string; decision?: "approved" | "rejected"; note?: string; fields?: FieldInput };
  const { account = "", caseId = "", decision } = b;
  if (!isAddress(account)) throw new HttpError(400, "參數錯誤");
  const c = await findCase(account, caseId);
  if (!c) throw new HttpError(404, "找不到案件");
  const note = (b.note ?? "").trim().slice(0, 500) || undefined;

  if (b.action === "correct") {
    if (c.status !== "approved" || c.purpose !== "onboard") throw new HttpError(409, "只能更正已核准的開戶案件");
    if (!note) throw new HttpError(400, "請填寫更正原因");
    const { fields, changed } = await confirmFields(account, c, b.fields);
    if (!changed.length) throw new HttpError(400, "欄位沒有變更");
    await saveCase(account, { ...c, fields, corrections: [...(c.corrections ?? []), { by: who, at: Date.now(), fields: changed, note }] }, (rec) => {
      if (fields.idNumberHash) rec.idHash = fields.idNumberHash;
    });
    await audit({ who, action: "kyc.fields.correct", account, caseId, fields: changed, note });
    return Response.json({ ok: true, case: await findCase(account, caseId) });
  }

  if (!decision || !["approved", "rejected"].includes(decision)) throw new HttpError(400, "參數錯誤");
  if (c.status !== "review") throw new HttpError(409, `案件狀態為 ${c.status}，只能處理待複核的案件`);
  let next: KycCase = { ...c, status: decision, decidedBy: "reviewer", review: { by: who, at: Date.now(), decision, note } };
  let changed: string[] = [];
  if (decision === "approved" && c.purpose === "onboard") {
    const r = await confirmFields(account, c, b.fields);
    next = { ...next, fields: r.fields };
    changed = r.changed;
  }
  await saveCase(account, next);
  await audit({ who, action: "decide", account, caseId, decision, note, ...(changed.length ? { fieldsConfirmed: changed } : {}) });
  if (decision === "approved") await finalize(account, caseId, who);
  return Response.json({ ok: true, case: await findCase(account, caseId) });
});
