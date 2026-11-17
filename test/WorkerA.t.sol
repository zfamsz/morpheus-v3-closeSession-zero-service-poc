// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IMOR {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

struct Session {
    address user;
    bytes32 bidId;
    uint256 stake;
    bytes closeoutReceipt;
    uint256 closeoutType;
    uint256 providerWithdrawnAmount;
    uint128 openedAt;
    uint128 endsAt;
    uint128 closedAt;
    bool isActive;
    bool isDirectPaymentFromUser;
}

interface IDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function providerDeregister(address provider_) external;
    function modelRegister(address modelOwner_, bytes32 baseModelId_, bytes32 ipfsCID_, uint256 fee_, uint256 amount_, string calldata name_, string[] calldata tags_) external;
    function modelDeregister(bytes32 modelId_) external;
    function getModelId(address owner_, bytes32 baseModelId_) external pure returns (bytes32);
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function deleteModelBid(bytes32 bidId_) external;
    function getBid(bytes32 bidId_) external view returns (address provider, bytes32 modelId, uint256 pricePerSecond, uint256 nonce, uint128 createdAt, uint128 deletedAt);
    function getModel(bytes32 modelId_) external view returns (bytes32 ipfsCID, uint256 fee, uint256 stake, address owner, string memory name, string[] memory tags, uint128 createdAt, bool isDeleted);
    function getModelActiveBids(bytes32 modelId_, uint256 offset_, uint256 limit_) external view returns (bytes32[] memory, uint256);
    function getActiveModelIds(uint256 offset_, uint256 limit_) external view returns (bytes32[] memory, uint256);
    function getActiveProviders(uint256 offset_, uint256 limit_) external view returns (address[] memory, uint256);
    function getModelMinimumStake() external view returns (uint256);
    function getProviderMinimumStake() external view returns (uint256);
    function getBidFee() external view returns (uint256);
    function getMinMaxBidPricePerSecond() external view returns (uint256, uint256);
    function getToken() external view returns (address);
    function openSession(address user_, uint256 amount_, bool isDirectPaymentFromUser_, bytes calldata approvalEncoded_, bytes calldata signature_) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function getIsProviderApprovalUsed(bytes calldata approval_) external view returns (bool);
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256, uint256);
    function getFundingAccount() external view returns (address);
    function getProvidersTotalClaimed() external view returns (uint256);
}

/// Worker A Round 3 — Lumerin Diamond / SessionRouter / ModelRegistry lane (Base fork).
/// Read-only vs mainnet state; all actors fresh EOAs funded with deal(); nothing broadcast.
contract WorkerA is Test {
    address internal constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address internal constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 internal constant FORK_BLOCK = 58_661_283;
    uint256 internal constant PRICE_MAX = 1e16; // 0.01 MOR/s

    uint256 internal providerKey = 0xA11CE;
    uint256 internal userKey = 0xB0B;
    address internal provider;
    address internal user;
    address internal funding;

    function _sign(uint256 key_, bytes memory payload_) internal pure returns (bytes memory) {
        bytes32 digest_ = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(payload_)));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, digest_);
        return abi.encodePacked(r_, s_, v_);
    }

    function _approval(bytes32 bidId_, address user_) internal view returns (bytes memory) {
        return abi.encode(bidId_, uint256(8453), user_, uint128(block.timestamp));
    }

    function _setupActor(address who_, uint256 mor_) internal {
        deal(MOR, who_, mor_);
        vm.prank(who_);
        IMOR(MOR).approve(DIAMOND, type(uint256).max);
    }

    /// Register provider + its own model + max-price bid. Returns (modelId, bidId).
    function _registerProvider(address prov_, uint256 provStake_, uint256 modelStake_, bytes32 baseModel_)
        internal returns (bytes32 modelId_, bytes32 bidId_)
    {
        _setupActor(prov_, provStake_ + modelStake_ + 1 ether);
        vm.startPrank(prov_);
        IDiamond(DIAMOND).providerRegister(prov_, provStake_, "https://provider.example");
        string[] memory tags_;
        IDiamond(DIAMOND).modelRegister(prov_, baseModel_, bytes32("cid"), 0, modelStake_, "model", tags_);
        modelId_ = IDiamond(DIAMOND).getModelId(prov_, baseModel_);
        bidId_ = IDiamond(DIAMOND).postModelBid(prov_, modelId_, PRICE_MAX);
        vm.stopPrank();
    }

    function _open(address opener_, address user_, uint256 amount_, bytes32 bidId_) internal returns (bytes32) {
        bytes memory approval_ = _approval(bidId_, user_);
        bytes memory sig_ = _sign(providerKey, approval_);
        vm.prank(opener_);
        return IDiamond(DIAMOND).openSession(user_, amount_, false, approval_, sig_);
    }

    function _openWithKey(address opener_, address user_, uint256 amount_, bytes32 bidId_, uint256 signerKey_) internal returns (bytes32) {
        bytes memory approval_ = _approval(bidId_, user_);
        bytes memory sig_ = _sign(signerKey_, approval_);
        vm.prank(opener_);
        return IDiamond(DIAMOND).openSession(user_, amount_, false, approval_, sig_);
    }

    function setUp() public {
        vm.createSelectFork("base", FORK_BLOCK);
        provider = vm.addr(providerKey);
        user = vm.addr(userKey);
        funding = IDiamond(DIAMOND).getFundingAccount();
    }

    // ---- probes of unknown getters (raw returndata) ----

    function test_probe_getters() public {
        // getProvider(address) = 0x55f21eb7 ; getModelStats(bytes32) = 0xce535723
        (bool okP, bytes memory retP) = DIAMOND.staticcall(abi.encodeWithSelector(0x55f21eb7, provider));
        emit log_named_uint("getProvider ok", okP ? 1 : 0);
        emit log_named_uint("getProvider retlen", retP.length);
        emit log_named_bytes("getProvider ret", retP);
        (bytes32[] memory ids,) = IDiamond(DIAMOND).getActiveModelIds(0, 1);
        (bool okS, bytes memory retS) = DIAMOND.staticcall(abi.encodeWithSelector(0xce535723, ids[0]));
        emit log_named_uint("getModelStats ok", okS ? 1 : 0);
        emit log_named_uint("getModelStats retlen", retS.length);
        emit log_named_bytes("getModelStats ret", retS);
        // unknown SessionRouter selectors with plausible args — log ok/retlen only
        bytes4[6] memory sels = [bytes4(0xf8ba944b), bytes4(0x61ce471a), bytes4(0x1d78a872), bytes4(0x068bcd8d), bytes4(0x673a2a1f), bytes4(0xa9756858)];
        for (uint256 i; i < sels.length; i++) {
            (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSelector(sels[i], provider));
            emit log_named_uint(string.concat("sel ", vm.toString(sels[i]), " ok"), ok ? 1 : 0);
            emit log_named_uint(string.concat("sel ", vm.toString(sels[i]), " retlen"), ret.length);
        }
    }

    // ---- baseline: C6 reproduction, log session duration math + per-session claim ----

    function test_baseline_c6() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 200_000 ether);
        uint256 fundingBefore = IMOR(MOR).balanceOf(funding);
        uint256 providerBefore = IMOR(MOR).balanceOf(provider);

        bytes32 sid = _open(user, user, 100_000 ether, bidId);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        emit log_named_uint("session stake", s.stake);
        emit log_named_uint("session openedAt", s.openedAt);
        emit log_named_uint("session endsAt", s.endsAt);
        emit log_named_uint("session duration s", uint256(s.endsAt) - uint256(s.openedAt));
        assertTrue(s.isActive);

        vm.warp(uint256(s.endsAt) + 1);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sid);
        uint256 gain = IMOR(MOR).balanceOf(provider) - providerBefore;
        uint256 fundingLoss = fundingBefore - IMOR(MOR).balanceOf(funding);
        emit log_named_uint("C6 provider gain MOR-wei", gain);
        emit log_named_uint("C6 funding loss MOR-wei", fundingLoss);
        emit log_named_uint("C6 providerWithdrawnAmount", IDiamond(DIAMOND).getSession(sid).providerWithdrawnAmount);
        assertEq(gain, fundingLoss);
        assertGt(gain, 0);
        // silence unused warnings
        modelId;
    }
}
