/**
 * 部署 CAFECA 合約到 Boltchain 測試網
 *
 *   npm run deploy
 *
 * 第一次執行：自動產生部署者私鑰（DEPLOYER_PRIVATE_KEY）並印出地址，請轉 BOLT 進去後再執行一次。
 * 也會自動產生其餘服務金鑰（paymaster 簽章、發卡方、KYC、Visa 處理商、商家）並寫回 .env.local，
 * 部署結果預設寫入 deployments/boltchain-testnet.local.json（不進 git）；
 * 要更新團隊共用的 deployments/boltchain-testnet.json 時加 --publish（npm run deploy -- --publish）。
 *
 * 增量部署法人帳戶（規格 §16.4）：npm run deploy -- --entity
 *   只部署 MemberValidator 與 EntityAccountFactory（讀 IdentityRegistry v2），不動既有自然人帳戶。
 *
 * 增量部署稽核紀錄上鏈合約（規格 §16.6 P3-A6）：npm run deploy -- --anchor
 *
 * 增量部署 IdentityRegistry v2（規格 §16.2）：npm run deploy -- --identity
 *   不動工廠與 KeyringValidator（既有身分地址不變），部署 v2、把 v1 仍有效的證明以同一把 KYC 金鑰簽發到 v2，
 *   並重新部署改讀 v2 的 CafecaPaymaster（取回舊 paymaster 的押金）。完成後重新啟動 npm run dev／start。
 */
import { readFileSync, writeFileSync, existsSync } from "fs";
import path from "path";
import {
  createPublicClient,
  createWalletClient,
  formatEther,
  getAddress,
  getContractAddress,
  http,
  parseEther,
  parseUnits,
  toHex,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { parseAbiItem } from "viem";
import { p256 } from "@noble/curves/p256";
import { sha256 } from "@noble/hashes/sha256";

/** 新帳戶預設的 BOLT（原生幣）額度：開戶即可轉帳 BOLT（與 server/native-limits.ts 一致） */
function native(env: Record<string, string>) {
  const v = (k: string, d: string) => parseEther(process.env[k] ?? env[k] ?? d);
  return [v("NATIVE_DEFAULT_PER_TX", "10"), v("NATIVE_DEFAULT_DAILY", "50")] as const;
}

const ROOT = process.cwd();
const ENV_FILE = path.join(ROOT, ".env.local");
// 預設寫入本機專用、不進 git 的 .local.json；加 --publish 才更新 git 追蹤的共用部署檔
const SHARED_FILE = path.join(ROOT, "deployments", "boltchain-testnet.json");
const LOCAL_FILE = path.join(ROOT, "deployments", "boltchain-testnet.local.json");
const OUT_FILE = process.argv.includes("--publish") ? SHARED_FILE : LOCAL_FILE;
const IN_FILE = existsSync(OUT_FILE) ? OUT_FILE : SHARED_FILE;

function parseEnv(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^['"]|['"]$/g, "");
  }
  return out;
}

function artifact(name: string): { abi: Abi; bytecode: Hex } {
  return JSON.parse(readFileSync(path.join(ROOT, "scripts", "artifacts", `${name}.json`), "utf8"));
}

async function main() {
  const envText = existsSync(ENV_FILE) ? readFileSync(ENV_FILE, "utf8") : "";
  const env = parseEnv(envText);
  // 產生缺少的金鑰（含部署者私鑰）
  const gen: Record<string, () => Promise<string> | string> = {
    DEPLOYER_PRIVATE_KEY: generatePrivateKey,
    RPC_URL: () => "https://boltchain.cafeca.io",
    PAYMASTER_SIGNER_KEY: generatePrivateKey,
    CARD_ISSUER_KEY: generatePrivateKey,
    KYC_SIGNER_KEY: generatePrivateKey,
    VISA_OPERATOR_KEY: generatePrivateKey,
    MERCHANT_KEY: generatePrivateKey,
    // 平台根金鑰（正式版離線保存）：授權安裝與輪替每個帳戶的平台備援金鑰
    GUARDIAN_ROOT_KEY: generatePrivateKey,
    // 衍生每個帳戶備援金鑰的種子（正式版：HSM 內每個帳戶產生獨立金鑰，不可匯出）
    GUARDIAN_SEED: () => toHex(crypto.getRandomValues(new Uint8Array(32))),
    SESSION_SECRET: () => toHex(crypto.getRandomValues(new Uint8Array(32))),
    // KYC 人工複核後台（/admin/kyc）的登入密碼
    KYC_REVIEW_TOKEN: () => toHex(crypto.getRandomValues(new Uint8Array(16))).slice(2),
    // K_pairwise：KYC Credential 的 pairwise_id（§16.3），與 SESSION_SECRET 衍生的 kycIdHash 金鑰分開
    KYC_PAIRWISE_KEY: () => toHex(crypto.getRandomValues(new Uint8Array(32))).slice(2),
    // 資料調閱資料包的 ES256 簽章金鑰（P-256 私鑰 hex；公鑰公布在 /.well-known/cafeca-configuration 的 disclosure.jwks）
    DISCLOSURE_SIGNING_KEY: () => Buffer.from(p256.utils.randomPrivateKey()).toString("hex"),
  };
  let appended = "";
  for (const [k, fn] of Object.entries(gen)) {
    if (env[k] === undefined) {
      env[k] = await fn();
      appended += `${k}=${env[k]}\n`;
    }
  }
  if (appended) {
    writeFileSync(ENV_FILE, envText + (envText.endsWith("\n") || !envText ? "" : "\n") + "\n# 由 npm run deploy 產生\n" + appended);
    console.log("已產生服務金鑰並寫入 .env.local");
  }

  const rpc = env.RPC_URL;
  const deployer = privateKeyToAccount(env.DEPLOYER_PRIVATE_KEY as Hex);
  const pub = createPublicClient({ transport: http(rpc, { timeout: 60_000 }) });
  const chainId = await pub.getChainId();
  const chain = {
    id: chainId,
    name: "Boltchain Testnet",
    nativeCurrency: { name: "BOLT", symbol: "BOLT", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  } as const;
  const wallet = createWalletClient({ account: deployer, chain, transport: http(rpc, { timeout: 120_000 }) });

  const balance = await pub.getBalance({ address: deployer.address });
  console.log(`chainId ${chainId}，部署者 ${deployer.address}，餘額 ${formatEther(balance)} BOLT`);
  const factoryOnly = process.argv.includes("--factory");
  const identityOnly = process.argv.includes("--identity");
  const entityOnly = process.argv.includes("--entity");
  const anchorOnly = process.argv.includes("--anchor");
  const deposit = factoryOnly ? 0n : parseEther(env.PAYMASTER_DEPOSIT ?? "5");
  const stake = factoryOnly ? 0n : parseEther(env.PAYMASTER_STAKE ?? "1");
  if (!identityOnly && !entityOnly && balance < deposit + stake + parseEther(factoryOnly ? "0.2" : "1")) {
    console.error(`\n部署者地址：${deployer.address}`);
    console.error(`請轉入 BOLT 到這個地址（目前 ${formatEther(balance)} BOLT），再執行一次 npm run deploy。`);
    console.error("私鑰已存在 .env.local 的 DEPLOYER_PRIVATE_KEY，請妥善保管。\n");
    console.error(`餘額不足：需要至少 ${formatEther(deposit + stake + parseEther("1"))} BOLT（paymaster 押金＋質押＋部署 gas）`);
    process.exit(1);
  }

  // P-256 precompile 檢查（EIP-7951 / RIP-7212，位址 0x100）
  {
    const priv = p256.utils.randomPrivateKey();
    const pt = p256.getPublicKey(priv, false);
    const h = sha256(new TextEncoder().encode("cafeca"));
    const sig = p256.sign(h, priv, { lowS: true });
    const input = toHex(new Uint8Array([...h, ...hexBytes(sig.r), ...hexBytes(sig.s), ...pt.slice(1)]));
    const r = await pub.call({ to: "0x0000000000000000000000000000000000000100", data: input }).catch(() => ({ data: undefined }));
    console.log(`P-256 precompile：${r.data && BigInt(r.data) === 1n ? "可用 ✓" : "不可用（合約會改用 Solidity 實作，gas 較高）"}`);
  }

  const block = await pub.getBlock();
  const legacy = block.baseFeePerGas === null || block.baseFeePerGas === undefined;
  const feeOpts = async () => (legacy ? { gasPrice: ((await pub.getGasPrice()) * 12n) / 10n } : {});

  async function deploy(name: string, args: unknown[] = []): Promise<Address> {
    const a = artifact(name);
    const hash = await wallet.deployContract({ abi: a.abi, bytecode: a.bytecode, args, ...(await feeOpts()) } as never);
    const rc = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
    if (rc.status !== "success" || !rc.contractAddress) throw new Error(`${name} 部署失敗 ${hash}`);
    const addr = getAddress(rc.contractAddress);
    console.log(`  ${name.padEnd(24)} ${addr}`);
    return addr;
  }

  async function send(address: Address, name: string, fn: string, args: unknown[] = [], value = 0n) {
    const a = artifact(name);
    const hash = await wallet.writeContract({ address, abi: a.abi, functionName: fn, args, value, ...(await feeOpts()) } as never);
    const rc = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
    if (rc.status !== "success") throw new Error(`${name}.${fn} 失敗 ${hash}`);
  }

  // 只重新部署工廠（其餘合約不變時使用：npm run deploy -- --factory）
  if (factoryOnly) {
    if (!existsSync(IN_FILE)) throw new Error("找不到既有部署，請先完整部署");
    const d = JSON.parse(readFileSync(IN_FILE, "utf8"));
    if (!d.deployed || d.chainId !== chainId) throw new Error("既有部署不在這條鏈上，請先完整部署");
    console.log("只重新部署 IdentityAccountFactory…");
    const factory = await deploy("IdentityAccountFactory", [
      d.accountImpl,
      d.keyring,
      d.recovery,
      d.twdc,
      parseUnits("10000", 6),
      parseUnits("30000", 6),
      ...native(env),
    ]);
    writeFileSync(OUT_FILE, JSON.stringify({ ...d, factory }, null, 2) + "\n");
    console.log(`完成 ✓ 舊工廠 ${d.factory} → 新工廠 ${factory}`);
    console.log("注意：帳戶地址由工廠地址決定，舊工廠建立的測試錢包需重新開戶。");
    return;
  }

  const kycSigner = privateKeyToAccount(env.KYC_SIGNER_KEY as Hex);
  const pmSigner = privateKeyToAccount(env.PAYMASTER_SIGNER_KEY as Hex).address;
  /** KYC_SIGNER_CLASS=PRODUCTION 只在正式 KYC 後台上線、換上 HSM 金鑰後使用；原型期一律 PROTOTYPE */
  const signerCls = env.KYC_SIGNER_CLASS === "PRODUCTION" ? 2 : 1;

  async function deployPaymaster(entryPoint: Address, registry: Address, channelManager: Address) {
    const paymaster = await deploy("CafecaPaymaster", [entryPoint, pmSigner, registry, channelManager]);
    await send(paymaster, "CafecaPaymaster", "setTier", [0, parseEther("5"), 30]);
    await send(paymaster, "CafecaPaymaster", "setTier", [1, parseEther("15"), 100]);
    await send(paymaster, "CafecaPaymaster", "setTier", [2, parseEther("50"), 300]);
    await send(paymaster, "CafecaPaymaster", "deposit", [], deposit);
    await send(paymaster, "CafecaPaymaster", "addStake", [86400], stake);
    return paymaster;
  }

  // 增量部署 IdentityRegistry v2：npm run deploy -- --identity
  if (identityOnly) {
    if (!existsSync(IN_FILE)) throw new Error("找不到既有部署，請先完整部署");
    const d = JSON.parse(readFileSync(IN_FILE, "utf8"));
    if (!d.deployed || d.chainId !== chainId) throw new Error("既有部署不在這條鏈上，請先完整部署");
    if (d.identityRegistry && !process.argv.includes("--force")) throw new Error(`已經部署過 IdentityRegistry（${d.identityRegistry}）；要重新部署請加 --force`);

    // 1. 取回舊 paymaster 的押金（質押需等 unlockStake 的延遲，留在原處）
    const oldDeposit = (await pub.readContract({ address: d.paymaster, abi: artifact("CafecaPaymaster").abi, functionName: "getDeposit" })) as bigint;
    if (oldDeposit > 0n) {
      await send(d.paymaster, "CafecaPaymaster", "withdrawTo", [deployer.address, oldDeposit]);
      console.log(`  取回舊 paymaster 押金 ${formatEther(oldDeposit)} BOLT`);
    }
    const bal = await pub.getBalance({ address: deployer.address });
    if (bal < deposit + stake + parseEther("0.5")) {
      throw new Error(`餘額不足：需要 ${formatEther(deposit + stake + parseEther("0.5"))} BOLT，目前 ${formatEther(bal)} BOLT（部署者 ${deployer.address}）`);
    }

    // 2. 部署 v2 並登記 KYC 簽章者
    console.log("部署 IdentityRegistry v2…");
    const identityRegistry = await deploy("IdentityRegistry", [deployer.address]);
    await send(identityRegistry, "IdentityRegistry", "setSigner", [kycSigner.address, signerCls]);
    console.log(`  KYC 簽章者 ${kycSigner.address} → ${signerCls === 2 ? "PRODUCTION" : "PROTOTYPE"}`);

    // 3. 遷移 v1 仍有效的證明（自然人、TW；簽章者等級沿用上面的設定）
    const migrated = await migrateAttestations(d, identityRegistry);
    console.log(`  已遷移 ${migrated} 筆 v1 證明`);

    // 4. 改讀 v2 的 paymaster
    console.log("重新部署 CafecaPaymaster（讀 v2）…");
    const paymaster = await deployPaymaster(d.entryPoint, identityRegistry, d.channelManager);
    writeFileSync(OUT_FILE, JSON.stringify({ ...d, identityRegistry, paymaster, paymasterV1: d.paymaster }, null, 2) + "\n");
    console.log(`完成 ✓ 已寫入 ${path.relative(ROOT, OUT_FILE)}；請重新啟動 npm run dev／start 讓錢包與 bundler 讀到新位址`);
    return;
  }

  /** 法人帳戶：MemberValidator（成員簽署、額度只能由管理者調整）＋工廠；預設額度 單筆 5 萬／每日 20 萬 TWDC */
  async function deployEntity(accountImpl: Address, identityRegistry: Address, twdc: Address) {
    const memberValidator = await deploy("MemberValidator", [identityRegistry, deployer.address]);
    const entityFactory = await deploy("EntityAccountFactory", [accountImpl, memberValidator, twdc, parseUnits("50000", 6), parseUnits("200000", 6), ...native(env)]);
    return { memberValidator, entityFactory };
  }

  if (entityOnly) {
    if (!existsSync(IN_FILE)) throw new Error("找不到既有部署，請先完整部署");
    const d = JSON.parse(readFileSync(IN_FILE, "utf8"));
    if (!d.deployed || d.chainId !== chainId) throw new Error("既有部署不在這條鏈上，請先完整部署");
    if (!d.identityRegistry) throw new Error("需要先部署 IdentityRegistry v2（npm run deploy -- --identity）");
    if (d.entityFactory && !process.argv.includes("--force")) throw new Error(`已經部署過法人帳戶合約（${d.entityFactory}）；要重新部署請加 --force`);
    console.log("部署法人帳戶合約…");
    const e = await deployEntity(d.accountImpl, d.identityRegistry, d.twdc);
    writeFileSync(OUT_FILE, JSON.stringify({ ...d, ...e }, null, 2) + "\n");
    console.log(`完成 ✓ 已寫入 ${path.relative(ROOT, OUT_FILE)}；請重新建置並啟動（npm run build／start）`);
    return;
  }

  if (anchorOnly) {
    if (!existsSync(IN_FILE)) throw new Error("找不到既有部署，請先完整部署");
    const d = JSON.parse(readFileSync(IN_FILE, "utf8"));
    if (!d.deployed || d.chainId !== chainId) throw new Error("既有部署不在這條鏈上，請先完整部署");
    if (d.auditAnchor && !process.argv.includes("--force")) throw new Error(`已經部署過 AuditAnchor（${d.auditAnchor}）；要重新部署請加 --force`);
    const auditAnchor = await deploy("AuditAnchor", [deployer.address]);
    writeFileSync(OUT_FILE, JSON.stringify({ ...d, auditAnchor }, null, 2) + "\n");
    console.log(`完成 ✓ 已寫入 ${path.relative(ROOT, OUT_FILE)}；請重新建置並啟動（npm run build／start）`);
    return;
  }

  async function migrateAttestations(d: { attestation: Address; startBlock?: number }, registry: Address) {
    const v1 = artifact("AttestationRegistry").abi;
    const v2 = artifact("IdentityRegistry").abi;
    const ev = parseAbiItem("event Attested(address indexed account, uint8 level, uint48 expiry, bytes32 claimsRoot, address signer)");
    const head = await pub.getBlockNumber();
    const accounts = new Set<Address>();
    for (let from = BigInt(d.startBlock ?? 0); from <= head; from += 10_000n) {
      const to = from + 9_999n > head ? head : from + 9_999n;
      for (const l of await pub.getLogs({ address: d.attestation, event: ev, fromBlock: from, toBlock: to })) accounts.add(l.args.account!);
    }
    const now = Math.floor(Date.now() / 1000);
    let n = 0;
    for (const account of accounts) {
      const [level, expiry, claimsRoot, signer] = (await pub.readContract({ address: d.attestation, abi: v1, functionName: "attestations", args: [account] })) as [number, number, Hex, Address];
      if (level === 0 || expiry <= now || signer.toLowerCase() !== kycSigner.address.toLowerCase()) continue;
      const nonce = ((await pub.readContract({ address: registry, abi: v2, functionName: "nonceOf", args: [account] })) as bigint) + 1n;
      const digest = (await pub.readContract({
        address: registry,
        abi: v2,
        functionName: "attestDigest",
        args: [account, 0, level, expiry, claimsRoot, "0x5457", nonce],
      })) as Hex;
      const sig = await kycSigner.sign({ hash: digest });
      await send(registry, "IdentityRegistry", "attest", [account, 0, level, expiry, claimsRoot, "0x5457", nonce, sig]);
      n++;
    }
    return n;
  }

  const startBlock = Number(await pub.getBlockNumber());
  console.log("部署合約…");
  const entryPoint = await deploy("EntryPoint");
  const accountImpl = await deploy("CafecaAccount", [entryPoint]);
  const attestation = await deploy("AttestationRegistry", [deployer.address]);
  const deviceDirectory = await deploy("DeviceDirectory");

  const n = await pub.getTransactionCount({ address: deployer.address, blockTag: "pending" });
  const predict = (k: number) => getContractAddress({ from: deployer.address, nonce: BigInt(n + k) });
  const [pKeyring, pRecovery, pCv, pCm] = [predict(0), predict(1), predict(2), predict(3)];
  // limitAdmin：交易額度只能由管理者調整（測試網＝部署者／營運錢包；正式環境改為多簽）
  const keyring = await deploy("KeyringValidator", [pRecovery, pCm, pCv, deviceDirectory, attestation, deployer.address]);
  const recovery = await deploy("RecoveryValidator", [keyring, attestation]);
  const channelValidator = await deploy("ChannelValidator");
  const channelManager = await deploy("ChannelManager", [accountImpl, channelValidator]);
  const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  if (!same(keyring, pKeyring) || !same(recovery, pRecovery) || !same(channelValidator, pCv) || !same(channelManager, pCm)) {
    throw new Error("預測地址不符，請重新部署");
  }
  const twdc = await deploy("TestStable");
  const factory = await deploy("IdentityAccountFactory", [
    accountImpl,
    keyring,
    recovery,
    twdc,
    parseUnits("10000", 6),
    parseUnits("30000", 6),
    ...native(env),
  ]);
  const identityRegistry = await deploy("IdentityRegistry", [deployer.address]);

  console.log("設定權限與 paymaster…");
  await send(attestation, "AttestationRegistry", "setCardIssuer", [privateKeyToAccount(env.CARD_ISSUER_KEY as Hex).address, true]);
  await send(attestation, "AttestationRegistry", "setKycSigner", [privateKeyToAccount(env.KYC_SIGNER_KEY as Hex).address, true]);
  await send(attestation, "AttestationRegistry", "setGuardianAuthority", [privateKeyToAccount(env.GUARDIAN_ROOT_KEY as Hex).address, true]);
  await send(identityRegistry, "IdentityRegistry", "setSigner", [kycSigner.address, signerCls]);
  const paymaster = await deployPaymaster(entryPoint, identityRegistry, channelManager);
  const { memberValidator, entityFactory } = await deployEntity(accountImpl, identityRegistry, twdc);
  const auditAnchor = await deploy("AuditAnchor", [deployer.address]);

  const out = {
    chainId,
    deployed: true,
    entryPoint,
    accountImpl,
    factory,
    keyring,
    recovery,
    channelValidator,
    channelManager,
    attestation,
    identityRegistry,
    deviceDirectory,
    memberValidator,
    entityFactory,
    auditAnchor,
    paymaster,
    twdc,
    startBlock,
  };
  writeFileSync(OUT_FILE, JSON.stringify(out, null, 2) + "\n");
  console.log(`完成 ✓ 已寫入 ${path.relative(ROOT, OUT_FILE)}`);
  console.log(`剩餘 ${formatEther(await pub.getBalance({ address: deployer.address }))} BOLT`);
}

function hexBytes(v: bigint): number[] {
  return Array.from(Buffer.from(v.toString(16).padStart(64, "0"), "hex"));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
