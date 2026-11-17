// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {WorkerA, IDiamond, IMOR, Session} from "./WorkerA.t.sol";

/// Batch 4: receipt-b disentangle, M-V1 limiter reset, M-V14 replay/chain, M-V6 double-pay.
contract WorkerA4 is WorkerA {
    function _openDirect(address user_, uint256 amount_, bytes32 bidId_) internal returns (bytes32) {
        bytes memory approval_ = _approval(bidId_, user_);
        bytes memory sig_ = _sign(providerKey, approval_);
        vm.prank(user_);
        return IDiamond(DIAMOND).openSession(user_, amount_, true, approval_, sig_);
    }

    function _receipt(bytes32 sid_, uint256 chain_, uint128 ts_, uint32 a_, uint32 b_) internal pure returns (bytes memory) {
        return abi.encode(sid_, chain_, ts_, a_, b_);
    }

    function _close(bytes32 sid_, uint128 ts_, uint32 a_, uint32 b_) internal {
        bytes memory receipt = _receipt(sid_, 8453, ts_, a_, b_);
        bytes memory sig_ = _sign(providerKey, receipt);
        vm.prank(user);
        IDiamond(DIAMOND).closeSession(receipt, sig_);
    }

    function _settleUser() internal {
        (uint256 onHold,) = IDiamond(DIAMOND).getUserStakesOnHold(user, 255);
        if (onHold > 0) {
            vm.prank(user);
            IDiamond(DIAMOND).withdrawUserStakes(user, 255);
        }
    }

    function _modelStatsRaw(bytes32 modelId_) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSelector(0xce535723, modelId_));
        require(ok);
        return ret;
    }

    function _statsWords(bytes32 modelId_) internal view returns (uint256[7] memory w) {
        bytes memory ret = _modelStatsRaw(modelId_);
        for (uint256 i; i < 7; i++) {
            uint256 v;
            assembly { v := mload(add(add(ret, 32), mul(i, 32))) }
            w[i] = v;
        }
    }

    /// Disentangle receipt field b: close at elapsed 500 with a=42, b=7777.
    function test_receipt_b_disentangle() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        bytes32 sid = _openDirect(user, 10_000 ether, bidId);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.openedAt) + 500);
        uint256 provBefore = IMOR(MOR).balanceOf(provider);
        _close(sid, uint128(block.timestamp), 42, 7777);
        emit log_named_uint("pay with a=42 b=7777 @500s", IMOR(MOR).balanceOf(provider) - provBefore);
        uint256[7] memory w = _statsWords(modelId);
        emit log_named_uint("stats w0", w[0]);
        emit log_named_uint("stats w1", w[1]);
        emit log_named_uint("stats w2", w[2]);
        emit log_named_uint("stats w3", w[3]);
        emit log_named_uint("stats w4", w[4]);
        emit log_named_uint("stats w5", w[5]);
        emit log_named_uint("stats w6", w[6]);
    }

    /// M-V14: receipt replay across sessions + wrong chain id.
    function test_v14_replay_and_chain() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        bytes32 sidA = _open(user, user, 10_000 ether, bidId);
        vm.warp(block.timestamp + 1);
        bytes32 sidB = _open(user, user, 10_000 ether, bidId);
        Session memory sA = IDiamond(DIAMOND).getSession(sidA);
        vm.warp(uint256(sA.endsAt) + 1);
        // (1) close A with its own valid receipt
        _close(sidA, uint128(block.timestamp), 100, 1000);
        assertTrue(IDiamond(DIAMOND).getSession(sidA).closedAt != 0, "A closed");
        // (2) replay A's receipt against B: call closeSession with A's receipt again.
        // closeSession decodes sessionId from the receipt, so this targets A, not B.
        bytes memory receiptA = _receipt(sidA, 8453, uint128(block.timestamp), 100, 1000);
        bytes memory sigA = _sign(providerKey, receiptA);
        vm.prank(user);
        try IDiamond(DIAMOND).closeSession(receiptA, sigA) {
            emit log("replay double-close of A: SUCCEEDED (no revert)");
        } catch {
            emit log("replay double-close of A: reverted");
        }
        emit log_named_uint("B closedAt after replay (0=still open)", IDiamond(DIAMOND).getSession(sidB).closedAt);
        assertTrue(IDiamond(DIAMOND).getSession(sidB).isActive, "B must still be active");
        // (3) receipt for B but with chainId=1
        bytes memory receiptWrongChain = _receipt(sidB, 1, uint128(block.timestamp), 100, 1000);
        bytes memory sigWC = _sign(providerKey, receiptWrongChain);
        vm.prank(user);
        try IDiamond(DIAMOND).closeSession(receiptWrongChain, sigWC) {
            emit log("wrong-chain receipt close: SUCCEEDED");
        } catch {
            emit log("wrong-chain receipt close: reverted");
        }
        emit log_named_uint("B closedAt after wrong-chain receipt", IDiamond(DIAMOND).getSession(sidB).closedAt);
        // (4) approval with chainId=1 for openSession
        bytes memory approvalWC = abi.encode(bidId, uint256(1), user, uint128(block.timestamp));
        bytes memory sigAWC = _sign(providerKey, approvalWC);
        vm.prank(user);
        try IDiamond(DIAMOND).openSession(user, 10_000 ether, false, approvalWC, sigAWC) returns (bytes32 sidWC) {
            emit log_named_bytes32("wrong-chain approval OPENED session", sidWC);
        } catch {
            emit log("wrong-chain approval open: reverted");
        }
        modelId;
    }

    /// M-V6: claim pre-close, then close with full-duration receipt. Direct + non-direct.
    function test_v6_double_pay() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 2_000_000 ether);
        // --- direct leg ---
        bytes32 sidD = _openDirect(user, 10_000 ether, bidId);
        Session memory sD = IDiamond(DIAMOND).getSession(sidD);
        vm.warp(uint256(sD.endsAt) + 1);
        uint256 provBefore = IMOR(MOR).balanceOf(provider);
        uint256 fundingBefore = IMOR(MOR).balanceOf(funding);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sidD);
        uint256 claimPay = IMOR(MOR).balanceOf(provider) - provBefore;
        int256 fundingDelta = int256(IMOR(MOR).balanceOf(funding)) - int256(fundingBefore);
        emit log_named_uint("V6 direct claimForProvider pay", claimPay);
        emit log_named_int("V6 direct funding delta on claim", fundingDelta);
        emit log_named_uint("V6 direct providerWithdrawn after claim", IDiamond(DIAMOND).getSession(sidD).providerWithdrawnAmount);
        // now close with full receipt
        provBefore = IMOR(MOR).balanceOf(provider);
        _close(sidD, uint128(block.timestamp), 100, 2921);
        uint256 closePay = IMOR(MOR).balanceOf(provider) - provBefore;
        emit log_named_uint("V6 direct close pay after claim", closePay);
        emit log_named_uint("V6 direct TOTAL provider pay", claimPay + closePay);
        emit log_named_uint("V6 direct earned (dur*price)", (uint256(sD.endsAt) - uint256(sD.openedAt)) * PRICE_MAX);
        vm.warp(block.timestamp + 2 days);
        _settleUser();
        // --- non-direct leg ---
        bytes32 sidN = _open(user, user, 10_000 ether, bidId);
        Session memory sN = IDiamond(DIAMOND).getSession(sidN);
        vm.warp(uint256(sN.endsAt) + 1);
        provBefore = IMOR(MOR).balanceOf(provider);
        fundingBefore = IMOR(MOR).balanceOf(funding);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sidN);
        uint256 claimPayN = IMOR(MOR).balanceOf(provider) - provBefore;
        emit log_named_uint("V6 stipend claimForProvider pay", claimPayN);
        emit log_named_int("V6 stipend funding delta on claim", int256(IMOR(MOR).balanceOf(funding)) - int256(fundingBefore));
        provBefore = IMOR(MOR).balanceOf(provider);
        _close(sidN, uint128(block.timestamp), 100, 2921);
        uint256 closePayN = IMOR(MOR).balanceOf(provider) - provBefore;
        emit log_named_uint("V6 stipend close pay after claim", closePayN);
        emit log_named_uint("V6 stipend TOTAL provider pay", claimPayN + closePayN);
        emit log_named_uint("V6 stipend earned (dur*price)", (uint256(sN.endsAt) - uint256(sN.openedAt)) * PRICE_MAX);
        modelId;
    }

    /// M-V1: farm to the cap, deregister, re-register, farm again.
    function test_v1_limiter_reset() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 50_000_000 ether);
        // cycle 1: 1M-MOR sessions, ~2921 MOR earned each; cap = 5000
        uint256 cycle1;
        for (uint256 i; i < 4; i++) {
            bytes32 sid = _open(user, user, 1_000_000 ether, bidId);
            Session memory s = IDiamond(DIAMOND).getSession(sid);
            vm.warp(uint256(s.endsAt) + 1);
            uint256 before = IMOR(MOR).balanceOf(provider);
            vm.prank(provider);
            IDiamond(DIAMOND).claimForProvider(sid);
            uint256 got = IMOR(MOR).balanceOf(provider) - before;
            cycle1 += got;
            emit log_named_uint("V1 cycle1 claim", got);
            if (got == 0) break;
        }
        emit log_named_uint("V1 cycle1 TOTAL claimed", cycle1);
        assertGe(cycle1, 4_900 ether, "cycle1 must reach ~cap");
        // deregister path: try direct providerDeregister first
        uint256 provBalBefore = IMOR(MOR).balanceOf(provider);
        vm.prank(provider);
        try IDiamond(DIAMOND).providerDeregister(provider) {
            emit log("V1 providerDeregister with active bid: SUCCEEDED");
        } catch {
            emit log("V1 providerDeregister with active bid: reverted, deleting bid first");
            vm.prank(provider);
            IDiamond(DIAMOND).deleteModelBid(bidId);
            vm.prank(provider);
            IDiamond(DIAMOND).providerDeregister(provider);
            emit log("V1 providerDeregister after bid delete: SUCCEEDED");
        }
        emit log_named_uint("V1 provider balance delta on deregister", IMOR(MOR).balanceOf(provider) - provBalBefore);
        // re-register same address, same stake
        (bytes32 modelId2, bytes32 bidId2) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        // cycle 2: farm again
        uint256 cycle2;
        for (uint256 i; i < 4; i++) {
            bytes32 sid = _open(user, user, 1_000_000 ether, bidId2);
            Session memory s = IDiamond(DIAMOND).getSession(sid);
            vm.warp(uint256(s.endsAt) + 1);
            uint256 before = IMOR(MOR).balanceOf(provider);
            vm.prank(provider);
            IDiamond(DIAMOND).claimForProvider(sid);
            uint256 got = IMOR(MOR).balanceOf(provider) - before;
            cycle2 += got;
            emit log_named_uint("V1 cycle2 claim", got);
            if (got == 0) break;
        }
        emit log_named_uint("V1 cycle2 TOTAL claimed", cycle2);
        emit log_named_uint("V1 GRAND TOTAL claimed (both cycles)", cycle1 + cycle2);
        modelId; modelId2;
    }
}
