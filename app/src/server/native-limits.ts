import "server-only";
import { decodeAbiParameters, parseEther, zeroAddress, type Address, type Hex } from "viem";
import { DEPLOYMENT } from "@/lib/config";
import { keyringValidatorAbi } from "@/lib/contracts/abis";
import { writeAudit } from "./audit";
import { operatorTx, publicClient } from "./chain";
import { limitAdmin } from "./limits";
import { HttpError } from "./session";

/**
 * BOLT（原生幣）轉帳額度。
 *
 * 新版工廠（IdentityAccountFactory／EntityAccountFactory 帶 nativePerTx／nativeDaily）開戶時就設好平台預設
 * BOLT 額度，開戶即可轉帳 BOLT。舊工廠建立的帳戶原生幣額度是 0，任何 BOLT 轉出都會被判定超額（沒有卡片就拒絕），
 * 這裡提供「啟用平台預設 BOLT 額度」補上：
 *   - KeyringValidator v2：由 limitAdmin（營運錢包／多簽）以 setLimitsFor 設定，原因碼 5
 *   - v1（目前的測試網）：只能由帳戶自己設定；bundler 只放行「從 0 設為平台預設值」這一種，
 *     合約仍要求實體卡確認，或排程 72 小時後生效
 * 預設值：NATIVE_DEFAULT_PER_TX（BOLT，預設 10）、NATIVE_DEFAULT_DAILY（預設 50）。
 */

export const nativeDefaults = () => ({
  perTx: parseEther(process.env.NATIVE_DEFAULT_PER_TX ?? "10"),
  daily: parseEther(process.env.NATIVE_DEFAULT_DAILY ?? "50"),
});

export async function nativeLimitsOf(account: Address) {
  const [[perTx, daily], [spent, windowStart]] = await Promise.all([
    publicClient.readContract({ address: DEPLOYMENT.keyring, abi: keyringValidatorAbi, functionName: "limits", args: [zeroAddress, account] }),
    publicClient.readContract({ address: DEPLOYMENT.keyring, abi: keyringValidatorAbi, functionName: "spent", args: [zeroAddress, account] }),
  ]);
  const now = Number((await publicClient.getBlock()).timestamp);
  return { perTx, daily, spent: now - Number(windowStart) < 86400 ? spent : 0n };
}

export async function nativeStatus(account: Address) {
  const [l, admin] = await Promise.all([nativeLimitsOf(account), limitAdmin()]);
  const d = nativeDefaults();
  return {
    perTx: l.perTx.toString(),
    daily: l.daily.toString(),
    spent: l.spent.toString(),
    enabled: l.perTx > 0n || l.daily > 0n,
    defaults: { perTx: d.perTx.toString(), daily: d.daily.toString() },
    // admin：伺服器代為設定（v2）；self：帳戶自己設定（v1，需要卡片或排程）
    mode: admin ? ("admin" as const) : ("self" as const),
  };
}

/** v2：由 limitAdmin 為帳戶設定平台預設 BOLT 額度（只在目前為 0 時） */
export async function enableNativeDefaults(account: Address) {
  if (!(await limitAdmin())) throw new HttpError(409, "目前的合約版本需要由帳戶自己設定（實體卡確認或排程 72 小時）");
  const st = await publicClient.readContract({ address: DEPLOYMENT.keyring, abi: keyringValidatorAbi, functionName: "accountState", args: [account] });
  if (!st[2]) throw new HttpError(404, "這個帳戶還沒有開通");
  const l = await nativeLimitsOf(account);
  if (l.perTx > 0n || l.daily > 0n) throw new HttpError(409, "BOLT 額度已經設定過；要調整請聯絡客服");
  const d = nativeDefaults();
  const rc = await operatorTx({ address: DEPLOYMENT.keyring, abi: keyringValidatorAbi, functionName: "setLimitsFor", args: [account, zeroAddress, d.perTx, d.daily, 5] } as never);
  await writeAudit({ who: `user:${account}`, action: "limits.native.default", account, perTx: d.perTx.toString(), daily: d.daily.toString(), tx: rc.transactionHash });
  return rc.transactionHash;
}

/** bundler 例外：帳戶自己把 BOLT 額度從 0 設為平台預設值（v1）。其他額度變更一律拒絕 */
export async function isNativeDefaultInit(account: Address, fn: string, args: readonly unknown[]): Promise<boolean> {
  let token: Address, perTx: bigint, daily: bigint;
  try {
    if (fn === "setLimits") [token, perTx, daily] = args as [Address, bigint, bigint];
    else [token, perTx, daily] = decodeAbiParameters([{ type: "address" }, { type: "uint128" }, { type: "uint128" }], args[1] as Hex) as [Address, bigint, bigint];
  } catch {
    return false;
  }
  const d = nativeDefaults();
  if (token.toLowerCase() !== zeroAddress || perTx !== d.perTx || daily !== d.daily) return false;
  const l = await nativeLimitsOf(account).catch(() => null);
  return !!l && l.perTx === 0n && l.daily === 0n;
}
