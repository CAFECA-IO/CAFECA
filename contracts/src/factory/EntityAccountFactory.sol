// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CafecaAccount} from "../account/CafecaAccount.sol";
import {MemberValidator} from "../modules/MemberValidator.sol";

/// @title EntityAccountFactory
/// @notice 法人帳戶（規格 §16.4）：與自然人帳戶使用同一份 CafecaAccount，但唯一的 validator 是 MemberValidator。
///         法人沒有自己的金鑰；第一位 ADMIN（通常是代表人）必須是有效 L2 的 CAFECA 身分。
///         account = CREATE2(salt = keccak256(firstAdmin, salt))，地址與統編無關；統編 ↔ 地址的綁定由 KYC 後台
///         在查核商工登記後，以 IdentityRegistry v2 簽發 subjectType = 1 的證明（一個統編只綁一個法人帳戶）。
contract EntityAccountFactory {
    address public immutable accountImpl;
    address public immutable memberValidator;
    address public immutable defaultToken;
    uint128 public immutable defaultPerTx;
    uint128 public immutable defaultDaily;
    /// @notice 原生幣（BOLT）預設額度（token = address(0)）
    uint128 public immutable nativePerTx;
    uint128 public immutable nativeDaily;

    event EntityCreated(address indexed entity, address indexed firstAdmin, bytes32 salt);

    constructor(
        address accountImpl_,
        address memberValidator_,
        address defaultToken_,
        uint128 defaultPerTx_,
        uint128 defaultDaily_,
        uint128 nativePerTx_,
        uint128 nativeDaily_
    ) {
        nativePerTx = nativePerTx_;
        nativeDaily = nativeDaily_;
        accountImpl = accountImpl_;
        memberValidator = memberValidator_;
        defaultToken = defaultToken_;
        defaultPerTx = defaultPerTx_;
        defaultDaily = defaultDaily_;
    }

    function saltOf(address firstAdmin, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(firstAdmin, salt));
    }

    function getAddress(address firstAdmin, bytes32 salt) public view returns (address) {
        return Clones.predictDeterministicAddress(accountImpl, saltOf(firstAdmin, salt));
    }

    /// @notice 只有第一位 ADMIN 本人（其身分帳戶）能建立，避免別人以他的名義開法人帳戶
    function createEntity(bytes32 salt) external returns (address entity) {
        address admin = msg.sender;
        bytes32 s = saltOf(admin, salt);
        entity = Clones.predictDeterministicAddress(accountImpl, s);
        if (entity.code.length > 0) return entity;
        Clones.cloneDeterministic(accountImpl, s);

        address[] memory validators = new address[](1);
        validators[0] = memberValidator;
        bool native = nativeDaily > 0;
        MemberValidator.LimitInit[] memory lims = new MemberValidator.LimitInit[](native ? 2 : 1);
        lims[0] = MemberValidator.LimitInit(defaultToken, defaultPerTx, defaultDaily);
        if (native) lims[1] = MemberValidator.LimitInit(address(0), nativePerTx, nativeDaily);
        bytes[] memory vdata = new bytes[](1);
        vdata[0] = abi.encode(admin, lims);
        CafecaAccount(payable(entity)).initialize(validators, vdata, new address[](0), new bytes[](0));
        emit EntityCreated(entity, admin, salt);
    }
}
