// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeyringValidator} from "../src/modules/KeyringValidator.sol";
import {IERC7579ModuleConfig, MODULE_TYPE_EXECUTOR} from "../src/interfaces/IERC7579.sol";
import {OpKind, TxSummary, TxSummaryLib} from "../src/lib/TxSummary.sol";

contract KeyringTest is Base {
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        account = _deployAccount();
    }

    function _transferOp(uint256 amount) internal view returns (PackedUserOperation memory) {
        return _op(account, address(keyring), _exec(address(twdc), 0, abi.encodeCall(IERC20.transfer, (bob, amount))));
    }

    // ── §4.4 開戶：initCode 部署＋第一把 passkey 同一筆完成 ──

    function test_CreateAccountViaInitCode() public {
        // 身分以 FIDO2 金鑰為根：地址由公鑰決定，瀏覽器可自行算出並以 initCode 部署
        (bytes32 qx, bytes32 qy) = _pub(NEW_PHONE);
        address predicted = factory.getAddress(qx, qy);
        vm.deal(predicted, 1 ether);

        PackedUserOperation memory op =
            _op(predicted, address(keyring), _exec(address(dd), 0, abi.encodeCall(dd.registerDevice, (bytes32("iphone"), hex"01"))));
        op.initCode = abi.encodePacked(address(factory), abi.encodeCall(factory.createAccount, (qx, qy, RP)));
        _signDaily(op, NEW_PHONE);
        _handle(op);

        assertGt(predicted.code.length, 0);
        assertEq(uint8(keyring.getKey(predicted, _keyId(NEW_PHONE)).keyClass), uint8(KeyringValidator.KeyClass.DAILY));
    }

    function test_InitCodeSignedByOtherKeyRejected() public {
        // 用別人的公鑰部署，但沒有那把私鑰：第一筆 UserOp 驗簽失敗，整筆不上鏈
        (bytes32 qx, bytes32 qy) = _pub(NEW_PHONE);
        address predicted = factory.getAddress(qx, qy);
        vm.deal(predicted, 1 ether);
        PackedUserOperation memory op = _op(predicted, address(keyring), _exec(address(dd), 0, abi.encodeCall(dd.revokeDevice, (bytes32(0)))));
        op.initCode = abi.encodePacked(address(factory), abi.encodeCall(factory.createAccount, (qx, qy, RP)));
        _signWith(op, ATTACKER, _dailyAuthData());
        _handleExpectFail(op);
    }

    function test_FrontRunDeployStillOwnedByRootKey() public {
        // 攻擊者搶先代為部署：帳戶仍只由這把金鑰控制，攻擊者得不到任何權限
        (bytes32 qx, bytes32 qy) = _pub(NEW_PHONE);
        address a = factory.createAccount(qx, qy, RP);
        assertEq(a, factory.getAddress(qx, qy));
        assertEq(uint8(keyring.getKey(a, _keyId(NEW_PHONE)).keyClass), uint8(KeyringValidator.KeyClass.DAILY));
        assertEq(uint8(keyring.getKey(a, _keyId(ATTACKER)).keyClass), uint8(KeyringValidator.KeyClass.NONE));
        assertEq(factory.createAccount(qx, qy, RP), a); // 重複呼叫冪等
    }

    // ── §4.3 標準模式（尚未綁卡）──

    function test_Standard_DailySmallTransfer() public {
        PackedUserOperation memory op = _transferOp(1_000e6);
        _signDaily(op, PHONE);
        _handle(op);
        assertEq(twdc.balanceOf(bob), 1_000e6);
    }

    // ── 原生幣（BOLT）：開戶即有預設額度 ──

    function test_Native_DefaultLimitsAllowDailyTransfer() public {
        (uint128 perTx, uint128 daily) = keyring.limits(address(0), account);
        assertEq(perTx, NATIVE_PER_TX);
        assertEq(daily, NATIVE_DAILY);
        PackedUserOperation memory op = _op(account, address(keyring), _exec(bob, 0.5 ether, ""));
        _signDaily(op, PHONE);
        _handle(op);
        assertEq(bob.balance, 0.5 ether);
    }

    function test_Native_ValueWithContractCallWithinLimit() public {
        // 網站合約呼叫附帶 BOLT（例如付費建立存證）：在額度內用手機即可
        NativeSink sink = new NativeSink();
        PackedUserOperation memory op = _op(account, address(keyring), _exec(address(sink), 0.75 ether, abi.encodeCall(NativeSink.pay, (42))));
        _signDaily(op, PHONE);
        _handle(op);
        assertEq(address(sink).balance, 0.75 ether);
    }

    function test_Native_OverLimitRejectedWithoutCard() public {
        PackedUserOperation memory op = _op(account, address(keyring), _exec(bob, NATIVE_PER_TX + 1, ""));
        _signDaily(op, PHONE);
        _handleExpectFail(op);
        // 每日累計
        for (uint256 i = 0; i < 5; i++) {
            op = _op(account, address(keyring), _exec(bob, 1 ether, ""));
            _signDaily(op, PHONE);
            _handle(op);
        }
        op = _op(account, address(keyring), _exec(bob, 0.1 ether, ""));
        _signDaily(op, PHONE);
        _handleExpectFail(op);
    }

    function test_Standard_OverPerTxRejected() public {
        PackedUserOperation memory op = _transferOp(PER_TX + 1);
        _signDaily(op, PHONE);
        _handleExpectFail(op);
    }

    function test_Standard_DailyWindow() public {
        for (uint256 i = 0; i < 3; i++) {
            PackedUserOperation memory op = _transferOp(PER_TX);
            _signDaily(op, PHONE);
            _handle(op);
        }
        PackedUserOperation memory op4 = _transferOp(1e6);
        _signDaily(op4, PHONE);
        _handleExpectFail(op4); // 當日累計超過 30,000

        vm.warp(block.timestamp + 1 days);
        PackedUserOperation memory op5 = _transferOp(1e6);
        _signDaily(op5, PHONE);
        _handle(op5);
    }

    // ── 多裝置共管：所有裝置金鑰同級 ──

    function test_Device_AddsAnotherDeviceImmediately() public {
        (bytes32 qx, bytes32 qy) = _pub(NEW_PHONE);
        PackedUserOperation memory op =
            _op(account, address(keyring), _exec(address(keyring), 0, abi.encodeCall(keyring.addDailyKey, (qx, qy, RP))));
        _signDaily(op, PHONE);
        _handle(op);
        assertEq(uint8(keyring.getKey(account, _keyId(NEW_PHONE)).keyClass), uint8(KeyringValidator.KeyClass.DAILY));

        // 新裝置與原裝置等級相同：新裝置也能移除原裝置
        op = _op(account, address(keyring), _exec(address(keyring), 0, abi.encodeCall(keyring.removeKey, (_keyId(PHONE)))));
        _signDaily(op, NEW_PHONE);
        _handle(op);
        assertEq(uint8(keyring.getKey(account, _keyId(PHONE)).keyClass), uint8(KeyringValidator.KeyClass.NONE));
        assertEq(keyring.keysOf(account).length, 1);

        PackedUserOperation memory t = _transferOp(1e6);
        _signDaily(t, NEW_PHONE);
        _handle(t);
    }

    function test_Device_CannotRemoveLastKey() public {
        PackedUserOperation memory op =
            _op(account, address(keyring), _exec(address(keyring), 0, abi.encodeCall(keyring.removeKey, (_keyId(PHONE)))));
        _signDaily(op, PHONE);
        _handle(op); // 執行期 LastKey
        assertEq(uint8(keyring.getKey(account, _keyId(PHONE)).keyClass), uint8(KeyringValidator.KeyClass.DAILY));
    }

    // ── §4.5 綁卡 → 主金鑰模式 ──

    function test_BindCard_EntersMasterMode() public {
        _bindCard(account);
        assertTrue(keyring.isMasterMode(account));
        assertEq(uint8(keyring.getKey(account, _keyId(CARD)).keyClass), uint8(KeyringValidator.KeyClass.MASTER));
    }

    function test_BindCard_RejectsFakeIssuer() public {
        _kyc(account);
        _bindCardKey(account, CARD, keccak256("fake"), bytes32(0), 0xFA4E); // 執行期 InvalidCardAttestation
        assertFalse(keyring.isMasterMode(account));
    }

    function test_BindCard_RequiresKyc() public {
        _bindCardKey(account, CARD, keccak256("card"), bytes32(0), issuerPk); // 執行期 KycRequired
        assertFalse(keyring.isMasterMode(account));
        _kyc(account);
        _bindCardKey(account, CARD, keccak256("card"), bytes32(0), issuerPk);
        assertTrue(keyring.isMasterMode(account));
    }

    // ── 實體卡不可被其他金鑰移除 ──

    function test_Card_PhoneCannotRemoveCard_NorSchedule() public {
        _bindCard(account);
        bytes memory cd = _exec(address(keyring), 0, abi.encodeCall(keyring.removeKey, (_keyId(CARD))));
        PackedUserOperation memory op = _op(account, address(keyring), cd);
        _signDaily(op, PHONE);
        _handleExpectFail(op);

        uint8 action = uint8(KeyringValidator.Action.REMOVE_KEY);
        op = _op(
            account,
            address(keyring),
            _exec(address(keyring), 0, abi.encodeCall(keyring.schedule, (action, abi.encode(_keyId(CARD)))))
        );
        _signDaily(op, PHONE);
        _handleExpectFail(op);
        assertTrue(keyring.isMasterMode(account));
    }

    function test_Card_OtherCardCannotRemoveIt_ButItselfCan() public {
        _bindCard(account);
        uint256 card2 = 0xCA4D2;
        _bindCardKey(account, card2, keccak256("card-0002"), bytes32(0), issuerPk);
        assertEq(keyring.masterCount(account), 2);

        bytes memory cd = _exec(address(keyring), 0, abi.encodeCall(keyring.removeKey, (_keyId(CARD))));
        PackedUserOperation memory op = _op(account, address(keyring), cd);
        (,,, bytes32 ctxd) = keyring.previewAssessment(account, cd);
        _signWith(op, card2, _cardAuthData(ctxd));
        _handleExpectFail(op);

        op = _op(account, address(keyring), cd);
        _signCard(op); // 卡片自己
        _handle(op);
        assertEq(keyring.masterCount(account), 1);
    }

    function test_Card_LostCardReplacedByIssuer() public {
        _bindCard(account);
        uint256 card2 = 0xCA4D2;
        _bindCardKey(account, card2, keccak256("card-0002"), _keyId(CARD), issuerPk);
        assertEq(keyring.masterCount(account), 1);
        assertEq(uint8(keyring.getKey(account, _keyId(CARD)).keyClass), uint8(KeyringValidator.KeyClass.NONE));
        assertEq(uint8(keyring.getKey(account, _keyId(card2)).keyClass), uint8(KeyringValidator.KeyClass.MASTER));
    }

    // ── §4.3＋§9.2 主金鑰模式：大額需卡片＋螢幕確認 ──

    function test_Master_LargeTransferNeedsCard() public {
        _bindCard(account);

        PackedUserOperation memory op = _transferOp(50_000e6);
        _signDaily(op, PHONE);
        _handleExpectFail(op); // 手機不能做大額

        op = _transferOp(50_000e6);
        _signWith(op, CARD, _dailyAuthData()); // 卡片但沒有 ctxd（盲簽）
        _handleExpectFail(op);

        op = _transferOp(50_000e6);
        _signCard(op);
        _handle(op);
        assertEq(twdc.balanceOf(bob), 50_000e6);
    }

    function test_Master_TamperedDisplayRejected() public {
        _bindCard(account);
        PackedUserOperation memory op = _transferOp(50_000e6);
        // 被動過的 App 讓卡片顯示「轉 500 給 bob」，實際 calldata 是 50,000
        TxSummary memory shown =
            TxSummary(uint8(OpKind.TRANSFER), block.chainid, address(twdc), 500e6, bob, bytes32(0));
        _signWith(op, CARD, _cardAuthData(TxSummaryLib.single(shown)));
        _handleExpectFail(op);
    }

    function test_Master_CtxdMatchesIndependentSummary() public {
        _bindCard(account);
        PackedUserOperation memory op = _transferOp(50_000e6);
        TxSummary memory expected =
            TxSummary(uint8(OpKind.TRANSFER), block.chainid, address(twdc), 50_000e6, bob, bytes32(0));
        _signWith(op, CARD, _cardAuthData(TxSummaryLib.single(expected)));
        _handle(op);
        assertEq(twdc.balanceOf(bob), 50_000e6);
    }

    function test_Master_SyncedKeyCannotActAsMaster() public {
        _bindCard(account);
        PackedUserOperation memory op = _transferOp(50_000e6);
        (,,, bytes32 ctxd) = keyring.previewAssessment(account, op.callData);
        // BE 旗標 = 1（可同步）的簽章不被當作卡片
        bytes memory ad = abi.encodePacked(RP, bytes1(0x8D), uint32(1), bytes8(0xA164637478645820), ctxd);
        _signWith(op, CARD, ad);
        _handleExpectFail(op);
    }

    function test_Master_DailyCanStillDoSmallTransfer() public {
        _bindCard(account);
        PackedUserOperation memory op = _transferOp(100e6);
        _signDaily(op, PHONE);
        _handle(op);
        assertEq(twdc.balanceOf(bob), 100e6);
    }

    function test_Master_CardAddsKeyImmediately() public {
        _bindCard(account);
        (bytes32 qx, bytes32 qy) = _pub(NEW_PHONE);
        bytes memory cd = _exec(address(keyring), 0, abi.encodeCall(keyring.addDailyKey, (qx, qy, RP)));
        PackedUserOperation memory op = _op(account, address(keyring), cd);
        _signCard(op);
        _handle(op);
        assertEq(uint8(keyring.getKey(account, _keyId(NEW_PHONE)).keyClass), uint8(KeyringValidator.KeyClass.DAILY));
    }

    function test_Master_CardRemovesStolenPhone() public {
        _bindCard(account);
        bytes memory cd = _exec(address(keyring), 0, abi.encodeCall(keyring.removeKey, (_keyId(PHONE))));
        PackedUserOperation memory op = _op(account, address(keyring), cd);
        _signCard(op);
        _handle(op);
        assertEq(uint8(keyring.getKey(account, _keyId(PHONE)).keyClass), uint8(KeyringValidator.KeyClass.NONE));
    }

    function test_Limits_UserCannotChange_EvenWithCard() public {
        _bindCard(account);
        bytes memory lower =
            _exec(address(keyring), 0, abi.encodeCall(keyring.setLimits, (address(twdc), uint128(1_000e6), uint128(5_000e6))));
        bytes memory raise =
            _exec(address(keyring), 0, abi.encodeCall(keyring.setLimits, (address(twdc), uint128(50_000e6), uint128(100_000e6))));
        PackedUserOperation memory op = _op(account, address(keyring), lower);
        _signDaily(op, PHONE);
        _handleExpectFail(op);
        op = _op(account, address(keyring), raise);
        _signCard(op);
        _handleExpectFail(op);
        // 排程修改也不行
        bytes memory sched = _exec(
            address(keyring), 0, abi.encodeCall(keyring.schedule, (uint8(2), abi.encode(address(twdc), uint128(50_000e6), uint128(100_000e6))))
        );
        op = _op(account, address(keyring), sched);
        _signCard(op);
        _handleExpectFail(op);
        // 直接呼叫也不行
        vm.prank(account);
        vm.expectRevert(KeyringValidator.LimitsManagedByAdmin.selector);
        keyring.setLimits(address(twdc), 1, 1);
        (uint128 perTx, uint128 daily) = keyring.limits(address(twdc), account);
        assertEq(perTx, 10_000e6);
        assertEq(daily, 30_000e6);
    }

    function test_Limits_AdminRaisesAndLowers() public {
        vm.expectRevert(KeyringValidator.OnlyLimitAdmin.selector);
        keyring.setLimitsFor(account, address(twdc), 50_000e6, 100_000e6, 1);

        vm.prank(gov);
        vm.expectEmit(true, true, false, true);
        emit KeyringValidator.LimitsSetByAdmin(account, address(twdc), 50_000e6, 100_000e6, 1, gov);
        keyring.setLimitsFor(account, address(twdc), 50_000e6, 100_000e6, 1);
        (uint128 perTx, uint128 daily) = keyring.limits(address(twdc), account);
        assertEq(perTx, 50_000e6);
        assertEq(daily, 100_000e6);

        vm.prank(gov);
        keyring.setLimitsFor(account, address(twdc), 500e6, 1_000e6, 2);
        (perTx, daily) = keyring.limits(address(twdc), account);
        assertEq(perTx, 500e6);

        // 未初始化的帳戶不能設定
        vm.prank(gov);
        vm.expectRevert(KeyringValidator.NotInitialized.selector);
        keyring.setLimitsFor(makeAddr("nobody"), address(twdc), 1, 1, 1);
    }

    function test_Limits_AdminTransferIsTwoStep() public {
        address next = makeAddr("nextAdmin");
        vm.prank(gov);
        keyring.transferLimitAdmin(next);
        assertEq(keyring.limitAdmin(), gov);
        vm.prank(makeAddr("x"));
        vm.expectRevert(KeyringValidator.OnlyLimitAdmin.selector);
        keyring.acceptLimitAdmin();
        vm.prank(next);
        keyring.acceptLimitAdmin();
        assertEq(keyring.limitAdmin(), next);
        vm.prank(gov);
        vm.expectRevert(KeyringValidator.OnlyLimitAdmin.selector);
        keyring.setLimitsFor(account, address(twdc), 1, 1, 1);
    }

    function test_Master_UnlimitedApproveNeedsCard() public {
        _bindCard(account);
        bytes memory cd = _exec(address(twdc), 0, abi.encodeCall(IERC20.approve, (bob, type(uint256).max)));
        PackedUserOperation memory op = _op(account, address(keyring), cd);
        _signDaily(op, PHONE);
        _handleExpectFail(op);
    }

    function test_ModuleInstallNeedsScheduleAndCard() public {
        _bindCard(account);
        address evil = makeAddr("evilExecutor");
        bytes memory installCd = abi.encodeCall(IERC7579ModuleConfig.installModule, (MODULE_TYPE_EXECUTOR, evil, ""));

        // 未排程：即使卡片簽也被拒
        PackedUserOperation memory op = _op(account, address(keyring), installCd);
        _signWith(op, CARD, _cardAuthData(bytes32(0)));
        _handleExpectFail(op);

        // 卡片排程（螢幕確認）→ 72h 前仍被拒 → 72h 後卡片簽署安裝
        uint8 action = uint8(KeyringValidator.Action.MODULE);
        op = _op(account, address(keyring), _exec(address(keyring), 0, abi.encodeCall(keyring.schedule, (action, installCd))));
        _signDaily(op, PHONE);
        _handleExpectFail(op); // 主金鑰模式下排程模組變更需卡片
        op = _op(account, address(keyring), _exec(address(keyring), 0, abi.encodeCall(keyring.schedule, (action, installCd))));
        _signCard(op);
        _handle(op);

        vm.warp(block.timestamp + 71 hours);
        op = _op(account, address(keyring), installCd);
        _signWith(op, CARD, _cardAuthData(bytes32(0)));
        _handleExpectFail(op);

        vm.warp(block.timestamp + 1 hours);
        vm.etch(evil, hex"00"); // 讓 onInstall 呼叫成功（STOP）
        op = _op(account, address(keyring), installCd);
        _signCard(op);
        _handle(op);
        assertTrue(IERC7579ModuleConfig(account).isModuleInstalled(MODULE_TYPE_EXECUTOR, evil, ""));
    }

    function test_RandomKeyRejected() public {
        PackedUserOperation memory op = _transferOp(1e6);
        _signDaily(op, ATTACKER);
        _handleExpectFail(op);
    }
}

contract NativeSink {
    uint256 public last;

    function pay(uint256 x) external payable {
        last = x;
    }
}
