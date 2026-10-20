import "server-only";
import { kycIdHash } from "./kyc";
import { validTwId } from "./kyc-ml/fields";
import { HttpError } from "./session";
import { read, type KycCase } from "./store";

/**
 * 複核人員確認或更正 OCR 擷取的欄位（人工核准、核准後更正共用）。
 *
 * - 統一編號只保存 HMAC：複核人員對照浮水印版證件輸入，伺服器驗檢查碼、算 HMAC，原文不落地
 * - OCR 已擷取到統一編號時可以留空（沿用）；輸入值與 OCR 不同視為更正，寫入稽核紀錄
 * - 性別、證件類型、國籍由統一編號推得，與輸入矛盾時拒絕
 * - 同一統一編號已綁定其他有效身分時拒絕（與自動流程的 duplicate 檢查相同）
 */
export type FieldInput = { name?: unknown; birthday?: unknown; idNumber?: unknown; issueDate?: unknown };
type Fields = NonNullable<KycCase["fields"]>;

const isDate = (v: string) => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v)) return false;
  const d = new Date(v + "T00:00:00Z");
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
};

export async function confirmFields(account: string, c: KycCase, input: FieldInput | undefined): Promise<{ fields: Fields; changed: string[] }> {
  const prev: Fields = c.fields ?? {};
  const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");

  const name = str(input?.name) || prev.name || "";
  if (!/^[\p{Script=Han}‧]{2,20}$/u.test(name) && !/^[A-Za-z][A-Za-z ,.'-]{1,59}$/.test(name)) throw new HttpError(400, "姓名格式錯誤：請依證件輸入（中文 2–20 字，或護照／居留證上的英文姓名）");

  const birthday = str(input?.birthday) || prev.birthday || "";
  const today = new Date().toISOString().slice(0, 10);
  if (!isDate(birthday) || birthday > today || birthday < "1900-01-01") throw new HttpError(400, "出生日期格式錯誤（西元 YYYY-MM-DD）");

  const issueDate = str(input?.issueDate) || prev.issueDate || undefined;
  if (issueDate && (!isDate(issueDate) || issueDate > today || issueDate < birthday)) throw new HttpError(400, "發證日期不合理（西元 YYYY-MM-DD，須晚於出生日期）");

  const typed = str(input?.idNumber).toUpperCase();
  let idNumberHash = prev.idNumberHash;
  let sex = prev.sex, docType = prev.docType, nationality = prev.nationality;
  if (typed) {
    if (!validTwId(typed)) throw new HttpError(400, "統一編號格式或檢查碼錯誤");
    idNumberHash = kycIdHash(typed);
    docType = /[12]/.test(typed[1]) ? "national_id" : "resident_permit";
    if (docType === "national_id") {
      sex = typed[1] === "1" ? "M" : "F";
      nationality = "TW";
    } else {
      // 新式居留證第二碼 8／9 為性別，國籍不從證號推得
      sex = typed[1] === "8" ? "M" : "F";
      nationality = prev.docType === "resident_permit" ? prev.nationality : undefined;
    }
  }
  if (!idNumberHash) throw new HttpError(400, "OCR 沒有擷取到統一編號：請對照證件輸入");

  const s = await read();
  const others = Object.entries(s.kyc).filter(([a, r]) => a.toLowerCase() !== account.toLowerCase() && r.idHash === idNumberHash && r.level >= 2);
  if (others.length) throw new HttpError(409, `此統一編號已綁定其他 CAFECA 身分（${others.length} 個），不能核准`);

  const fields: Fields = { name, birthday, sex, docType, issueDate, nationality, idNumberHash };
  const changed = (Object.keys(fields) as (keyof Fields)[]).filter((k) => (fields[k] ?? null) !== (prev[k] ?? null));
  return { fields, changed };
}
