import { promises as fs } from "fs";
import path from "path";
import { isAddress } from "viem";
import { caseDir, readOcr } from "@/server/kyc-pipeline";
import { findCase } from "@/server/kyc-queue";
import { audit, requireReviewer } from "@/server/kyc-review";
import { handle, HttpError } from "@/server/session";

/** 複核人員檢視案件檔案（只有浮水印版證件、臉部影像與遮罩後的 OCR 文字）；每次檢視都寫入稽核紀錄 */
export const GET = handle(async (req: Request) => {
  const who = await requireReviewer("kyc");
  const q = new URL(req.url).searchParams;
  const account = q.get("account") ?? "";
  const id = q.get("case") ?? "";
  const kind = q.get("kind") as "front" | "back" | "face" | "ocr";
  if (!isAddress(account) || !["front", "back", "face", "ocr"].includes(kind)) throw new HttpError(400, "參數錯誤");
  const c = await findCase(account, id);
  if (!c) throw new HttpError(404, "找不到案件");
  if (kind === "ocr") {
    // OCR 診斷文字（統一編號與長數字已遮罩）
    const ocr = await readOcr(account, id).catch(() => null);
    await audit({ who, action: "view", account, caseId: id, kind });
    return Response.json({ ocr }, { headers: { "cache-control": "no-store" } });
  }
  const file = path.join(caseDir(account, id), c.files[kind]);
  const buf = await fs.readFile(file);
  await audit({ who, action: "view", account, caseId: id, kind });
  const type = kind === "face" ? (c.files.face.endsWith("mp4") ? "video/mp4" : "video/webm") : "image/jpeg";
  return new Response(new Uint8Array(buf), { headers: { "content-type": type, "cache-control": "no-store", "x-content-type-options": "nosniff" } });
});
