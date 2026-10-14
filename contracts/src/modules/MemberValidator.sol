// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {
    IValidator,
    IERC7579Execution,
    Execution,
    MODULE_TYPE_VALIDATOR,
    VALIDATION_SUCCESS,
    VALIDATION_FAILED,
    ERC1271_MAGIC,
    ERC1271_INVALID
} from "../interfaces/IERC7579.sol";
import {ExecLib} from "../lib/ExecLib.sol";

interface IIdentityLevel {
    function levelOf(address account) external view returns (uint8);
}

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @title MemberValidator
/// @notice 法人帳戶（規格 §16.4、issue #1）的 validator：法人沒有自己的金鑰，由「成員」代為簽署。
///
///         - 成員是其他 CAFECA 身分帳戶，每位都必須是 IdentityRegistry v2 的有效 L2（自然人）。
///           成員用自己的 Passkey／實體卡簽，稽核時看得到是哪一位成員簽的；離職只要移除成員地址。
///         - ADMIN（代表人或內規指定的人）才能新增、移除、變更成員；OPERATOR 只能做代幣轉帳與授權。
///         - 成員簽的是 entityHash(entity, hash) = keccak256("CAFECA_ENTITY_V1", chainId, validator, entity, hash)，
///           成員個人簽過的訊息不會被當成法人簽章，反之亦然。
///         - 動用資金需要法人本身通過驗證（levelOf(entity) ≥ 2，由 KYC 後台依商工登記簽發 subjectType=1 的證明）；
///           被撤銷或暫停後只能管理成員，不能轉出。
///         - 額度與自然人相同：只有 limitAdmin（CAFECA 管理者）能調整，任何成員都不能改。
///
/// @dev 驗證時會呼叫成員帳戶的 isValidSignature（讀取成員的金鑰儲存），並讀取 IdentityRegistry；
///      這超出 ERC-7562 的 associated storage 規則，需要 CAFECA bundler 放寬（同 KeyringValidator 的時間戳記）。
contract MemberValidator is IValidator {
    enum Role {
        NONE,
        OPERATOR,
        ADMIN
    }

    struct Limit {
        uint128 perTx;
        uint128 daily;
    }

    struct Spent {
        uint128 amount;
        uint48 windowStart;
    }

    struct EntityState {
        bool initialized;
        uint32 adminCount;
        uint32 memberCount;
    }

    struct LimitInit {
        address token;
        uint128 perTx;
        uint128 daily;
    }

    /// @dev UserOp.signature 與 ERC-1271 data = abi.encode(MemberSig)
    struct MemberSig {
        address member;
        bytes signature; // 成員帳戶的 ERC-1271 簽章（validator(20) ‖ …）
    }

    uint8 public constant MEMBER_MIN_LEVEL = 2;
    uint8 public constant ENTITY_MIN_LEVEL = 2;
    uint48 public constant WINDOW = 24 hours;
    bytes32 public constant ENTITY_TYPEHASH = keccak256("CAFECA_ENTITY_V1");

    IIdentityLevel public immutable registry;

    address public limitAdmin;
    address public pendingLimitAdmin;

    mapping(address member => mapping(address entity => Role)) public roleOf;
    mapping(address token => mapping(address entity => Limit)) public limits;
    mapping(address token => mapping(address entity => Spent)) public spent;
    mapping(address entity => EntityState) public entityState;
    mapping(address entity => address[]) internal _members;
    mapping(address member => mapping(address entity => bool)) internal _listed;

    event MemberSet(address indexed entity, address indexed member, Role role);
    /// @notice 每一筆法人 UserOp 由哪位成員授權（稽核用）
    event MemberAuthorized(address indexed entity, address indexed member, bytes32 indexed userOpHash);
    event LimitsSet(address indexed entity, address indexed token, uint128 perTx, uint128 daily);
    event LimitsSetByAdmin(address indexed entity, address indexed token, uint128 perTx, uint128 daily, uint8 reason, address admin);
    event LimitAdminTransferStarted(address indexed next);
    event LimitAdminChanged(address indexed admin);

    error AlreadyInitialized();
    error NotInitialized();
    error MemberNotVerified();
    error LastAdmin();
    error OnlyLimitAdmin();
    error CannotUninstall();

    constructor(address registry_, address limitAdmin_) {
        registry = IIdentityLevel(registry_);
        limitAdmin = limitAdmin_;
        emit LimitAdminChanged(limitAdmin_);
    }

    // ───────────────────────── ERC-7579 模組 ─────────────────────────

    /// @param data abi.encode(address firstAdmin, LimitInit[] defaultLimits)
    function onInstall(bytes calldata data) external {
        EntityState storage st = entityState[msg.sender];
        if (st.initialized) revert AlreadyInitialized();
        st.initialized = true;
        (address admin, LimitInit[] memory lims) = abi.decode(data, (address, LimitInit[]));
        _setMember(msg.sender, admin, Role.ADMIN);
        for (uint256 i = 0; i < lims.length; i++) {
            _setLimits(msg.sender, lims[i].token, lims[i].perTx, lims[i].daily);
        }
    }

    function onUninstall(bytes calldata) external pure {
        revert CannotUninstall();
    }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == MODULE_TYPE_VALIDATOR;
    }

    // ───────────────────────── 成員管理（msg.sender = 法人帳戶，驗證階段已確認是 ADMIN 簽的） ─────────────────────────

    function setMember(address member, Role role) external {
        if (!entityState[msg.sender].initialized) revert NotInitialized();
        _setMember(msg.sender, member, role);
    }

    function membersOf(address entity) external view returns (address[] memory list, Role[] memory roles) {
        address[] storage all = _members[entity];
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) if (roleOf[all[i]][entity] != Role.NONE) n++;
        list = new address[](n);
        roles = new Role[](n);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            Role r = roleOf[all[i]][entity];
            if (r != Role.NONE) {
                list[j] = all[i];
                roles[j++] = r;
            }
        }
    }

    function _setMember(address entity, address member, Role role) internal {
        if (role != Role.NONE && registry.levelOf(member) < MEMBER_MIN_LEVEL) revert MemberNotVerified();
        EntityState storage st = entityState[entity];
        Role cur = roleOf[member][entity];
        if (cur == role) return;
        if (cur == Role.ADMIN) {
            if (st.adminCount == 1) revert LastAdmin();
            st.adminCount--;
        }
        if (role == Role.ADMIN) st.adminCount++;
        if (cur == Role.NONE) {
            st.memberCount++;
            if (!_listed[member][entity]) {
                _listed[member][entity] = true;
                _members[entity].push(member);
            }
        } else if (role == Role.NONE) {
            st.memberCount--;
        }
        roleOf[member][entity] = role;
        emit MemberSet(entity, member, role);
    }

    // ───────────────────────── 額度（只有管理者能調整） ─────────────────────────

    function setLimitsFor(address entity, address token, uint128 perTx, uint128 daily, uint8 reason) external {
        if (msg.sender != limitAdmin) revert OnlyLimitAdmin();
        if (!entityState[entity].initialized) revert NotInitialized();
        _setLimits(entity, token, perTx, daily);
        emit LimitsSetByAdmin(entity, token, perTx, daily, reason, msg.sender);
    }

    function transferLimitAdmin(address next) external {
        if (msg.sender != limitAdmin) revert OnlyLimitAdmin();
        pendingLimitAdmin = next;
        emit LimitAdminTransferStarted(next);
    }

    function acceptLimitAdmin() external {
        if (msg.sender != pendingLimitAdmin) revert OnlyLimitAdmin();
        limitAdmin = msg.sender;
        pendingLimitAdmin = address(0);
        emit LimitAdminChanged(msg.sender);
    }

    function _setLimits(address entity, address token, uint128 perTx, uint128 daily) internal {
        limits[token][entity] = Limit(perTx, daily);
        emit LimitsSet(entity, token, perTx, daily);
    }

    // ───────────────────────── 簽章 ─────────────────────────

    /// @notice 成員要簽的雜湊：把法人、鏈與本合約綁進去，成員個人的簽章不會被當成法人簽章
    function entityHash(address entity, bytes32 hash) public view returns (bytes32) {
        return keccak256(abi.encode(ENTITY_TYPEHASH, block.chainid, address(this), entity, hash));
    }

    function _memberOk(address entity, bytes32 hash, bytes memory data) internal view returns (bool ok, address member, Role role) {
        if (data.length < 64) return (false, address(0), Role.NONE);
        MemberSig memory ms = abi.decode(data, (MemberSig));
        member = ms.member;
        role = roleOf[member][entity];
        if (role == Role.NONE) return (false, member, role);
        if (registry.levelOf(member) < MEMBER_MIN_LEVEL) return (false, member, role);
        if (member.code.length == 0) return (false, member, role);
        try IERC1271(member).isValidSignature(entityHash(entity, hash), ms.signature) returns (bytes4 m) {
            ok = m == ERC1271_MAGIC;
        } catch {
            ok = false;
        }
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) external returns (uint256) {
        address entity = userOp.sender;
        if (!entityState[entity].initialized) return VALIDATION_FAILED;
        (bool ok, address member, Role role) = _memberOk(entity, userOpHash, userOp.signature);
        if (!ok) return VALIDATION_FAILED;

        (bool allowed, Role need, address[] memory tokens, uint256[] memory amounts, uint256 n) = _assess(entity, userOp.callData);
        if (!allowed || uint8(role) < uint8(need)) return VALIDATION_FAILED;
        if (n > 0 && registry.levelOf(entity) < ENTITY_MIN_LEVEL) return VALIDATION_FAILED;
        for (uint256 i = 0; i < n; i++) {
            if (!_consume(entity, tokens[i], amounts[i])) return VALIDATION_FAILED;
        }
        emit MemberAuthorized(entity, member, userOpHash);
        return VALIDATION_SUCCESS;
    }

    /// @dev 法人以 ERC-1271 簽署（例如 Sign in with CAFECA「以公司身分」登入）：任何有效成員皆可
    function isValidSignatureWithSender(address, bytes32 hash, bytes calldata data) external view returns (bytes4) {
        if (!entityState[msg.sender].initialized) return ERC1271_INVALID;
        (bool ok,,) = _memberOk(msg.sender, hash, data);
        return ok ? ERC1271_MAGIC : ERC1271_INVALID;
    }

    // ───────────────────────── 權限判斷 ─────────────────────────

    bytes4 private constant TRANSFER = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant APPROVE = 0x095ea7b3; // approve(address,uint256)
    bytes4 private constant TRANSFER_FROM = 0x23b872dd; // transferFrom(address,address,uint256)
    bytes4 private constant INCREASE_ALLOWANCE = 0x39509351; // increaseAllowance(address,uint256)

    /// @notice 預覽某個 callData 需要的角色與動用金額（錢包顯示用）
    function previewAssessment(address entity, bytes calldata callData)
        external
        view
        returns (bool allowed, Role need, address[] memory tokens, uint256[] memory amounts, uint256 n)
    {
        return _assess(entity, callData);
    }

    function _assess(address entity, bytes calldata callData)
        internal
        view
        returns (bool allowed, Role need, address[] memory tokens, uint256[] memory amounts, uint256 n)
    {
        if (callData.length < 4 || bytes4(callData[0:4]) != IERC7579Execution.execute.selector) return (false, Role.NONE, tokens, amounts, 0);
        (bytes32 mode, bytes memory ec) = abi.decode(callData[4:], (bytes32, bytes));
        Execution[] memory execs;
        try this.decodeExecutions(mode, ec) returns (Execution[] memory e) {
            execs = e;
        } catch {
            return (false, Role.NONE, tokens, amounts, 0);
        }
        // 每筆最多計入兩種：原生幣 value 與代幣金額
        tokens = new address[](execs.length * 2);
        amounts = new uint256[](execs.length * 2);
        need = Role.OPERATOR;
        allowed = true;
        for (uint256 i = 0; i < execs.length; i++) {
            Execution memory e = execs[i];
            bytes4 sel = e.callData.length >= 4 ? bytes4(e.callData) : bytes4(0);
            if (e.target == entity) return (false, need, tokens, amounts, 0);
            if (e.value > 0) {
                // 原生幣（BOLT）以 token = address(0) 計入額度；沒有設定原生幣額度就不能轉出
                if (e.target == address(this) || limits[address(0)][entity].daily == 0) return (false, need, tokens, amounts, 0);
                n = _addSpend(tokens, amounts, n, address(0), e.value);
                if (e.callData.length == 0) continue; // 單純轉 BOLT：經辦即可
            }
            if (e.target == address(this)) {
                // 只允許 setMember，且必須是 ADMIN
                if (sel != this.setMember.selector) return (false, need, tokens, amounts, 0);
                // 驗證階段先擋下執行時一定會失敗的變更（未實名的成員、移除最後一位 ADMIN），避免白付 gas
                (address m, Role r) = abi.decode(ExecLib.args(e.callData), (address, Role));
                if (r != Role.NONE && registry.levelOf(m) < MEMBER_MIN_LEVEL) return (false, need, tokens, amounts, 0);
                if (roleOf[m][entity] == Role.ADMIN && r != Role.ADMIN && entityState[entity].adminCount == 1 && execs.length == 1) {
                    return (false, need, tokens, amounts, 0);
                }
                need = Role.ADMIN;
                continue;
            }
            Limit memory lim = limits[e.target][entity];
            if (lim.daily > 0 && (sel == TRANSFER || sel == APPROVE || sel == INCREASE_ALLOWANCE || sel == TRANSFER_FROM)) {
                uint256 amt;
                bytes memory a = ExecLib.args(e.callData);
                if (sel == TRANSFER_FROM) (,, amt) = abi.decode(a, (address, address, uint256));
                else (, amt) = abi.decode(a, (address, uint256));
                n = _addSpend(tokens, amounts, n, e.target, amt);
            } else {
                // 其他合約呼叫（含受額度管理代幣的其他函式）只有 ADMIN 能做
                need = Role.ADMIN;
            }
        }
    }

    /// @dev 同一代幣合併計算
    function _addSpend(address[] memory tokens, uint256[] memory amounts, uint256 n, address token, uint256 amt) internal pure returns (uint256) {
        for (uint256 j = 0; j < n; j++) {
            if (tokens[j] == token) {
                amounts[j] += amt;
                return n;
            }
        }
        tokens[n] = token;
        amounts[n] = amt;
        return n + 1;
    }

    /// @dev 供 try/catch 解碼（外部呼叫才能攔截解碼錯誤）
    function decodeExecutions(bytes32 mode, bytes calldata ec) external pure returns (Execution[] memory) {
        return ExecLib.decode(mode, ec);
    }

    function _consume(address entity, address token, uint256 amount) internal returns (bool) {
        Limit memory lim = limits[token][entity];
        if (amount > lim.perTx) return false;
        Spent storage sp = spent[token][entity];
        uint256 used = block.timestamp >= uint256(sp.windowStart) + WINDOW ? 0 : sp.amount;
        if (used + amount > lim.daily) return false;
        if (block.timestamp >= uint256(sp.windowStart) + WINDOW) sp.windowStart = uint48(block.timestamp);
        sp.amount = uint128(used + amount);
        return true;
    }
}
