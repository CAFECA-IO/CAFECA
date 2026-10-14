// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CafecaAccount} from "../account/CafecaAccount.sol";
import {KeyringValidator} from "../modules/KeyringValidator.sol";

/// @title IdentityAccountFactory
/// @notice 數位身分以「第一把 FIDO2 金鑰」為根（規格 §3、§4.4）：
///         account = CREATE2(salt = keccak256(qx, qy))，部署時把這把金鑰安裝為第一把 DAILY 金鑰。
/// @dev 不需要任何登入證明：
///      - 地址由公鑰決定，initCode 的參數完全由 salt 約束，別人代為部署也只會得到「由這把金鑰控制」的帳戶
///      - 以 initCode 部署的第一筆 UserOp 必須由該 passkey 簽章，證明持有私鑰
///      濫用防護（大量建立身分套取 gas 贊助）由 paymaster 額度與伺服器端頻率限制處理（規格 §8）。
contract IdentityAccountFactory {
    address public immutable accountImpl;
    address public immutable keyring;
    address public immutable recovery;

    address public immutable defaultToken;
    uint128 public immutable defaultPerTx;
    uint128 public immutable defaultDaily;
    /// @notice 原生幣（BOLT）預設額度：開戶即可轉出 BOLT（token = address(0)）
    uint128 public immutable nativePerTx;
    uint128 public immutable nativeDaily;

    event AccountCreated(address indexed account, bytes32 indexed rootKeyId);

    constructor(
        address accountImpl_,
        address keyring_,
        address recovery_,
        address defaultToken_,
        uint128 defaultPerTx_,
        uint128 defaultDaily_,
        uint128 nativePerTx_,
        uint128 nativeDaily_
    ) {
        accountImpl = accountImpl_;
        keyring = keyring_;
        recovery = recovery_;
        defaultToken = defaultToken_;
        defaultPerTx = defaultPerTx_;
        defaultDaily = defaultDaily_;
        nativePerTx = nativePerTx_;
        nativeDaily = nativeDaily_;
    }

    /// @notice 身分根金鑰 ID（與 KeyringValidator.keyIdOf 相同）
    function rootKeyId(bytes32 qx, bytes32 qy) public pure returns (bytes32) {
        return keccak256(abi.encode(qx, qy));
    }

    function getAddress(bytes32 qx, bytes32 qy) public view returns (address) {
        return Clones.predictDeterministicAddress(accountImpl, rootKeyId(qx, qy));
    }

    function createAccount(bytes32 qx, bytes32 qy, bytes32 rpIdHash) external returns (address account) {
        bytes32 salt = rootKeyId(qx, qy);
        account = Clones.predictDeterministicAddress(accountImpl, salt);
        if (account.code.length > 0) return account;

        Clones.cloneDeterministic(accountImpl, salt);

        address[] memory validators = new address[](2);
        validators[0] = keyring;
        validators[1] = recovery;

        bool native = nativeDaily > 0;
        KeyringValidator.LimitInit[] memory lims = new KeyringValidator.LimitInit[](native ? 2 : 1);
        lims[0] = KeyringValidator.LimitInit(defaultToken, defaultPerTx, defaultDaily);
        if (native) lims[1] = KeyringValidator.LimitInit(address(0), nativePerTx, nativeDaily);
        bytes[] memory vdata = new bytes[](2);
        vdata[0] = abi.encode(KeyringValidator.KeyInit(qx, qy, rpIdHash), lims);
        vdata[1] = "";

        CafecaAccount(payable(account)).initialize(validators, vdata, new address[](0), new bytes[](0));
        emit AccountCreated(account, salt);
    }
}
