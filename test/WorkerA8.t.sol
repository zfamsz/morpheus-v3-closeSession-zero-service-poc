// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {WorkerA, IDiamond, IMOR, Session} from "./WorkerA.t.sol";

/// Batch 8: V3 sibling (wrong-provider receipt), receipt-ts vs block-ts,
/// V9 max single-session spread + 365d reset, 609-model stake census.
contract WorkerA8 is WorkerA {
    function _openDirectKey(address user_, uint256 amount_, bytes32 bidId_, uint256 signerKey_) internal returns (bytes32) {
        bytes memory approval_ = _approval(bidId_, user_);
        bytes memory sig_ = _sign(signerKey_, approval_);
        vm.prank(user_);
        return IDiamond(DIAMOND).openSession(user_, amount_, true, approval_, sig_);
    }

    function _closeTry(bytes32 sid_, uint128 ts_, uint32 a_, uint32 b_, uint256 signerKey_, address caller_) internal returns (bool) {
        bytes memory receipt = abi.encode(sid_, uint256(8453), ts_, a_, b_);
        bytes memory sig_ = _sign(signerKey_, receipt);
        vm.prank(caller_);
        try IDiamond(DIAMOND).closeSession(receipt, sig_) {
            return true;
        } catch {
            return false;
        }
    }

    function _settleUser() internal {
        (uint256 onHold,) = IDiamond(DIAMOND).getUserStakesOnHold(user, 255);
        if (onHold > 0) {
            vm.prank(user);
            IDiamond(DIAMOND).withdrawUserStakes(user, 255);
        }
    }

    function _providerEarned(address prov_) internal view returns (uint256) {
        (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSelector(0x55f21eb7, prov_));
        require(ok);
        uint256 v;
        assembly { v := mload(add(ret, 192)) } // w5 = limitPeriodEarned (positional)
        return v;
    }

    /// V3 sibling: receipt signed by provider A used to close provider B's session.
    function test_v3_wrong_provider_receipt() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        uint256 keyB = 0xBEEF;
        address provB = vm.addr(keyB);
        (bytes32 modelB, bytes32 bidB) = _registerProvider(provB, 5_000 ether, 1 ether, bytes32("model-b"));
        _setupActor(user, 500_000 ether);
        bytes32 sid = _openDirectKey(user, 10_000 ether, bidB, keyB);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.endsAt));
        uint256 provBBefore = IMOR(MOR).balanceOf(provB);
        // close B's session with a receipt signed by provider A (wrong signer)
        bool ok = _closeTry(sid, uint128(block.timestamp), 100, 2921, providerKey, user);
        emit log_named_uint("close with wrong-provider receipt ok", ok ? 1 : 0);
        emit log_named_uint("session closedAt (0=open)", IDiamond(DIAMOND).getSession(sid).closedAt);
        emit log_named_uint("provider B pay", IMOR(MOR).balanceOf(provB) - provBBefore);
        assertTrue(ok, "V3: wrong-provider receipt must close the session");
        assertTrue(IDiamond(DIAMOND).getSession(sid).closedAt != 0, "V3: session must be closed");
        assertEq(IMOR(MOR).balanceOf(provB) - provBBefore, (uint256(s.endsAt) - uint256(s.openedAt)) * PRICE_MAX, "V3: wrong-provider receipt must pay provider B in full");
        modelId; modelB;
    }

    /// Receipt-ts vs block-ts: close at block time openedAt+500 with receipt ts = openedAt+2500.
    function test_receipt_ts_vs_block_ts() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        bytes32 sid = _openDirectKey(user, 10_000 ether, bidId, providerKey);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.openedAt) + 500);
        uint256 provBefore = IMOR(MOR).balanceOf(provider);
        // receipt claims ts = openedAt+2500 (future vs block time, within duration 2921)
        bool ok = _closeTry(sid, uint128(s.openedAt) + 2500, 100, 2921, providerKey, user);
        uint256 pay = IMOR(MOR).balanceOf(provider) - provBefore;
        emit log_named_uint("close with receipt-ts +2500 @block +500 ok", ok ? 1 : 0);
        emit log_named_uint("provider pay (5 if block-ts, 25 if receipt-ts)", pay);
        assertTrue(ok, "V3: receipt-ts close must succeed");
        assertEq(pay, 5 ether, "V3: pay must follow block time, not receipt ts");
        // second session: receipt ts beyond endsAt
        vm.warp(block.timestamp + 1);
        bytes32 sid2 = _openDirectKey(user, 10_000 ether, bidId, providerKey);
        Session memory s2 = IDiamond(DIAMOND).getSession(sid2);
        vm.warp(uint256(s2.openedAt) + 500);
        uint256 provBefore2 = IMOR(MOR).balanceOf(provider);
        bool ok2 = _closeTry(sid2, uint128(s2.endsAt) + 100_000, 100, 2921, providerKey, user);
        uint256 pay2 = IMOR(MOR).balanceOf(provider) - provBefore2;
        emit log_named_uint("close with receipt-ts endsAt+100k ok", ok2 ? 1 : 0);
        emit log_named_uint("provider pay2 (5 if block-ts, >29 if receipt-ts)", pay2);
        assertTrue(ok2, "V3: receipt-ts beyond endsAt close must succeed");
        assertEq(pay2, 5 ether, "V3: pay must follow block time, not receipt ts");
        modelId;
    }

    /// V9 max: 1M-MOR direct session vs 0.2-MOR provider; then 365d reset check.
    function test_v9_max_and_reset() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 0.2 ether, 0.1 ether, bytes32("base-model"));
        _setupActor(user, 5_000_000 ether);
        uint256 userStart = IMOR(MOR).balanceOf(user);
        uint256 provStart = IMOR(MOR).balanceOf(provider);
        // max session: 1,000,000 MOR
        bytes32 sid = _openDirectKey(user, 1_000_000 ether, bidId, providerKey);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.endsAt));
        _closeTry(sid, uint128(block.timestamp), 100, 292150, providerKey, user);
        vm.warp(block.timestamp + 2 days);
        _settleUser();
        uint256 credit1 = IMOR(MOR).balanceOf(provider) - provStart;
        uint256 debit1 = userStart - IMOR(MOR).balanceOf(user);
        emit log_named_uint("V9max earned (dur*price)", (uint256(s.endsAt) - uint256(s.openedAt)) * PRICE_MAX);
        emit log_named_uint("V9max provider credited", credit1);
        emit log_named_uint("V9max user debited", debit1);
        emit log_named_uint("V9max single-session spread", debit1 - credit1);
        // warp past the 365-day limit period; does the old spread release? does the cap reset?
        emit log_named_uint("V9 earned before reset", _providerEarned(provider));
        vm.warp(block.timestamp + 366 days);
        emit log_named_uint("V9 earned after +366d (0 = reset)", _providerEarned(provider));
        uint256 userStart2 = IMOR(MOR).balanceOf(user);
        uint256 provStart2 = IMOR(MOR).balanceOf(provider);
        bytes32 sid2 = _openDirectKey(user, 10_000 ether, bidId, providerKey);
        Session memory s2 = IDiamond(DIAMOND).getSession(sid2);
        vm.warp(uint256(s2.endsAt));
        _closeTry(sid2, uint128(block.timestamp), 100, 2921, providerKey, user);
        vm.warp(block.timestamp + 2 days);
        _settleUser();
        uint256 credit2 = IMOR(MOR).balanceOf(provider) - provStart2;
        uint256 debit2 = userStart2 - IMOR(MOR).balanceOf(user);
        emit log_named_uint("V9 post-reset provider credited (fresh 0.2 cap?)", credit2);
        emit log_named_uint("V9 post-reset user debited", debit2);
        emit log_named_uint("V9 post-reset new spread", debit2 - credit2);
        emit log_named_uint("V9 provider TOTAL received (both periods)", (IMOR(MOR).balanceOf(provider) - provStart));
        emit log_named_uint("V9 user TOTAL lost (both periods)", userStart - IMOR(MOR).balanceOf(user));
        modelId;
    }
}
