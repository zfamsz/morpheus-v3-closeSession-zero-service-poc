// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {WorkerA, IDiamond, IMOR, Session} from "./WorkerA.t.sol";

/// Batch 6: M-V8 precision overflow (int32 extremes) + wedge scope (same-model other provider vs other model).
contract WorkerA6 is WorkerA {
    uint32 internal constant TPS_INT32_MAX = 2_147_483_647; // int32 max
    uint32 internal constant TPS_INT32_MIN = 2_147_483_648; // uint32 value that decodes as int32 min

    function _openKey(address user_, uint256 amount_, bytes32 bidId_, uint256 signerKey_) internal returns (bytes32) {
        bytes memory approval_ = _approval(bidId_, user_);
        bytes memory sig_ = _sign(signerKey_, approval_);
        vm.prank(user_);
        return IDiamond(DIAMOND).openSession(user_, amount_, false, approval_, sig_);
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

    function _statsWords(bytes32 modelId_) internal view returns (uint256[7] memory w) {
        (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSelector(0xce535723, modelId_));
        require(ok);
        for (uint256 i; i < 7; i++) {
            uint256 v;
            assembly { v := mload(add(add(ret, 32), mul(i, 32))) }
            w[i] = v;
        }
    }

    function _logStats(string memory tag, bytes32 modelId_) internal {
        uint256[7] memory w = _statsWords(modelId_);
        emit log_named_uint(string.concat(tag, " w0"), w[0]);
        emit log_named_uint(string.concat(tag, " w1"), w[1]);
        emit log_named_uint(string.concat(tag, " w2"), w[2]);
        emit log_named_uint(string.concat(tag, " w3"), w[3]);
        emit log_named_uint(string.concat(tag, " w4"), w[4]);
        emit log_named_uint(string.concat(tag, " w5"), w[5]);
        emit log_named_uint(string.concat(tag, " w6"), w[6]);
    }

    function test_v8_int32_extremes() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 5_000_000 ether);
        // seed: 2 closes at TPS = int32 max
        for (uint256 i; i < 2; i++) {
            bytes32 sid = _openKey(user, 10_000 ether, bidId, providerKey);
            Session memory s = IDiamond(DIAMOND).getSession(sid);
            vm.warp(uint256(s.endsAt));
            bool ok = _closeTry(sid, uint128(block.timestamp), TPS_INT32_MAX, 0, providerKey, user);
            emit log_named_uint("seed close ok", ok ? 1 : 0);
            vm.warp(block.timestamp + 1);
        }
        _logStats("seeded", modelId);
        // trigger: 1 close at TPS = int32 min (uint32 2147483648)
        bytes32 sidT = _openKey(user, 10_000 ether, bidId, providerKey);
        Session memory sT = IDiamond(DIAMOND).getSession(sidT);
        vm.warp(uint256(sT.endsAt));
        bool okT = _closeTry(sidT, uint128(block.timestamp), TPS_INT32_MIN, 0, providerKey, user);
        emit log_named_uint("trigger close (int32 min) ok", okT ? 1 : 0);
        _logStats("after trigger", modelId);
        // victim close afterwards, same model, normal TPS
        vm.warp(block.timestamp + 1);
        bytes32 sidV = _openKey(user, 10_000 ether, bidId, providerKey);
        Session memory sV = IDiamond(DIAMOND).getSession(sidV);
        vm.warp(uint256(sV.endsAt));
        bool okV = _closeTry(sidV, uint128(block.timestamp), 100, 1000, providerKey, user);
        emit log_named_uint("victim close same model ok", okV ? 1 : 0);
        _logStats("after victim", modelId);
        // retry trigger session with normal TPS (is it bricked or retryable?)
        bool okR = _closeTry(sidT, uint128(block.timestamp), 100, 1000, providerKey, user);
        emit log_named_uint("trigger session retry normal TPS ok", okR ? 1 : 0);
    }

    function _wedgeModel(bytes32 bidId_, uint256 signerKey_) internal returns (bool) {
        for (uint256 i; i < 2; i++) {
            bytes32 sid = _openKey(user, 10_000 ether, bidId_, signerKey_);
            Session memory s = IDiamond(DIAMOND).getSession(sid);
            vm.warp(uint256(s.endsAt));
            _closeTry(sid, uint128(block.timestamp), TPS_INT32_MAX, 0, signerKey_, user);
            vm.warp(block.timestamp + 1);
        }
        bytes32 sidT = _openKey(user, 10_000 ether, bidId_, signerKey_);
        Session memory sT = IDiamond(DIAMOND).getSession(sidT);
        vm.warp(uint256(sT.endsAt));
        return _closeTry(sidT, uint128(block.timestamp), TPS_INT32_MIN, 0, signerKey_, user);
    }

    function _victimClose(bytes32 bidId_, uint256 signerKey_) internal returns (bool) {
        bytes32 sid = _openKey(user, 10_000 ether, bidId_, signerKey_);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.endsAt));
        return _closeTry(sid, uint128(block.timestamp), 100, 1000, signerKey_, user);
    }

    /// Wedge scope: if model M stats wedge, does a DIFFERENT provider's close on M revert,
    /// and does a close on a DIFFERENT model M2 still work?
    function test_v8_wedge_scope() public {
        // provider1 owns model M; provider2 (different key) bids on M too
        (bytes32 modelId, bytes32 bidId1) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        uint256 key2 = 0xBEEF;
        address prov2 = vm.addr(key2);
        _setupActor(prov2, 1_000 ether);
        vm.startPrank(prov2);
        IDiamond(DIAMOND).providerRegister(prov2, 0.2 ether, "https://p2.example");
        vm.stopPrank();
        // prov2 posts a bid on provider1's model
        vm.prank(prov2);
        bytes32 bidId2 = IDiamond(DIAMOND).postModelBid(prov2, modelId, PRICE_MAX);
        // provider2's own model M2
        vm.startPrank(prov2);
        string[] memory tags_;
        IDiamond(DIAMOND).modelRegister(prov2, bytes32("m2"), bytes32("cid2"), 0, 0.1 ether, "m2", tags_);
        vm.stopPrank();
        bytes32 modelId2 = IDiamond(DIAMOND).getModelId(prov2, bytes32("m2"));
        vm.prank(prov2);
        bytes32 bidIdM2 = IDiamond(DIAMOND).postModelBid(prov2, modelId2, PRICE_MAX);
        _setupActor(user, 5_000_000 ether);

        // wedge attempt on M via provider1 sessions: 2x int32max then 1x int32min
        bool okT = _wedgeModel(bidId1, providerKey);
        emit log_named_uint("wedge trigger close ok", okT ? 1 : 0);
        _logStats("M after trigger", modelId);

        // victim: DIFFERENT provider (prov2) session on SAME model M
        vm.warp(block.timestamp + 1);
        bool okV2 = _victimClose(bidId2, key2);
        emit log_named_uint("other-provider close same model ok", okV2 ? 1 : 0);

        // victim: session on DIFFERENT model M2
        vm.warp(block.timestamp + 1);
        bool okM2 = _victimClose(bidIdM2, key2);
        emit log_named_uint("close different model ok", okM2 ? 1 : 0);
        _logStats("M2 after", modelId2);
    }
}
