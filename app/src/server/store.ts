import "server-only";
import { promises as fs } from "fs";
import path from "path";

/** 原型用的 JSON 檔案儲存（data/store.json）。正式環境換成資料庫。 */

export type ChatEnvelope = { iv: string; ct: string };
export type ChatMessage = {
  id: string;
  from: string; // address 或 "system"
  to: string;
  fromDevice?: string;
  kind: "text" | "pay.request" | "pay.receipt" | "pay.transfer" | "file" | "location" | "agent.intent" | "system";
  /** 端對端加密內容：deviceId → 密文（system 訊息為明文 body） */
  envelopes?: Record<string, ChatEnvelope>;
  body?: unknown;
  ts: number;
};

export type AgentRecord = {
  owner: string;
  name: string;
  salt: string;
  operatorKey: string; // 測試網：伺服器保管（代表 TEE），正式版放在 TDX enclave
  operator: string;
  channel?: string;
  createdAt: number;
  log: { ts: number; text: string; tx?: string }[];
};

export type VisaAuth = {
  id: string;
  channel: string;
  owner: string;
  merchant: string;
  amount: string;
  status: "authorized" | "captured" | "released";
  captured?: string;
  txs: string[];
  ts: number;
};

export type Store = {
  handles: Record<string, string>; // handle → address
  profiles: Record<string, { handle: string; iss: string; createdAt: number; changedAt?: number }>;
  /** 變更代稱後保留的舊代稱（舊代稱 → 原擁有者），其他人不能註冊 */
  retiredHandles?: Record<string, string>;
  /** 代稱變更付款（交易雜湊 → 付款紀錄） */
  handleFees?: Record<string, { owner: string; paidAt: number; used: boolean; usedFor?: string; usedAt?: number }>;
  messages: ChatMessage[];
  agents: Record<string, AgentRecord>; // id → record
  visa: VisaAuth[];
  visaChannels: Record<string, string>; // owner → channel
  /** 模擬 KYC 單位保存的紀錄：身分證字號只存 HMAC，用於重新 KYC 恢復時比對本人 */
  kyc: Record<string, KycRecord>;
  /** 活體驗證挑戰（一次性） */
  kycChallenges: Record<string, { code: string; actions: string[]; exp: number; used: boolean }>;
  /** 實體卡訂單：以鏈上付款交易為憑 */
  cardOrders: Record<string, CardOrder>;
  /** 裝置配對 session：新裝置只知道自己的公鑰，既有裝置確認後把身分地址回填 */
  pairings: Record<string, Pairing>;
  /** 票券（活動、交通等），由票券發行方簽章，持有人以數位身分出示 */
  tickets: Record<string, Ticket>;
  /** 身分狀態同步進度（處理到哪個區塊的 RecoveryExecuted） */
  /** 法人帳戶（規格 §16.4）：法人地址（小寫）→ 驗證紀錄；一個統編只能綁一個法人帳戶 */
  entities?: Record<string, EntityRecord>;
  /** 工商憑證綁定挑戰（一次性，10 分鐘） */
  moeacaChallenges?: Record<string, { entity: string; account: string; tbs: string; exp: number; used: boolean }>;
  /** 聊天附件（檔案內容在傳送端就以一次性金鑰加密，伺服器只保存密文；金鑰在端對端加密的訊息裡） */
  chatBlobs?: Record<string, { from: string; to: string; size: number; createdAt: number }>;
  identitySync?: { lastBlock: number; log: { account: string; block: number; action: "reattest" | "suspend" | "skip"; tx?: string; at: number }[] };
  /** 依賴方（資料調閱 API 的使用者，規格 §16.6 P2）：id → 登記資料；API 金鑰只存 SHA-256 */
  relyingParties?: Record<string, RelyingParty>;
  /** 資料調閱申請 */
  disclosures?: Record<string, Disclosure>;
  /** 條款同意紀錄（P3-B2）：帳戶（小寫）→ 每次同意的版本、內容雜湊、時間與 Passkey 簽章 */
  termsConsents?: Record<string, { version: string; hash: string; at: number; signature: string }[]>;
  /** 稽核紀錄上鏈紀錄（P3-A6） */
  auditAnchors?: { count: number; head: string; tx: string; block: number; at: number }[];
  /** 管理後台人員（P3-A3）：每人一個帳號、以 Passkey 登入 */
  staff?: Record<string, Staff>;
  /** 人員邀請碼（只存 SHA-256；72 小時、一次性） */
  staffInvites?: Record<string, { name: string; roles: StaffRole[]; staffId?: string; by: string; exp: number; used: boolean }>;
};

export type StaffRole = "admin" | "kyc" | "disclosure" | "limits" | "audit";

export type Staff = {
  id: string;
  name: string;
  roles: StaffRole[];
  passkeys: { credentialId: string; qx: string; qy: string; label: string; addedAt: number; lastUsedAt?: number }[];
  active: boolean;
  createdAt: number;
  createdBy: string;
  lastLoginAt?: number;
};

export type RelyingParty = {
  id: string;
  name: string;
  ubn?: string;
  /** 與 Sign in with CAFECA 的 domain 相同（origin） */
  domains: string[];
  contact: string;
  keyHash: string;
  /** 資料包加密用 P-256 公鑰 */
  encJwk: { kty: string; crv: string; x: string; y: string };
  createdAt: number;
  createdBy: string;
  active: boolean;
  /** 資料處理約定（DPA）：未簽署不能使用 API（P3-B3） */
  dpa?: { version: string; signedAt: string; recordedBy: string; recordedAt: number };
};

export type Disclosure = {
  id: string;
  rp: string;
  account: string;
  fields: ("legal_name" | "birthday" | "sex" | "doc_type" | "nationality" | "issue_date" | "kyc_history" | "doc_images" | "entity")[];
  legalBasis: { type: "court" | "prosecutor" | "police" | "aml" | "consent"; ref: string; text: string };
  caseRef?: string;
  reason: string;
  relationship: { type: "signin" | "pairwise" | "none"; detail: string };
  /** 司法機關要求暫緩通知當事人，到這個時間前使用者看不到 */
  noticeDeferredUntil?: number;
  status: "consent" | "review" | "approved1" | "released" | "rejected";
  consent?: { status: "pending" | "granted" | "denied" | "expired"; at?: number; signature?: string; expiresAt?: number };
  /** 應回應期限（司法機關文書所載，或依政策的工作天數；同意類在當事人同意後起算） */
  dueAt?: number;
  /** 依賴方提出的回應期限（文書所載） */
  respondBy?: number;
  /** [0] 第一位核准，[1] 第二位放行（不同人） */
  approvals: { who: string; at: number; fields: Disclosure["fields"]; note?: string }[];
  rejection?: { by: string; at: number; reason: string };
  release?: { at: number; by: string; expiresAt: number; fetched: number[] };
  createdAt: number;
};

export type GcisCompany = {
  ubn: string;
  name: string;
  status: string;
  responsible: string;
  changeDate: string;
  setupDate: string;
  location: string;
  capital: number;
  fetchedAt: number;
};

export type EntityRecord = {
  entity: string;
  /** 建立者（第一位 ADMIN） */
  creator: string;
  displayName?: string;
  createdAt: number;
  /** 最近一次驗證申請 */
  application?: {
    id: string;
    ubn: string;
    applicant: string;
    applicantName: string | null;
    at: number;
    path: "representative" | "agent" | "moeaca";
    /** 工商憑證綁定（P1.5）：驗證過的憑證摘要 */
    moeaca?: { ubn: string; companyName: string; cardRank: string; serial: string; notAfter: string; fingerprint256: string; testPki: boolean };
    status: "pending" | "review" | "approved" | "rejected";
    gcis: GcisCompany | null;
    checks: Record<string, { ok: boolean; detail: string }>;
    letter?: string;
    review?: { by: string; at: number; decision: "approved" | "rejected"; note?: string };
  /** 核准後由複核人員更正欄位的紀錄（只記欄位名稱，不記內容） */
  corrections?: { by: string; at: number; fields: string[]; note: string }[];
    result?: { txHash?: string; error?: string };
  };
  /** 已通過的綁定（統編與登記資料快照）；每日監控以這份快照比對 */
  verified?: { ubn: string; name: string; responsible: string; changeDate: string; approvedAt: number; txHash?: string };
  monitor?: { lastCheck: number; status: "ok" | "suspended" | "revoked" | "error"; detail?: string; tx?: string };
};

export type Ticket = {
  owner: string;
  kind: "event" | "transit" | "coupon";
  title: string;
  subtitle: string;
  venue: string;
  startsAt: number;
  seat?: string;
  issuer: string;
  issuedAt: number;
};

export type Pairing = { qx: string; qy: string; rpIdHash: string; name: string; exp: number; createdAt: number; address?: string };

export type KycRecord = {
  /** 切換正式簽章者時標記：原型期的驗證不再有效，需要重新驗證（P3-A5） */
  reverify?: { at: number; reason: string };
  level: number;
  ts: number;
  idHash?: string;
  /** KYC 案件（證件僅保存浮水印版；原始影像從未離開使用者裝置） */
  cases?: KycCase[];
};

export type KycCase = {
  id: string;
  purpose: "onboard" | "recover";
  createdAt: number;
  challenge: string;
  files: { front: string; back: string; face: string };
  hashes: { front: string; back: string; face: string };
  actions: { action: string; startedAt: number; completedAt: number; peak: number }[];
  docFeatures: unknown;
  /** 後台處理結果（團隊自建：OCR、活體重檢、人臉比對、翻拍偵測） */
  status: "pending" | "processing" | "approved" | "review" | "rejected";
  checks: Record<string, { ok: boolean; detail: string }>;
  /** 擷取出的欄位（不保存統一編號原文與住址，只保存統一編號 HMAC） */
  fields?: { name?: string; birthday?: string; sex?: string; docType?: string; issueDate?: string; nationality?: string; idNumberHash?: string } | null;
  /** 身分帳戶（新案件才有；舊案件以所在的 kyc[account] 為準） */
  account?: string;
  /** 各模組分數（決策紀錄，供稽核） */
  scores?: Record<string, number | string | boolean | null>;
  decidedBy?: "auto" | "reviewer" | "prototype";
  review?: { by: string; at: number; decision: "approved" | "rejected"; note?: string };
  /** 核准後由複核人員更正欄位的紀錄（只記欄位名稱，不記內容） */
  corrections?: { by: string; at: number; fields: string[]; note: string }[];
  /** 恢復案件：新裝置金鑰，核准後由平台備援金鑰發起 initiateRecovery */
  recovery?: { qx: string; qy: string; rpIdHash: string };
  /** 核准後的鏈上結果 */
  result?: { txHash?: string; recoveryTx?: string; readyAt?: number; error?: string };
  processedAt?: number;
  /** 保存期限到期、證件影像與臉部影片已清除的時間（P3-B5） */
  purgedAt?: number;
  /** 背景驗證嘗試次數（伺服器中途重啟時避免同一案件反覆讓程序當掉） */
  attempts?: number;
};

export type CardOrder = { owner: string; txHash: string; amount: string; paidAt: number; used: boolean; replaces?: string; issuedFor?: string };

const FILE = path.join(process.cwd(), "data", "store.json");
const EMPTY: Store = { handles: {}, profiles: {}, messages: [], agents: {}, visa: [], visaChannels: {}, kyc: {}, kycChallenges: {}, cardOrders: {}, pairings: {}, tickets: {} };

let lock: Promise<unknown> = Promise.resolve();

async function load(): Promise<Store> {
  try {
    return { ...EMPTY, ...JSON.parse(await fs.readFile(FILE, "utf8")) };
  } catch {
    return structuredClone(EMPTY);
  }
}

export async function read(): Promise<Store> {
  await lock.catch(() => undefined);
  return load();
}

export function update<T>(fn: (s: Store) => T | Promise<T>): Promise<T> {
  const run = async () => {
    const s = await load();
    const out = await fn(s);
    await fs.mkdir(path.dirname(FILE), { recursive: true });
    await fs.writeFile(FILE + ".tmp", JSON.stringify(s, null, 2));
    await fs.rename(FILE + ".tmp", FILE);
    return out;
  };
  const next = lock.then(run, run);
  lock = next.catch(() => undefined);
  return next;
}
