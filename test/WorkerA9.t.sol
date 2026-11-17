// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {WorkerA, IDiamond, IMOR, Session} from "./WorkerA.t.sol";

/// Batch 9: V3 follow-ups — receipt signer irrelevance + user exit without close.
/// + 609-model census (slow RPC; run alone).
contract WorkerA9 is WorkerA {
    function _openDirectKey(address user_, uint256 amount_, bytes32 bidId_, uint256 signerKey_) internal returns (bytes32) {
        bytes memory approval_ = _approval(bidId_, user_);
        bytes memory sig_ = _sign(signerKey_, approval_);
        vm.prank(user_);
        return IDiamond(DIAMOND).openSession(user_, amount_, true, approval_, sig_);
    }

    /// Close a direct session with a receipt signed by a stranger (never a provider).
    /// Does the session close, and does the provider get paid in full?
    function test_v3_stranger_signed_receipt() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        bytes32 sid = _openDirectKey(user, 10_000 ether, bidId, providerKey);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.endsAt));
        uint256 provBefore = IMOR(MOR).balanceOf(provider);
        uint256 strangerKey = 0xBAD;
        bytes memory receipt = abi.encode(sid, uint256(8453), uint128(block.timestamp), uint32(0), uint32(0));
        bytes memory sigStranger = _sign(strangerKey, receipt);
        bool closedStranger;
        vm.prank(user);
        try IDiamond(DIAMOND).closeSession(receipt, sigStranger) {
            closedStranger = true;
            emit log("stranger-signed receipt close: SUCCEEDED");
        } catch {
            closedStranger = false;
            emit log("stranger-signed receipt close: REVERTED");
        }
        emit log_named_uint("provider pay after stranger-signed close", IMOR(MOR).balanceOf(provider) - provBefore);
        emit log_named_uint("session closedAt", IDiamond(DIAMOND).getSession(sid).closedAt);
        assertTrue(closedStranger, "V3: stranger-signed receipt must close the session");
        assertEq(IMOR(MOR).balanceOf(provider) - provBefore, (uint256(s.endsAt) - uint256(s.openedAt)) * PRICE_MAX, "V3: stranger-signed close must pay provider in full");
        assertTrue(IDiamond(DIAMOND).getSession(sid).closedAt != 0, "V3: session must be closed");
        modelId;
    }

    /// Close with a garbage (random) signature. Does the receipt signature matter at all?
    function test_v3_garbage_signature_receipt() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        bytes32 sid = _openDirectKey(user, 10_000 ether, bidId, providerKey);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.endsAt));
        uint256 provBefore = IMOR(MOR).balanceOf(provider);
        bytes memory receipt = abi.encode(sid, uint256(8453), uint128(block.timestamp), uint32(0), uint32(0));
        bytes memory garbage = hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
        bool closedGarbage;
        vm.prank(user);
        try IDiamond(DIAMOND).closeSession(receipt, garbage) {
            closedGarbage = true;
            emit log("garbage-signature receipt close: SUCCEEDED");
        } catch {
            closedGarbage = false;
            emit log("garbage-signature receipt close: REVERTED");
        }
        emit log_named_uint("provider pay after garbage-sig close", IMOR(MOR).balanceOf(provider) - provBefore);
        emit log_named_uint("session closedAt", IDiamond(DIAMOND).getSession(sid).closedAt);
        assertFalse(closedGarbage, "V3: garbage signature must NOT close the session");
        assertEq(IMOR(MOR).balanceOf(provider) - provBefore, 0, "V3: garbage-sig close must pay 0");
        assertEq(IDiamond(DIAMOND).getSession(sid).closedAt, 0, "V3: session must stay open");
        modelId;
    }

    /// Can the user exit (recover stake) WITHOUT closing — i.e. is close the only exit?
    function test_v3_withdraw_without_close() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        uint256 userStart = IMOR(MOR).balanceOf(user);
        bytes32 sid = _openDirectKey(user, 10_000 ether, bidId, providerKey);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.endsAt) + 1);
        (uint256 onHold, uint256 totalOnHold) = IDiamond(DIAMOND).getUserStakesOnHold(user, 255);
        emit log_named_uint("stakes on hold before close", onHold);
        emit log_named_uint("total on hold before close", totalOnHold);
        vm.prank(user);
        bool withdrew;
        try IDiamond(DIAMOND).withdrawUserStakes(user, 255) {
            withdrew = true;
            emit log("withdrawUserStakes without close: SUCCEEDED");
        } catch {
            withdrew = false;
            emit log("withdrawUserStakes without close: REVERTED");
        }
        emit log_named_uint("user recovered without close", IMOR(MOR).balanceOf(user) - (userStart - 10_000 ether));
        emit log_named_uint("session still active", IDiamond(DIAMOND).getSession(sid).isActive ? 1 : 0);
        assertFalse(withdrew, "V3: withdraw without close must revert");
        assertEq(IMOR(MOR).balanceOf(user) - (userStart - 10_000 ether), 0, "V3: user must recover 0 without close");
        assertTrue(IDiamond(DIAMOND).getSession(sid).isActive, "V3: session must stay active");
        modelId;
    }

    /// Census: total escrowed stake across all 609 live models (read-only, slow RPC).
    function test_census_609_model_stakes() public {
        (bytes32[] memory ids, uint256 total) = IDiamond(DIAMOND).getActiveModelIds(0, 700);
        emit log_named_uint("census models returned", ids.length);
        emit log_named_uint("census total", total);
        uint256 sum;
        uint256 over1;
        uint256 over100;
        uint256 maxStake;
        for (uint256 i; i < ids.length; i++) {
            (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSelector(0x21e7c498, ids[i]));
            require(ok);
            uint256 st;
            assembly { st := mload(add(ret, 128)) }
            sum += st;
            if (st > maxStake) maxStake = st;
            if (st >= 1 ether) over1++;
            if (st >= 100 ether) over100++;
        }
        emit log_named_uint("census total escrowed model stake MOR-wei", sum);
        emit log_named_uint("census max single model stake MOR-wei", maxStake);
        emit log_named_uint("census models with stake >= 1 MOR", over1);
        emit log_named_uint("census models with stake >= 100 MOR", over100);
    }
}
