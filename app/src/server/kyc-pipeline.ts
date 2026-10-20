import "server-only";
import { promises as fs } from "fs";
import path from "path";
import type { IdFields } from "./kyc-ml/fields";
import { kycIdHash } from "./kyc";
import { read, type KycCase } from "./store";

/**
 * 後台 KYC 驗證流程（團隊自建，規格 §14.3、§14.6）。全部在本機推論，影像不離開伺服器。
 *
 *   ocr          PP-OCRv5 擷取姓名、出生年月日、性別、發證日期、統一編號（檢查碼）、住址
 *   fields       欄位合理性（檢查碼、性別與第二碼、日期）
 *   idFace       證件正面找得到人像
 *   liveness     伺服器端重算 6 個動作（與裝置端同一套 MediaPipe 特徵點與公式）
 *   speech       Whisper 核對念出的 4 位數字
 *   faceMatch    影片正臉 vs 證件照（SFace，餘弦相似度）
 *   duplicate    同一個統一編號是否已綁定其他 CAFECA 身分
 *   recapture    翻拍偵測：目前只記錄裝置端特徵（摩爾紋、反光、清晰度），分類器尚未訓練
 *
 * 決策：全部通過且人臉相似度 ≥ AUTO_FACE（且 KYC_AUTO_APPROVE=1）→ approved；明確不是同一人或影片中沒有臉 → rejected；
 *       其餘 → review（人工複核，/admin/kyc）。
 */

/** 只供開發／E2E：略過模型、全部放行（正式環境不得開啟） */
export const PROTOTYPE_AUTO_APPROVE = process.env.KYC_PROTOTYPE_AUTO_APPROVE === "1";
/**
 * 高信心案件自動通過。預設關閉：門檻還沒有以真實（經同意的）樣本校準前，所有案件都先轉人工複核，
 * 複核紀錄與分數會成為校準資料。校準完成後設 KYC_AUTO_APPROVE=1。
 */
const AUTO_APPROVE = process.env.KYC_AUTO_APPROVE === "1";
/** 自動通過的人臉相似度門檻（高於 SFace 的同一人門檻，留安全邊際） */
const AUTO_FACE = Number(process.env.KYC_AUTO_FACE ?? 0.45);
/** 念數字只差一碼時，若其餘活體與人臉比對都通過即接受（KYC_SPEECH_PARTIAL_OK=0 可關閉） */
const SPEECH_PARTIAL_OK = process.env.KYC_SPEECH_PARTIAL_OK !== "0";
/** 低於此值視為明確不是同一人 */
const REJECT_FACE = 0.15;

export function caseDir(account: string, id: string) {
  return path.join(process.cwd(), "data", "kyc", account.toLowerCase(), id);
}

type OcrDump = { text: string; score: number; box: number[] }[];
type CaseFile = KycCase & { code?: string; challengeActions?: string[]; embeddings?: { id?: number[]; video?: number[] }; ocr?: { front: OcrDump; back: OcrDump; zoom?: OcrDump } };

/** 複核後台讀取 OCR 診斷資料 */
export async function readOcr(account: string, id: string) {
  return (await readCaseFile(account, id)).ocr ?? null;
}

async function readCaseFile(account: string, id: string): Promise<CaseFile> {
  return JSON.parse(await fs.readFile(path.join(caseDir(account, id), "case.json"), "utf8"));
}

async function writeOcr(account: string, id: string, ocr: CaseFile["ocr"]) {
  const f = await readCaseFile(account, id);
  await fs.writeFile(path.join(caseDir(account, id), "case.json"), JSON.stringify({ ...f, ocr }, null, 2));
}

async function writeEmbeddings(account: string, id: string, e: CaseFile["embeddings"]) {
  const f = await readCaseFile(account, id);
  await fs.writeFile(path.join(caseDir(account, id), "case.json"), JSON.stringify({ ...f, embeddings: e }, null, 2));
}

const round = (n: number) => Number(n.toFixed(3));

export async function runPipeline(c: KycCase, account: string): Promise<KycCase> {
  const checks = { ...c.checks };
  const scores: NonNullable<KycCase["scores"]> = {};

  if (PROTOTYPE_AUTO_APPROVE) {
    checks.prototype = { ok: true, detail: "KYC_PROTOTYPE_AUTO_APPROVE=1：未經模型驗證直接放行（僅限開發）" };
    return { ...c, checks, status: "approved", decidedBy: "prototype", processedAt: Date.now() };
  }

  // 模型與原生模組（onnxruntime-node、sharp）只在真正要驗證時才載入
  const [{ consistency, findTwIds, maskOcr, parseBack, parseFront }, { cosine, detectFaces, embedFace, largest, SFACE_SAME }, { checkLiveness }, { ffmpegAvailable }, { readText }, { decodeImage, missingModels, warp }] =
    await Promise.all([import("./kyc-ml/fields"), import("./kyc-ml/face"), import("./kyc-ml/liveness"), import("./kyc-ml/media"), import("./kyc-ml/ocr"), import("./kyc-ml/runtime")]);

  const missing = missingModels();
  if (missing.length || !(await ffmpegAvailable())) {
    checks.models = { ok: false, detail: missing.length ? `缺少模型：${missing.join("、")}（請執行 npm run fetch-models）` : "伺服器沒有 ffmpeg，無法解碼臉部影像" };
    return { ...c, checks, status: "review", processedAt: Date.now() };
  }

  const dir = caseDir(account, c.id);
  const meta = await readCaseFile(account, c.id);

  // 1. 證件 OCR
  const frontImg = await decodeImage(await fs.readFile(path.join(dir, c.files.front)));
  const backImg = await decodeImage(await fs.readFile(path.join(dir, c.files.back)));
  const frontLines = await readText(frontImg);
  const backLines = await readText(backImg);
  const f: IdFields = { ...parseFront(frontLines), ...parseBack(backLines) };
  let zoomLines: typeof frontLines = [];
  if (!f.idNumber) {
    // 統一編號在正面右下角，常被反光或浮水印干擾：裁出右下區域放大兩倍再讀一次
    const x0 = Math.round(frontImg.width * 0.5), y0 = Math.round(frontImg.height * 0.55);
    const w = frontImg.width - x0, h = frontImg.height - y0;
    zoomLines = await readText(warp(frontImg, w * 2, h * 2, [0.5, 0, x0, 0, 0.5, y0]));
    const found = [...new Set(zoomLines.flatMap((l) => findTwIds(l.text)).concat(findTwIds(zoomLines.map((l) => l.text).join(""))))];
    if (found.length === 1) {
      f.idNumber = found[0];
      f.docType = /[12]/.test(found[0][1]) ? "national_id" : "resident_permit";
    }
  }
  // 診斷用：OCR 原始文字（統一編號與長數字已遮罩）存進案件檔，保存期限到期時一併清除
  await writeOcr(account, c.id, { front: maskOcr(frontLines), back: maskOcr(backLines), zoom: zoomLines.length ? maskOcr(zoomLines) : undefined });
  const cons = consistency(f);
  checks.ocr = { ok: !!(f.idNumber && f.name && f.birthday), detail: f.idNumber ? `擷取到姓名、出生日期與統一編號（${f.idNumber.slice(0, 1)}*******${f.idNumber.slice(-2)}）` : "無法擷取統一編號" };
  checks.fields = { ok: cons.ok, detail: cons.ok ? "檢查碼、性別與日期合理" : cons.issues.join("；") };
  checks.backSide = { ok: !!(f.address || f.birthplace), detail: f.address || f.birthplace ? "反面欄位可辨識" : "反面欄位無法辨識（可能不是身分證反面）" };

  // 2. 證件人像
  const idFace = largest(await detectFaces(frontImg, 0.6));
  checks.idFace = { ok: !!idFace, detail: idFace ? "證件正面找到人像" : "證件正面找不到人像" };
  const idEmb = idFace ? await embedFace(frontImg, idFace) : null;

  // 3. 活體重檢＋語音
  const live = await checkLiveness(path.join(dir, c.files.face), c.actions, meta.challengeActions ?? c.actions.map((a) => a.action), meta.code ?? "");
  const okActions = live.actions.filter((a) => a.ok).length;
  checks.liveness = {
    ok: live.actions.every((a) => a.ok) && live.faceRatio >= 0.85,
    detail: `影片 ${live.frames} 格、${Math.round(live.faceRatio * 100)}% 有臉；${okActions}/${live.actions.length} 個動作在影片中確認` + (live.actions.some((a) => !a.ok) ? `（未確認：${live.actions.filter((a) => !a.ok).map((a) => a.action).join("、")}）` : ""),
  };
  checks.singleFace = { ok: live.multiFaceRatio < 0.1, detail: live.multiFaceRatio < 0.1 ? "影片中只有一張臉" : `${Math.round(live.multiFaceRatio * 100)}% 的影格出現多張臉` };
  const speechPartial = live.speech?.match === "partial";

  // 4. 人臉比對
  const videoEmb = live.best ? await embedFace(live.best.img, live.best.face) : null;
  const sim = idEmb && videoEmb ? cosine(idEmb, videoEmb) : null;
  checks.faceMatch = {
    ok: sim !== null && sim >= AUTO_FACE,
    detail: sim === null ? "無法比對（證件或影片找不到臉）" : sim >= AUTO_FACE ? "影片與證件照為同一人" : sim >= SFACE_SAME ? "相似度偏低，需人工確認" : "影片與證件照不像同一人",
  };
  // 念數字：語音模型會聽錯個別數字。4 碼中錯 1 碼時，其餘活體動作全部確認、單一人臉且人臉比對通過，才視為通過
  const partialOk = SPEECH_PARTIAL_OK && speechPartial && checks.liveness.ok && checks.singleFace.ok && checks.faceMatch.ok;
  checks.speech = {
    ok: live.speech?.match === "exact" || partialOk,
    detail: !live.speech
      ? "沒有念數字的動作"
      : live.speech.match === "exact"
        ? "念出的數字正確"
        : speechPartial
          ? `辨識結果只部分相符（${live.speech.digits || "無"}）${partialOk ? "；其餘活體動作與人臉比對皆通過，接受" : ""}`
          : "聽不到或數字不符",
  };

  // 5. 同一證號是否已屬於其他身分
  const idHash = f.idNumber ? kycIdHash(f.idNumber) : undefined;
  const others = idHash
    ? Object.entries((await read()).kyc).filter(([a, r]) => a.toLowerCase() !== account.toLowerCase() && r.idHash === idHash && r.level >= 2).map(([a]) => a)
    : [];
  checks.duplicate = { ok: others.length === 0, detail: others.length ? `此統一編號已綁定其他 CAFECA 身分（${others.length} 個）` : "統一編號未綁定其他身分" };

  // 6. 翻拍特徵（僅記錄）
  const df = (c.docFeatures ?? {}) as { front?: { glare?: number; moire?: number; sharpness?: number } };
  scores.glare = df.front?.glare ?? null;
  scores.moire = df.front?.moire ?? null;
  scores.sharpness = df.front?.sharpness ?? null;

  Object.assign(scores, {
    faceSimilarity: sim === null ? null : round(sim),
    faceRatio: round(live.faceRatio),
    multiFaceRatio: round(live.multiFaceRatio),
    actionsConfirmed: okActions,
    speechMatch: live.speech?.match ?? null,
    speechDigits: live.speech?.digits ?? null,
    ocrId: !!f.idNumber,
  });
  for (const a of live.actions) scores[`action_${a.action}`] = a.value;

  if (idEmb || videoEmb) await writeEmbeddings(account, c.id, { id: idEmb ? Array.from(idEmb) : undefined, video: videoEmb ? Array.from(videoEmb) : undefined });

  const allOk = ["ocr", "fields", "idFace", "liveness", "singleFace", "speech", "faceMatch", "duplicate"].every((k) => checks[k]?.ok);
  const clearlyOther = sim !== null && sim < REJECT_FACE;
  const noFaceVideo = live.faceRatio < 0.2;
  const status: KycCase["status"] = clearlyOther || noFaceVideo ? "rejected" : allOk && AUTO_APPROVE ? "approved" : "review";
  if (clearlyOther) checks.decision = { ok: false, detail: "影片中的人與證件照明顯不同" };
  else if (noFaceVideo) checks.decision = { ok: false, detail: "臉部影像中幾乎偵測不到臉，請在光線充足處重新錄製" };

  return {
    ...c,
    account,
    checks,
    scores,
    fields: f.idNumber || f.name
      ? { name: f.name ?? undefined, birthday: f.birthday ?? undefined, sex: f.sex ?? undefined, docType: f.docType ?? undefined, issueDate: f.issueDate ?? undefined, nationality: f.docType === "national_id" ? "TW" : undefined, idNumberHash: idHash }
      : null,
    status,
    decidedBy: status === "review" ? undefined : "auto",
    processedAt: Date.now(),
  };
}

/**
 * 恢復身分：新案件與開戶案件是否為同一人。
 * 兩個條件都要成立：統一編號 HMAC 相同、兩段影片（或證件照）的人臉相似度 ≥ AUTO_FACE。
 */
export async function sameSubject(account: string, prev: KycCase, next: KycCase): Promise<{ ok: boolean; detail: string }> {
  if (PROTOTYPE_AUTO_APPROVE) return { ok: true, detail: "KYC_PROTOTYPE_AUTO_APPROVE=1：未比對（僅限開發）" };
  const idSame = !!prev.fields?.idNumberHash && prev.fields.idNumberHash === next.fields?.idNumberHash;
  const [a, b] = await Promise.all([readCaseFile(account, prev.id).catch(() => null), readCaseFile(account, next.id).catch(() => null)]);
  const va = a?.embeddings?.video ?? a?.embeddings?.id, vb = b?.embeddings?.video ?? b?.embeddings?.id;
  const sim = va && vb ? va.reduce((s, x, i) => s + x * vb[i], 0) : null;
  const faceOk = sim !== null && sim >= AUTO_FACE;
  return {
    ok: idSame && faceOk,
    detail: `${idSame ? "統一編號相同" : "統一編號不同或無法辨識"}；人臉相似度 ${sim === null ? "無法計算" : sim.toFixed(2)}`,
  };
}
