import type { OcrLine } from "./ocr";

/**
 * 國民身分證版面解析（規格 §14.3）：以標籤列（姓名、出生年月日…）找同一列右側的值，
 * 統一編號以正規式＋檢查碼從全文擷取。浮水印造成的雜訊行不會落在標籤列上，因此不影響。
 */
export type IdFields = {
  name: string | null;
  birthday: string | null; // 西元 YYYY-MM-DD
  sex: "M" | "F" | null;
  issueDate: string | null;
  issueType: string | null; // 初發／補發／換發
  idNumber: string | null;
  docType: "national_id" | "resident_permit" | null;
  address: string | null;
  birthplace: string | null;
};

const LETTER: Record<string, number> = {
  A: 10, B: 11, C: 12, D: 13, E: 14, F: 15, G: 16, H: 17, I: 34, J: 18, K: 19, L: 20, M: 21,
  N: 22, O: 35, P: 23, Q: 24, R: 25, S: 26, T: 27, U: 28, V: 29, W: 32, X: 30, Y: 31, Z: 33,
};

/** 國民身分證／新式居留證統一編號檢查碼 */
export function validTwId(id: string): boolean {
  if (!/^[A-Z][1289]\d{8}$/.test(id)) return false;
  const n = LETTER[id[0]];
  let sum = Math.floor(n / 10) + (n % 10) * 9;
  for (let i = 1; i < 9; i++) sum += Number(id[i]) * (9 - i);
  sum += Number(id[9]);
  return sum % 10 === 0;
}

const norm = (s: string) =>
  s
    .replace(/别/g, "別")
    .replace(/[证証]/g, "證")
    .replace(/换/g, "換")
    .replace(/补/g, "補")
    .replace(/发/g, "發")
    .replace(/国/g, "國")
    .replace(/编/g, "編")
    .replace(/号/g, "號")
    .replace(/[（]/g, "(")
    .replace(/[）]/g, ")")
    .replace(/[０-９Ａ-Ｚａ-ｚ]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/\s+/g, "")
    .replace(/[oO](?=\d)/g, "0");

function rocDate(s: string): string | null {
  const m = norm(s).match(/(?:民國?)?(\d{2,3})年(\d{1,2})月(\d{1,2})日/);
  if (!m) return null;
  const y = Number(m[1]) + 1911, mo = Number(m[2]), d = Number(m[3]);
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return null;
  return `${y}-${String(mo).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

/** 與標籤同一列、在標籤右側、高度相近且彼此相鄰的文字 */
function valueRight(lines: OcrLine[], label: RegExp): string | null {
  const l = lines.find((x) => label.test(norm(x.text)));
  if (!l) return null;
  const t = norm(l.text);
  const inline = t.slice(t.search(label)).replace(label, "");
  const [lx, ly, lw, lh] = l.box;
  const overlap = (x: OcrLine) => {
    const a = Math.max(ly, x.box[1]), b = Math.min(ly + lh, x.box[1] + x.box[3]);
    return Math.max(0, b - a) / Math.min(lh, x.box[3]);
  };
  const right = lines
    .filter((x) => x !== l && x.box[0] > lx + lw * 0.6 && overlap(x) > 0.5 && x.box[3] < lh * 2.2)
    .sort((a, b) => a.box[0] - b.box[0]);
  const parts = [inline];
  let edge = lx + lw;
  for (const x of right) {
    if (x.box[0] - edge > lh * 6) break;
    parts.push(norm(x.text));
    edge = x.box[0] + x.box[2];
  }
  const v = parts.join("");
  return v || null;
}

/** 浮水印（「僅供 CAFECA 身分驗證使用」）的片段：一行裡大多是這些字就視為雜訊 */
const WM_CHARS = new Set("僅催供CAFEcafe身分驗證使用用".split(""));
const isWatermark = (t: string) => {
  const s = norm(t);
  const hit = [...s].filter((c) => WM_CHARS.has(c)).length;
  return /CAFECA/i.test(s) || (s.length > 0 && hit / s.length >= 0.5);
};
const WATERMARK = { test: isWatermark };

/** 統一編號常見的誤讀字元（只用在第 2～10 碼） */
const DIGIT_LIKE: Record<string, string> = { O: "0", D: "0", Q: "0", I: "1", L: "1", "|": "1", Z: "2", S: "5", G: "6", T: "7", B: "8" };

/**
 * 從文字中找出檢查碼正確的統一編號。
 * - 逐一位置嘗試（浮水印的英文字母可能緊貼在證號前面，例如 "CAFECAK1…"）
 * - 第 2～10 碼把常見誤讀（O→0、I→1、S→5、B→8…）換回數字後再驗檢查碼；檢查碼本身就能擋掉大部分誤判
 */
export function findTwIds(text: string): string[] {
  const t = norm(text).toUpperCase().replace(/[^A-Z0-9|]/g, "");
  const out: string[] = [];
  for (let i = 0; i + 10 <= t.length; i++) {
    if (!/[A-Z]/.test(t[i])) continue;
    const rest = [...t.slice(i + 1, i + 10)].map((c) => DIGIT_LIKE[c] ?? c).join("");
    const id = t[i] + rest;
    if (validTwId(id) && !out.includes(id)) out.push(id);
  }
  return out;
}

/** 證件正面所有可辨識的日期（民國年），依版面位置判斷哪個是出生日期、哪個是發證日期 */
function datesOf(lines: OcrLine[]) {
  const issueLabel = lines.find((l) => /發證日期|發證/.test(norm(l.text)));
  const birthLabels = lines.filter((l) => /出生|年月日|生日/.test(norm(l.text)) && !/發證/.test(norm(l.text)));
  const dates = lines
    .map((l) => ({ l, date: rocDate(l.text), text: norm(l.text) }))
    .filter((x): x is { l: OcrLine; date: string; text: string } => !!x.date);
  const cy = (l: OcrLine) => l.box[1] + l.box[3] / 2;
  const isIssue = (x: (typeof dates)[number]) =>
    /發證|(初|補|換)發/.test(x.text) || (!!issueLabel && Math.abs(cy(x.l) - cy(issueLabel)) < Math.max(x.l.box[3], issueLabel.box[3]) * 0.6);
  const issue = dates.find(isIssue) ?? null;
  const rest = dates.filter((x) => x !== issue);
  let birth: (typeof dates)[number] | null = rest.find((x) => /出生|年月日|生日/.test(x.text)) ?? null;
  if (!birth && birthLabels.length && rest.length) {
    // 「出生／年月日」是上下兩行的標籤：取垂直位置最接近標籤、且在標籤右側的日期
    const near = (x: (typeof dates)[number]) => Math.min(...birthLabels.map((b) => Math.abs(cy(x.l) - cy(b)) + (x.l.box[0] < b.box[0] ? 1e6 : 0)));
    birth = [...rest].sort((a, b) => near(a) - near(b))[0];
  }
  // 只剩一個日期且比發證日期早：一定是出生日期
  if (!birth && rest.length === 1 && (!issue || rest[0].date < issue.date)) birth = rest[0];
  return { birthday: birth?.date ?? null, issueDate: issue?.date ?? null, issueText: issue?.text ?? "" };
}

export function parseFront(lines: OcrLine[]): Pick<IdFields, "name" | "birthday" | "sex" | "issueDate" | "issueType" | "idNumber" | "docType"> {
  const clean = lines
    .map((l) => ({ ...l, text: norm(l.text).replace(/^.*?(?=[A-Z][1289]\d{8})/, (m) => (isWatermark(m) ? "" : m)) }))
    .filter((l) => l.score >= 0.5 && (!isWatermark(l.text) || /[A-Z][1289]\d{8}/.test(l.text.toUpperCase())));
  // 統一編號：檢查碼足以排除誤判，所以低信心、混到浮水印的行也納入；同一列被切成兩段時也接起來試
  const rows: string[] = [];
  const sorted = [...lines].filter((l) => l.score >= 0.2).sort((a, b) => a.box[1] - b.box[1] || a.box[0] - b.box[0]);
  for (const l of sorted) {
    rows.push(l.text);
    const right = sorted.filter((x) => x !== l && x.box[0] > l.box[0] && Math.abs(x.box[1] + x.box[3] / 2 - (l.box[1] + l.box[3] / 2)) < l.box[3] * 0.5);
    if (right.length) rows.push(l.text + right.sort((a, b) => a.box[0] - b.box[0]).map((x) => x.text).join(""));
  }
  const ids = [...new Set(rows.flatMap(findTwIds))];
  const idNumber = ids.length === 1 ? ids[0] : (ids.find((id) => clean.some((l) => norm(l.text).toUpperCase().includes(id))) ?? ids[0] ?? null);
  const nameRaw = valueRight(clean, /姓名/);
  const name = nameRaw ? nameRaw.replace(/[^一-鿿‧·．.]/g, "").replace(/[·．.]/g, "‧").slice(0, 20) || null : null;
  const d = datesOf(clean);
  const birthday = rocDate(valueRight(clean, /出生年月日|出生日期/) ?? "") ?? d.birthday;
  const sexRaw = valueRight(clean, /性別/) ?? "";
  const sex = /男/.test(sexRaw) ? "M" : /女/.test(sexRaw) ? "F" : null;
  const issue = valueRight(clean, /發證日期/) ?? d.issueText;
  const issueType = (issue + d.issueText).match(/(初發|補發|換發)/)?.[1] ?? null;
  const docType = idNumber ? (/[12]/.test(idNumber[1]) ? "national_id" : "resident_permit") : null;
  return { name, birthday, sex, issueDate: rocDate(issue) ?? d.issueDate, issueType, idNumber, docType };
}

/** 診斷用：OCR 文字行存檔前遮罩統一編號與長數字（只留頭尾） */
export function maskOcr(lines: OcrLine[]) {
  return lines.map((l) => ({
    text: l.text.replace(/[A-Za-z]?[0-9OoIlSsBZ|]{6,}/g, (m) => m.slice(0, 1) + "*".repeat(Math.max(0, m.length - 3)) + m.slice(-2)),
    score: Number(l.score.toFixed(2)),
    box: l.box.map((v) => Math.round(v)),
  }));
}

export function parseBack(lines: OcrLine[]): Pick<IdFields, "address" | "birthplace"> {
  const clean = lines.filter((l) => l.score >= 0.5 && !WATERMARK.test(l.text));
  const address = valueRight(clean, /住址/)?.replace(/^[:：]/, "") || null;
  const birthplace = valueRight(clean, /出生地/)?.replace(/^[:：]/, "") || null;
  return { address, birthplace };
}

/** 欄位之間的合理性檢查 */
export function consistency(f: IdFields): { ok: boolean; issues: string[] } {
  const issues: string[] = [];
  if (!f.idNumber) issues.push("找不到有效的統一編號（檢查碼不符或無法辨識）");
  if (!f.name) issues.push("無法辨識姓名");
  if (!f.birthday) issues.push("無法辨識出生年月日");
  if (f.idNumber && f.sex && f.docType === "national_id") {
    const s = f.idNumber[1] === "1" ? "M" : "F";
    if (s !== f.sex) issues.push("性別與統一編號第二碼不符");
  }
  const now = new Date().toISOString().slice(0, 10);
  if (f.birthday && (f.birthday > now || f.birthday < "1900-01-01")) issues.push("出生日期不合理");
  if (f.issueDate && (f.issueDate > now || (f.birthday && f.issueDate < f.birthday))) issues.push("發證日期不合理");
  return { ok: issues.length === 0, issues };
}
