// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {WorkerA, IDiamond, IMOR, Session} from "./WorkerA.t.sol";

/// Batch 3: duration/price scaling, close-payment formula, D-1 binding case, zero-TPS close.
contract WorkerA3 is WorkerA {
    function _openDirect(address user_, uint256 amount_, bytes32 bidId_) internal returns (bytes32) {
        bytes memory approval_ = _approval(bidId_, user_);
        bytes memory sig_ = _sign(providerKey, approval_);
        vm.prank(user_);
        return IDiamond(DIAMOND).openSession(user_, amount_, true, approval_, sig_);
    }

    function _receipt(bytes32 sid_, uint128 ts_, uint32 a_, uint32 b_) internal pure returns (bytes memory) {
        return abi.encode(sid_, uint256(8453), ts_, a_, b_);
    }

    function _settleUser() internal {
        (uint256 onHold,) = IDiamond(DIAMOND).getUserStakesOnHold(user, 255);
        if (onHold > 0) {
            vm.prank(user);
            IDiamond(DIAMOND).withdrawUserStakes(user, 255);
        }
    }

    function _close(bytes32 sid_, uint128 ts_, uint32 a_, uint32 b_) internal {
        bytes memory receipt = _receipt(sid_, ts_, a_, b_);
        bytes memory sig_ = _sign(providerKey, receipt);
        vm.prank(user);
        IDiamond(DIAMOND).closeSession(receipt, sig_);
    }

    function test_duration_scaling() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 2_000_000 ether);
        uint256[4] memory amounts = [uint256(10_000 ether), 20_000 ether, 50_000 ether, 200_000 ether];
        for (uint256 i; i < amounts.length; i++) {
            bytes32 sid = _open(user, user, amounts[i], bidId);
            Session memory s = IDiamond(DIAMOND).getSession(sid);
            emit log_named_uint("amount", amounts[i]);
            emit log_named_uint("duration s", uint256(s.endsAt) - uint256(s.openedAt));
            vm.warp(uint256(s.endsAt) + 1);
            vm.prank(provider);
            IDiamond(DIAMOND).claimForProvider(sid);
        }
        modelId;
    }

    /// Close-payment formula: direct sessions closed at elapsed 0 / 500 / 1500 / endsAt.
    function test_close_formula() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 2_000_000 ether);
        uint256[4] memory elapsed = [uint256(0), 500, 1500, 2921];
        for (uint256 i; i < elapsed.length; i++) {
            bytes32 sid = _openDirect(user, 10_000 ether, bidId);
            Session memory s = IDiamond(DIAMOND).getSession(sid);
            uint256 dur = uint256(s.endsAt) - uint256(s.openedAt);
            uint256 warpTo = uint256(s.openedAt) + elapsed[i];
            if (warpTo > uint256(s.endsAt)) warpTo = uint256(s.endsAt);
            vm.warp(warpTo);
            uint256 provBefore = IMOR(MOR).balanceOf(provider);
            uint256 userBefore = IMOR(MOR).balanceOf(user);
            uint256 diaBefore = IMOR(MOR).balanceOf(DIAMOND);
            _close(sid, uint128(block.timestamp), 0, 0);
            Session memory s2 = IDiamond(DIAMOND).getSession(sid);
            emit log_named_uint("elapsed", elapsed[i]);
            emit log_named_uint("duration", dur);
            emit log_named_uint("providerPay", IMOR(MOR).balanceOf(provider) - provBefore);
            emit log_named_uint("userImmediateRefund", IMOR(MOR).balanceOf(user) - userBefore);
            emit log_named_int("diamondDelta", int256(IMOR(MOR).balanceOf(DIAMOND)) - int256(diaBefore));
            emit log_named_uint("providerWithdrawn", s2.providerWithdrawnAmount);
            emit log_named_uint("closedAt-openedAt", uint256(s2.closedAt) - uint256(s.openedAt));
            // settle user stake to keep balances clean for next iteration
            vm.warp(block.timestamp + 2 days);
            _settleUser();
        }
        modelId;
    }

    /// M-V3: close at endsAt with a valid provider-signed ZERO-TPS receipt.
    function test_v3_zero_tps_close() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        bytes32 sid = _openDirect(user, 10_000 ether, bidId);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.endsAt));
        uint256 provBefore = IMOR(MOR).balanceOf(provider);
        uint256 userBefore = IMOR(MOR).balanceOf(user);
        _close(sid, uint128(block.timestamp), 0, 0);
        uint256 pay = IMOR(MOR).balanceOf(provider) - provBefore;
        emit log_named_uint("V3 zero-TPS close providerPay MOR-wei", pay);
        emit log_named_uint("V3 full-duration earned MOR-wei", (uint256(s.endsAt) - uint256(s.openedAt)) * PRICE_MAX);
        emit log_named_uint("V3 user immediate delta", IMOR(MOR).balanceOf(user) - userBefore);
        assertEq(pay, (uint256(s.endsAt) - uint256(s.openedAt)) * PRICE_MAX, "V3: zero-TPS close must pay full earned");
        vm.warp(block.timestamp + 2 days);
        _settleUser();
        emit log_named_uint("V3 user net loss MOR-wei", 500_000 ether - IMOR(MOR).balanceOf(user));
        assertEq(500_000 ether - IMOR(MOR).balanceOf(user), pay, "V3: user net loss must equal provider pay");
        modelId;
    }

    /// M-V9 core (D-1 binding): provider stake 0.2 MOR, direct session earned ~29.21 MOR.
    /// Repeat 3 sessions; measure provider credit vs user debit vs spread locked in diamond.
    function test_v9_spread_binding() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 0.2 ether, 0.1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        uint256 totalSpread;
        for (uint256 i; i < 3; i++) {
            uint256 userStart = IMOR(MOR).balanceOf(user);
            bytes32 sid = _openDirect(user, 10_000 ether, bidId);
            Session memory s = IDiamond(DIAMOND).getSession(sid);
            vm.warp(uint256(s.endsAt));
            uint256 provBefore = IMOR(MOR).balanceOf(provider);
            uint256 userBefore = IMOR(MOR).balanceOf(user);
            uint256 diaBefore = IMOR(MOR).balanceOf(DIAMOND);
            _close(sid, uint128(block.timestamp), 100, 2921);
            Session memory s2 = IDiamond(DIAMOND).getSession(sid);
            uint256 credit = IMOR(MOR).balanceOf(provider) - provBefore;
            // user debit measured after full settlement (close refund + withdraw)
            vm.warp(block.timestamp + 2 days);
            _settleUser();
            uint256 debit = userStart - IMOR(MOR).balanceOf(user);
            // diamond should retain debit - credit
            int256 diaDelta = int256(IMOR(MOR).balanceOf(DIAMOND)) - int256(diaBefore);
            emit log_named_uint("V9 session earned (dur*price)", (uint256(s.endsAt) - uint256(s.openedAt)) * PRICE_MAX);
            emit log_named_uint("V9 provider credited", credit);
            emit log_named_uint("V9 user debited (settled)", debit);
            emit log_named_int("V9 diamond retained", diaDelta);
            emit log_named_uint("V9 providerWithdrawn", s2.providerWithdrawnAmount);
            totalSpread += (debit > credit ? debit - credit : 0);
        }
        emit log_named_uint("V9 cumulative spread MOR-wei", totalSpread);
        modelId;
    }
}
