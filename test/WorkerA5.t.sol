// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {WorkerA, IDiamond, IMOR, Session} from "./WorkerA.t.sol";

/// Batch 5: M-V1 stake-refund mechanics + M-V8 LibSD overflow.
contract WorkerA5 is WorkerA {
    function _openDirectKey(address user_, uint256 amount_, bytes32 bidId_, uint256 signerKey_) internal returns (bytes32) {
        bytes memory approval_ = _approval(bidId_, user_);
        bytes memory sig_ = _sign(signerKey_, approval_);
        vm.prank(user_);
        return IDiamond(DIAMOND).openSession(user_, amount_, true, approval_, sig_);
    }

    function _openKey(address user_, uint256 amount_, bytes32 bidId_, uint256 signerKey_) internal returns (bytes32) {
        bytes memory approval_ = _approval(bidId_, user_);
        bytes memory sig_ = _sign(signerKey_, approval_);
        vm.prank(user_);
        return IDiamond(DIAMOND).openSession(user_, amount_, false, approval_, sig_);
    }

    function _closeKey(bytes32 sid_, uint128 ts_, uint32 a_, uint32 b_, uint256 signerKey_, address caller_) internal {
        bytes memory receipt = abi.encode(sid_, uint256(8453), ts_, a_, b_);
        bytes memory sig_ = _sign(signerKey_, receipt);
        vm.prank(caller_);
        IDiamond(DIAMOND).closeSession(receipt, sig_);
    }

    function _settleUser() internal {
        (uint256 onHold,) = IDiamond(DIAMOND).getUserStakesOnHold(user, 255);
        if (onHold > 0) {
            vm.prank(user);
            IDiamond(DIAMOND).withdrawUserStakes(user, 255);
        }
    }

    function _statsWords(bytes32 modelId_) internal view returns (uint256[7] memory w) {
        (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSelector(0xce535723, modelId_));
        require(ok);
        for (uint256 i; i < 7; i++) {
            uint256 v;
            assembly { v := mload(add(add(ret, 32), mul(i, 32))) }
            w[i] = v;
        }
    }

    function _providerWords(address prov_) internal view returns (uint256[7] memory w) {
        (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSelector(0x55f21eb7, prov_));
        require(ok);
        // layout (positional, from live decode): w0=0x20, w1=0xc0, w2=stake, w3=start, w4=end, w5=earned, w6=?
        for (uint256 i; i < 7; i++) {
            uint256 v;
            assembly { v := mload(add(add(ret, 32), mul(i, 32))) }
            w[i] = v;
        }
    }

    /// M-V1 refund mechanics: is deregister refund = stake - earned?
    function test_v1_refund_mechanics() public {
        // (a) fresh provider, no farming: deregister should refund full stake if refund exists
        uint256 keyA = 0xBEEF;
        address provA = vm.addr(keyA);
        (bytes32 modelA, bytes32 bidA) = _registerProvider(provA, 5_000 ether, 1 ether, bytes32("model-a"));
        uint256 balA = IMOR(MOR).balanceOf(provA);
        vm.prank(provA);
        IDiamond(DIAMOND).deleteModelBid(bidA);
        vm.prank(provA);
        IDiamond(DIAMOND).providerDeregister(provA);
        emit log_named_uint("V1a no-farm deregister refund", IMOR(MOR).balanceOf(provA) - balA);
        // model stake: deregister the model, measure refund
        uint256 balA2 = IMOR(MOR).balanceOf(provA);
        vm.prank(provA);
        IDiamond(DIAMOND).modelDeregister(modelA);
        emit log_named_uint("V1a modelDeregister refund", IMOR(MOR).balanceOf(provA) - balA2);

        // (b) fresh provider, farm ~292 MOR, then deregister: refund = stake - earned?
        uint256 keyB = 0xCAFE;
        address provB = vm.addr(keyB);
        (bytes32 modelB, bytes32 bidB) = _registerProvider(provB, 5_000 ether, 1 ether, bytes32("model-b"));
        _setupActor(user, 500_000 ether);
        bytes32 sid = _openKey(user, 100_000 ether, bidB, keyB);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.endsAt) + 1);
        uint256 balB0 = IMOR(MOR).balanceOf(provB);
        vm.prank(provB);
        IDiamond(DIAMOND).claimForProvider(sid);
        uint256 earned = IMOR(MOR).balanceOf(provB) - balB0;
        emit log_named_uint("V1b farmed", earned);
        emit log_named_uint("V1b provider limitPeriodEarned (getProvider w5)", _providerWords(provB)[5]);
        uint256 balB = IMOR(MOR).balanceOf(provB);
        vm.prank(provB);
        IDiamond(DIAMOND).deleteModelBid(bidB);
        vm.prank(provB);
        IDiamond(DIAMOND).providerDeregister(provB);
        emit log_named_uint("V1b post-farm deregister refund", IMOR(MOR).balanceOf(provB) - balB);
        emit log_named_uint("V1b expected refund if stake-minus-earned", 5_000 ether - earned);
        modelB;
    }

    /// M-V8: (c) single max-TPS close on FRESH model stats; (a) 2x TPS=0 then 1x max-TPS.
    function test_v8_single_max_tps_fresh() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        bytes32 sid = _open(user, user, 10_000 ether, bidId);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.endsAt));
        _closeKey(sid, uint128(block.timestamp), type(uint32).max, 0, providerKey, user);
        uint256[7] memory w = _statsWords(modelId);
        emit log_named_uint("V8 fresh 1x max-TPS stats w0 (mean)", w[0]);
        emit log_named_uint("V8 fresh 1x max-TPS stats w1 (sqSum?)", w[1]);
        emit log_named_uint("V8 fresh 1x max-TPS stats w6 (count)", w[6]);
        // victim close afterwards must still work
        vm.warp(block.timestamp + 1);
        bytes32 sid2 = _open(user, user, 10_000 ether, bidId);
        Session memory s2 = IDiamond(DIAMOND).getSession(sid2);
        vm.warp(uint256(s2.endsAt));
        _closeKey(sid2, uint128(block.timestamp), 100, 1000, providerKey, user);
        emit log("V8 fresh: follow-up close after max-TPS close SUCCEEDED");
    }

    function test_v8_three_close_overflow() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        // two TPS=0 closes to seed mean=0
        for (uint256 i; i < 2; i++) {
            bytes32 sid = _open(user, user, 10_000 ether, bidId);
            Session memory s = IDiamond(DIAMOND).getSession(sid);
            vm.warp(uint256(s.endsAt));
            _closeKey(sid, uint128(block.timestamp), 0, 0, providerKey, user);
            vm.warp(block.timestamp + 1);
        }
        uint256[7] memory w0 = _statsWords(modelId);
        emit log_named_uint("V8 seeded stats w0 (mean)", w0[0]);
        emit log_named_uint("V8 seeded stats w1", w0[1]);
        emit log_named_uint("V8 seeded stats w6 (count)", w0[6]);
        // third close: TPS = uint32 max
        bytes32 sid3 = _open(user, user, 10_000 ether, bidId);
        Session memory s3 = IDiamond(DIAMOND).getSession(sid3);
        vm.warp(uint256(s3.endsAt));
        bytes memory receipt = abi.encode(sid3, uint256(8453), uint128(block.timestamp), type(uint32).max, uint32(0));
        bytes memory sig_ = _sign(providerKey, receipt);
        vm.prank(user);
        try IDiamond(DIAMOND).closeSession(receipt, sig_) {
            emit log("V8 3rd close (max TPS): SUCCEEDED");
        } catch {
            emit log("V8 3rd close (max TPS): REVERTED");
        }
        uint256[7] memory w1 = _statsWords(modelId);
        emit log_named_uint("V8 after max-TPS stats w0", w1[0]);
        emit log_named_uint("V8 after max-TPS stats w1", w1[1]);
        emit log_named_uint("V8 after max-TPS stats w6 (count)", w1[6]);
        // victim close afterwards: fresh session, normal TPS
        vm.warp(block.timestamp + 1);
        bytes32 sid4 = _open(user, user, 10_000 ether, bidId);
        Session memory s4 = IDiamond(DIAMOND).getSession(sid4);
        vm.warp(uint256(s4.endsAt));
        bytes memory receipt4 = abi.encode(sid4, uint256(8453), uint128(block.timestamp), uint32(100), uint32(1000));
        bytes memory sig4 = _sign(providerKey, receipt4);
        vm.prank(user);
        try IDiamond(DIAMOND).closeSession(receipt4, sig4) {
            emit log("V8 victim close after max-TPS: SUCCEEDED (not wedged)");
        } catch {
            emit log("V8 victim close after max-TPS: REVERTED (WEDGED)");
        }
    }
}
