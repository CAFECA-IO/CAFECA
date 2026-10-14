// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {CafecaAccount} from "../src/account/CafecaAccount.sol";
import {IdentityAccountFactory} from "../src/factory/IdentityAccountFactory.sol";
import {KeyringValidator} from "../src/modules/KeyringValidator.sol";
import {RecoveryValidator} from "../src/modules/RecoveryValidator.sol";
import {ChannelValidator} from "../src/modules/ChannelValidator.sol";
import {ChannelManager} from "../src/channels/ChannelManager.sol";
import {AttestationRegistry} from "../src/registry/AttestationRegistry.sol";
import {DeviceDirectory} from "../src/registry/DeviceDirectory.sol";
import {IERC7579Execution, Execution} from "../src/interfaces/IERC7579.sol";
import {ExecLib} from "../src/lib/ExecLib.sol";
import {WebAuthnLib} from "../src/lib/WebAuthnLib.sol";

contract MockStable is ERC20 {
    constructor() ERC20("CAFECA TWD Coin", "TWDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

abstract contract Base is Test {
    EntryPoint internal ep;
    CafecaAccount internal impl;
    KeyringValidator internal keyring;
    RecoveryValidator internal recovery;
    ChannelValidator internal cv;
    ChannelManager internal cm;
    AttestationRegistry internal att;
    DeviceDirectory internal dd;
    IdentityAccountFactory internal factory;
    MockStable internal twdc;

    address internal gov = makeAddr("governance");
    address payable internal beneficiary = payable(makeAddr("bundler"));
    uint256 internal issuerPk = 0x1551E7;
    uint256 internal kycPk = 0x4C7C;
    uint256 internal rootPk = 0x6007; // 平台根金鑰（離線）：授權備援金鑰
    uint256 internal guardianPk = 0x6A4D; // 此帳戶的平台備援金鑰（HSM）

    uint256 internal constant PHONE = 0xA11CE; // 手機 passkey（DAILY）
    uint256 internal constant CARD = 0xCA4D; // CAFECA 卡（MASTER）
    uint256 internal constant NEW_PHONE = 0xB0B; // 新手機
    uint256 internal constant ATTACKER = 0xBAD;

    bytes32 internal constant RP = sha256("cafeca.com.tw");

    uint256 internal constant PER_TX = 10_000e6;
    uint256 internal constant DAILY = 30_000e6;
    uint256 internal constant NATIVE_PER_TX = 1 ether;
    uint256 internal constant NATIVE_DAILY = 5 ether;

    address internal account;

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        ep = new EntryPoint();
        impl = new CafecaAccount(address(ep));
        att = new AttestationRegistry(gov);
        dd = new DeviceDirectory();

        uint64 n = vm.getNonce(address(this));
        address keyringAddr = vm.computeCreateAddress(address(this), n);
        address recoveryAddr = vm.computeCreateAddress(address(this), n + 1);
        address cvAddr = vm.computeCreateAddress(address(this), n + 2);
        address cmAddr = vm.computeCreateAddress(address(this), n + 3);
        keyring = new KeyringValidator(recoveryAddr, cmAddr, cvAddr, address(dd), address(att), gov);
        recovery = new RecoveryValidator(address(keyring), address(att));
        cv = new ChannelValidator();
        cm = new ChannelManager(address(impl), address(cv));
        assertEq(address(keyring), keyringAddr);
        assertEq(address(recovery), recoveryAddr);
        assertEq(address(cm), cmAddr);

        twdc = new MockStable();
        factory = new IdentityAccountFactory(
            address(impl),
            address(keyring),
            address(recovery),
            address(twdc),
            uint128(PER_TX),
            uint128(DAILY),
            uint128(NATIVE_PER_TX),
            uint128(NATIVE_DAILY)
        );

        vm.startPrank(gov);
        att.setCardIssuer(vm.addr(issuerPk), true);
        att.setKycSigner(vm.addr(kycPk), true);
        att.setGuardianAuthority(vm.addr(rootPk), true);
        vm.stopPrank();
    }

    // ───────────────────────── 帳戶 ─────────────────────────

    function _deployAccount() internal returns (address acct) {
        (bytes32 qx, bytes32 qy) = _pub(PHONE);
        acct = factory.getAddress(qx, qy);
        factory.createAccount(qx, qy, RP);
        vm.deal(acct, 10 ether);
        twdc.mint(acct, 1_000_000e6);
    }

    /// @dev L2 KYC（證件＋臉部影像）通過：KYC 單位寫入等級證明
    function _kyc(address acct) internal {
        bytes32 root = keccak256("claims");
        uint48 expiry = uint48(block.timestamp + 365 days);
        att.attest(acct, 2, root, expiry, _ethSign(kycPk, att.attestationDigest(acct, 2, root, expiry)));
    }

    /// @dev 購買並綁定實體卡（需先 KYC；發卡方確認付款後簽署）
    function _bindCard(address acct) internal {
        if (att.levelOf(acct) < 2) _kyc(acct);
        _bindCardKey(acct, CARD, keccak256("card-0001"), bytes32(0), issuerPk);
    }

    function _bindCardKey(address acct, uint256 cardPk, bytes32 serial, bytes32 replaces, uint256 signerPk) internal {
        (bytes32 qx, bytes32 qy) = _pub(cardPk);
        bytes memory sig = _ethSign(signerPk, keyring.cardAttestationDigest(acct, qx, qy, RP, serial, replaces));
        bytes memory data = abi.encodeCall(KeyringValidator.addMasterKey, (qx, qy, RP, serial, replaces, sig));
        PackedUserOperation memory op = _op(acct, address(keyring), _exec(address(keyring), 0, data));
        _signDaily(op, PHONE);
        _handle(op);
    }

    /// @dev KYC 通過後安裝平台備援金鑰（平台根金鑰授權）
    function _setGuardian(address acct) internal {
        address g = vm.addr(guardianPk);
        (, , , uint64 n) = recovery.state(acct);
        bytes memory sig = _ethSign(rootPk, recovery.guardianDigest(acct, g, n));
        PackedUserOperation memory op =
            _op(acct, address(keyring), _exec(address(recovery), 0, abi.encodeCall(recovery.setGuardian, (g, sig))));
        _signDaily(op, PHONE);
        _handle(op);
    }

    // ───────────────────────── UserOp ─────────────────────────

    function _exec(address target, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC7579Execution.execute, (ExecLib.modeSingle(), ExecLib.encodeSingle(target, value, data)));
    }

    function _execBatch(Execution[] memory execs) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC7579Execution.execute, (ExecLib.modeBatch(), ExecLib.encodeBatch(execs)));
    }

    function _op(address sender, address validator, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        uint192 key = uint192(uint160(validator)) << 32;
        op.sender = sender;
        op.nonce = ep.getNonce(sender, key);
        op.callData = callData;
        op.accountGasLimits = bytes32((uint256(5_000_000) << 128) | uint256(3_000_000));
        op.preVerificationGas = 100_000;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
    }

    function _handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        ep.handleOps(ops, beneficiary);
    }

    function _handleExpectFail(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectPartialRevert(IEntryPoint.FailedOp.selector);
        ep.handleOps(ops, beneficiary);
    }

    // ───────────────────────── WebAuthn ─────────────────────────

    function _pub(uint256 pk) internal pure returns (bytes32 qx, bytes32 qy) {
        (uint256 x, uint256 y) = vm.publicKeyP256(pk);
        return (bytes32(x), bytes32(y));
    }

    function _keyId(uint256 pk) internal pure returns (bytes32) {
        (bytes32 qx, bytes32 qy) = _pub(pk);
        return keccak256(abi.encode(qx, qy));
    }

    /// @dev 手機 passkey：UP|UV，無擴充
    function _dailyAuthData() internal pure returns (bytes memory) {
        return abi.encodePacked(RP, bytes1(0x05), uint32(1));
    }

    /// @dev 卡片：UP|UV|ED，附 ctxd 擴充
    function _cardAuthData(bytes32 ctxd) internal pure returns (bytes memory) {
        return abi.encodePacked(RP, bytes1(0x85), uint32(1), bytes8(0xA164637478645820), ctxd);
    }

    function _webauthn(bytes32 challenge, uint256 pk, bytes memory authData)
        internal
        pure
        returns (WebAuthnLib.Sig memory sig)
    {
        string memory cd = string.concat(
            '{"type":"webauthn.get","challenge":"',
            Base64.encodeURL(abi.encodePacked(challenge)),
            '","origin":"https://cafeca.com.tw","crossOrigin":false}'
        );
        bytes32 h = sha256(abi.encodePacked(authData, sha256(bytes(cd))));
        (bytes32 r, bytes32 s) = vm.signP256(pk, h);
        if (uint256(s) > WebAuthnLib.P256_N_DIV_2) {
            s = bytes32(0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551 - uint256(s));
        }
        sig = WebAuthnLib.Sig(authData, cd, 23, 1, r, s);
    }

    function _signWith(PackedUserOperation memory op, uint256 pk, bytes memory authData) internal view {
        bytes32 h = ep.getUserOpHash(op);
        op.signature = abi.encode(KeyringValidator.SignatureData(_keyId(pk), _webauthn(h, pk, authData)));
    }

    function _signDaily(PackedUserOperation memory op, uint256 pk) internal view {
        _signWith(op, pk, _dailyAuthData());
    }

    /// @dev 卡片簽章：ctxd 由 keyring.previewAssessment 產生（等同 App 傳給卡片顯示的內容）
    function _signCard(PackedUserOperation memory op) internal view {
        (,,, bytes32 ctxd) = keyring.previewAssessment(op.sender, op.callData);
        _signWith(op, CARD, _cardAuthData(ctxd));
    }

    function _ethSign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOperator(PackedUserOperation memory op, uint256 pk) internal view {
        bytes32 h = MessageHashUtils.toEthSignedMessageHash(ep.getUserOpHash(op));
        op.signature = _ethSign(pk, h);
    }
}
