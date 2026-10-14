// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base} from "./Base.t.sol";
import {CafecaAccount} from "../src/account/CafecaAccount.sol";
import {KeyringValidator} from "../src/modules/KeyringValidator.sol";
import {MemberValidator} from "../src/modules/MemberValidator.sol";
import {EntityAccountFactory} from "../src/factory/EntityAccountFactory.sol";
import {IERC7579ModuleConfig, Execution, MODULE_TYPE_EXECUTOR} from "../src/interfaces/IERC7579.sol";

contract EntityTest is Base {
    MemberValidator internal mv;
    EntityAccountFactory internal ef;

    uint256 internal constant REP = 0x4E90; // 代表人
    uint256 internal constant CLERK = 0xC1E4; // 會計（OPERATOR）
    uint256 internal constant OUTSIDER = 0x0D7; // 非成員
    address internal rep;
    address internal clerk;
    address internal outsider;
    address internal entity;
    address internal vendor = makeAddr("vendor");

    function setUp() public override {
        super.setUp();
        mv = new MemberValidator(address(att), gov);
        ef = new EntityAccountFactory(address(impl), address(mv), address(twdc), 50_000e6, 200_000e6, 1 ether, 5 ether);
        rep = _person(REP);
        clerk = _person(CLERK);
        outsider = _person(OUTSIDER);
        _kyc(rep);
        _kyc(clerk);
        _kyc(outsider);
        vm.prank(rep);
        entity = ef.createEntity(keccak256("acme"));
        twdc.mint(entity, 1_000_000e6);
        vm.deal(entity, 10 ether);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _person(uint256 pk) internal returns (address acct) {
        (bytes32 qx, bytes32 qy) = _pub(pk);
        acct = factory.getAddress(qx, qy);
        factory.createAccount(qx, qy, RP);
    }

    /// @dev 成員帳戶的 ERC-1271 簽章（KeyringValidator、手機 passkey）
    function _sig1271(uint256 pk, bytes32 digest) internal view returns (bytes memory) {
        return abi.encodePacked(address(keyring), abi.encode(KeyringValidator.SignatureData(_keyId(pk), _webauthn(digest, pk, _dailyAuthData()))));
    }

    function _signEntity(PackedUserOperation memory op, address member, uint256 pk) internal view {
        bytes32 h = ep.getUserOpHash(op);
        op.signature = abi.encode(MemberValidator.MemberSig(member, _sig1271(pk, mv.entityHash(op.sender, h))));
    }

    function _verifyEntity() internal {
        bytes32 root = keccak256("ubn:12345678");
        uint48 expiry = uint48(block.timestamp + 365 days);
        att.attest(entity, 2, root, expiry, _ethSign(kycPk, att.attestationDigest(entity, 2, root, expiry)));
    }

    function _pay(address member, uint256 pk, uint256 amount) internal view returns (PackedUserOperation memory op) {
        op = _op(entity, address(mv), _exec(address(twdc), 0, abi.encodeCall(IERC20.transfer, (vendor, amount))));
        _signEntity(op, member, pk);
    }

    function _setMemberOp(address member, MemberValidator.Role role, address signer, uint256 pk)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _op(entity, address(mv), _exec(address(mv), 0, abi.encodeCall(MemberValidator.setMember, (member, role))));
        _signEntity(op, signer, pk);
    }

    // ───────────────────────── 建立 ─────────────────────────

    function test_Create_FirstAdminMustBeL2() public {
        address nobody = _person(0xDEAD1);
        vm.prank(nobody);
        vm.expectRevert(MemberValidator.MemberNotVerified.selector);
        ef.createEntity(keccak256("x"));

        assertEq(ef.getAddress(rep, keccak256("acme")), entity);
        assertEq(uint8(mv.roleOf(rep, entity)), uint8(MemberValidator.Role.ADMIN));
        (uint128 perTx, uint128 daily) = mv.limits(address(twdc), entity);
        assertEq(perTx, 50_000e6);
        assertEq(daily, 200_000e6);
    }

    // ───────────────────────── 成員與權限 ─────────────────────────

    function test_AdminAddsOperator_OperatorPays_AuditEvent() public {
        _verifyEntity();
        _handle(_setMemberOp(clerk, MemberValidator.Role.OPERATOR, rep, REP));
        assertEq(uint8(mv.roleOf(clerk, entity)), uint8(MemberValidator.Role.OPERATOR));

        PackedUserOperation memory op = _pay(clerk, CLERK, 1_000e6);
        vm.expectEmit(true, true, true, false);
        emit MemberValidator.MemberAuthorized(entity, clerk, ep.getUserOpHash(op));
        _handle(op);
        assertEq(twdc.balanceOf(vendor), 1_000e6);
    }

    function test_OperatorCannotManageMembers() public {
        _handle(_setMemberOp(clerk, MemberValidator.Role.OPERATOR, rep, REP));
        _handleExpectFail(_setMemberOp(outsider, MemberValidator.Role.ADMIN, clerk, CLERK));
        _handleExpectFail(_setMemberOp(clerk, MemberValidator.Role.ADMIN, clerk, CLERK));
    }

    function test_MemberMustBeL2() public {
        address nobody = _person(0xDEAD2);
        _handleExpectFail(_setMemberOp(nobody, MemberValidator.Role.OPERATOR, rep, REP));
    }

    function test_NonMemberAndRemovedMemberRejected() public {
        _verifyEntity();
        _handleExpectFail(_pay(outsider, OUTSIDER, 1e6));
        _handle(_setMemberOp(clerk, MemberValidator.Role.OPERATOR, rep, REP));
        _handle(_pay(clerk, CLERK, 1e6));
        _handle(_setMemberOp(clerk, MemberValidator.Role.NONE, rep, REP));
        _handleExpectFail(_pay(clerk, CLERK, 1e6));
        (address[] memory list,) = mv.membersOf(entity);
        assertEq(list.length, 1);
        assertEq(list[0], rep);
    }

    function test_MemberWhoseKycLapsesRejected() public {
        _verifyEntity();
        _handle(_setMemberOp(clerk, MemberValidator.Role.OPERATOR, rep, REP));
        // 會計的實名證明被降為 L0
        bytes32 root = keccak256("claims");
        uint48 expiry = uint48(block.timestamp + 365 days);
        att.attest(clerk, 0, root, expiry, _ethSign(kycPk, att.attestationDigest(clerk, 0, root, expiry)));
        _handleExpectFail(_pay(clerk, CLERK, 1e6));
    }

    function test_LastAdminCannotBeRemoved() public {
        _handleExpectFail(_setMemberOp(rep, MemberValidator.Role.NONE, rep, REP));
        _handle(_setMemberOp(clerk, MemberValidator.Role.ADMIN, rep, REP));
        _handle(_setMemberOp(rep, MemberValidator.Role.OPERATOR, clerk, CLERK));
        assertEq(uint8(mv.roleOf(rep, entity)), uint8(MemberValidator.Role.OPERATOR));
    }

    // ───────────────────────── 簽章隔離 ─────────────────────────

    function test_PersonalSignatureNotAcceptedForEntity() public {
        _verifyEntity();
        PackedUserOperation memory op =
            _op(entity, address(mv), _exec(address(twdc), 0, abi.encodeCall(IERC20.transfer, (vendor, 1e6))));
        bytes32 h = ep.getUserOpHash(op);
        // 代表人直接簽 userOpHash（沒有包 entityHash）
        op.signature = abi.encode(MemberValidator.MemberSig(rep, _sig1271(REP, h)));
        _handleExpectFail(op);
        // 冒用別人的成員地址：簽章是外人的金鑰
        op.signature = abi.encode(MemberValidator.MemberSig(rep, _sig1271(OUTSIDER, mv.entityHash(entity, h))));
        _handleExpectFail(op);
    }

    function test_Entity1271_ForSignIn() public {
        bytes32 digest = keccak256("CAFECA Sign-In as entity");
        bytes memory ok = abi.encodePacked(address(mv), abi.encode(MemberValidator.MemberSig(rep, _sig1271(REP, mv.entityHash(entity, digest)))));
        assertEq(CafecaAccount(payable(entity)).isValidSignature(digest, ok), bytes4(0x1626ba7e));
        bytes memory personal = abi.encodePacked(address(mv), abi.encode(MemberValidator.MemberSig(rep, _sig1271(REP, digest))));
        assertEq(CafecaAccount(payable(entity)).isValidSignature(digest, personal), bytes4(0xffffffff));
        // 反過來：法人的簽章不能當成代表人個人的簽章
        assertEq(CafecaAccount(payable(rep)).isValidSignature(digest, _sig1271(REP, mv.entityHash(entity, digest))), bytes4(0xffffffff));
    }

    // ───────────────────────── 資金與額度 ─────────────────────────

    function test_UnverifiedEntityCannotMoveFunds() public {
        _handleExpectFail(_pay(rep, REP, 1e6));
        _verifyEntity();
        _handle(_pay(rep, REP, 1e6));
    }

    function test_LimitsEnforced_OnlyLimitAdminChanges() public {
        _verifyEntity();
        _handleExpectFail(_pay(rep, REP, 50_001e6)); // 超過單筆
        _handle(_pay(rep, REP, 50_000e6));
        _handle(_pay(rep, REP, 50_000e6));
        _handle(_pay(rep, REP, 50_000e6));
        _handle(_pay(rep, REP, 50_000e6));
        _handleExpectFail(_pay(rep, REP, 1e6)); // 超過每日
        vm.warp(block.timestamp + 1 days);
        _handle(_pay(rep, REP, 1e6));

        vm.expectRevert(MemberValidator.OnlyLimitAdmin.selector);
        mv.setLimitsFor(entity, address(twdc), 1, 1, 1);
        vm.prank(gov);
        mv.setLimitsFor(entity, address(twdc), 500_000e6, 1_000_000e6, 1);
        _handle(_pay(rep, REP, 400_000e6));
    }

    function test_BatchSpendIsSummed() public {
        _verifyEntity();
        Execution[] memory ex = new Execution[](2);
        ex[0] = Execution(address(twdc), 0, abi.encodeCall(IERC20.transfer, (vendor, 30_000e6)));
        ex[1] = Execution(address(twdc), 0, abi.encodeCall(IERC20.transfer, (vendor, 30_000e6)));
        PackedUserOperation memory op = _op(entity, address(mv), _execBatch(ex));
        _signEntity(op, rep, REP);
        _handleExpectFail(op); // 合計 60,000 > 單筆 50,000
    }

    function test_NativeTransferWithinDefaultLimits() public {
        (uint128 perTx, uint128 daily) = mv.limits(address(0), entity);
        assertEq(perTx, 1 ether);
        assertEq(daily, 5 ether);
        _handle(_setMemberOp(clerk, MemberValidator.Role.OPERATOR, rep, REP));
        // 未驗證的法人不能動用資金
        PackedUserOperation memory op = _op(entity, address(mv), _exec(vendor, 0.5 ether, ""));
        _signEntity(op, clerk, CLERK);
        _handleExpectFail(op);
        _verifyEntity();
        op = _op(entity, address(mv), _exec(vendor, 0.5 ether, ""));
        _signEntity(op, clerk, CLERK);
        _handle(op);
        assertEq(vendor.balance, 0.5 ether);
        // 附帶 BOLT 的一般合約呼叫：只有 ADMIN
        op = _op(entity, address(mv), _exec(address(factory), 0.1 ether, abi.encodeCall(factory.rootKeyId, (bytes32(0), bytes32(0)))));
        _signEntity(op, clerk, CLERK);
        _handleExpectFail(op);
    }

    function test_ForbiddenCalls() public {
        _verifyEntity();
        // 對法人帳戶本身（安裝模組）
        PackedUserOperation memory op = _op(
            entity,
            address(mv),
            _exec(entity, 0, abi.encodeCall(IERC7579ModuleConfig.installModule, (MODULE_TYPE_EXECUTOR, rep, "")))
        );
        _signEntity(op, rep, REP);
        _handleExpectFail(op);
        // 轉原生幣超過單筆額度
        op = _op(entity, address(mv), _exec(vendor, 2 ether, ""));
        _signEntity(op, rep, REP);
        _handleExpectFail(op);
        // OPERATOR 呼叫一般合約
        _handle(_setMemberOp(clerk, MemberValidator.Role.OPERATOR, rep, REP));
        op = _op(entity, address(mv), _exec(address(factory), 0, abi.encodeCall(factory.rootKeyId, (bytes32(0), bytes32(0)))));
        _signEntity(op, clerk, CLERK);
        _handleExpectFail(op);
        // ADMIN 可以
        op = _op(entity, address(mv), _exec(address(factory), 0, abi.encodeCall(factory.rootKeyId, (bytes32(0), bytes32(0)))));
        _signEntity(op, rep, REP);
        _handle(op);
    }
}
