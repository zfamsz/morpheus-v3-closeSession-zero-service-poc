// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {WorkerA, IDiamond, IMOR, Session} from "./WorkerA.t.sol";

/// Batch 7: BP-006 variants - (a) bid economics/expiry, (b) session-blocks-provider-exit,
/// (c) scale (one provider, N live models).
contract WorkerA7 is WorkerA {
    error ModelHasActiveBids();
    error InsufficientRightsForOperation(address delegator, address delegatee);

    function _openKey(address user_, uint256 amount_, bytes32 bidId_, uint256 signerKey_, bool direct_) internal returns (bytes32) {
        bytes memory approval_ = _approval(bidId_, user_);
        bytes memory sig_ = _sign(signerKey_, approval_);
        vm.prank(user_);
        return IDiamond(DIAMOND).openSession(user_, amount_, direct_, approval_, sig_);
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

    /// BP-006a: bid has no expiry - warp +365d, owner still blocked; bidder can cancel, owner cannot.
    function test_bp006a_bid_no_expiry() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        // owner cannot cancel the provider's bid (control, BP-006)
        (bytes32[] memory active,) = IDiamond(DIAMOND).getModelActiveBids(modelId, 0, 10);
        assertEq(active.length, 1);
        vm.prank(provider);
        vm.expectRevert(ModelHasActiveBids.selector);
        IDiamond(DIAMOND).modelDeregister(modelId);
        // warp 365 days: still blocked (no expiry)
        vm.warp(block.timestamp + 365 days);
        vm.prank(provider);
        vm.expectRevert(ModelHasActiveBids.selector);
        IDiamond(DIAMOND).modelDeregister(modelId);
        (address bp, , , , uint128 createdAt, uint128 deletedAt) = IDiamond(DIAMOND).getBid(bidId);
        emit log_named_uint("bid provider == owner-provider", bp == provider ? 1 : 0);
        emit log_named_uint("bid createdAt", createdAt);
        emit log_named_uint("bid deletedAt (0 = alive)", deletedAt);
        assertEq(deletedAt, 0, "bid never auto-expires");
        emit log_named_uint("live bidFee MOR-wei", IDiamond(DIAMOND).getBidFee());
        emit log_named_uint("live providerMinimumStake MOR-wei", IDiamond(DIAMOND).getProviderMinimumStake());
        emit log_named_uint("live modelMinimumStake MOR-wei", IDiamond(DIAMOND).getModelMinimumStake());
        (uint256 minP, uint256 maxP) = IDiamond(DIAMOND).getMinMaxBidPricePerSecond();
        emit log_named_uint("live minPricePerSecond", minP);
        emit log_named_uint("live maxPricePerSecond", maxP);
    }

    /// BP-006b: does a third-party USER session block the PROVIDER's stake exit?
    /// Matrix: deleteModelBid with active session? providerDeregister with active session?
    /// Who can close the session (user / provider / stranger with valid receipt)?
    function test_bp006b_session_blocks_provider_exit() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        bytes32 sid = _openKey(user, 10_000 ether, bidId, providerKey, false);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        emit log_named_uint("session isActive", s.isActive ? 1 : 0);
        // (1) provider tries to delete its own bid while session active
        vm.prank(provider);
        try IDiamond(DIAMOND).deleteModelBid(bidId) {
            emit log("deleteModelBid with active session: SUCCEEDED");
        } catch {
            emit log("deleteModelBid with active session: REVERTED");
        }
        // (2) provider tries providerDeregister while session active
        vm.prank(provider);
        try IDiamond(DIAMOND).providerDeregister(provider) {
            emit log("providerDeregister with active session: SUCCEEDED");
        } catch {
            emit log("providerDeregister with active session: REVERTED");
        }
        // (3) warp past endsAt: session still active?
        vm.warp(uint256(s.endsAt) + 1);
        emit log_named_uint("session isActive after endsAt", IDiamond(DIAMOND).getSession(sid).isActive ? 1 : 0);
        // (4) who can close it? provider (own-signed receipt)?
        bool okProv = _closeTry(sid, uint128(block.timestamp), 100, 1000, providerKey, provider);
        emit log_named_uint("provider closes own session ok", okProv ? 1 : 0);
        if (!okProv) {
            // stranger with valid provider-signed receipt?
            address stranger = vm.addr(0xBAD);
            bool okStr = _closeTry(sid, uint128(block.timestamp), 100, 1000, providerKey, stranger);
            emit log_named_uint("stranger closes with valid receipt ok", okStr ? 1 : 0);
            if (!okStr) {
                bool okUser = _closeTry(sid, uint128(block.timestamp), 100, 1000, providerKey, user);
                emit log_named_uint("user closes ok", okUser ? 1 : 0);
            }
        }
        modelId;
    }

    /// BP-006b-2: if bid CAN be deleted with an active session, is the session orphaned?
    /// (Runs only if deleteModelBid succeeded above; here tested directly.)
    function test_bp006b_orphan_session() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider(provider, 5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        bytes32 sid = _openKey(user, 10_000 ether, bidId, providerKey, false);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        vm.warp(uint256(s.endsAt) + 1);
        // try delete bid, then deregister model, then claim + close the orphaned session
        vm.prank(provider);
        try IDiamond(DIAMOND).deleteModelBid(bidId) {
            emit log("orphan: bid deleted with active session");
            vm.prank(provider);
            try IDiamond(DIAMOND).modelDeregister(modelId) {
                emit log("orphan: model deregistered with active session");
            } catch {
                emit log("orphan: modelDeregister reverted");
            }
            uint256 provBefore = IMOR(MOR).balanceOf(provider);
            vm.prank(provider);
            try IDiamond(DIAMOND).claimForProvider(sid) {
                emit log_named_uint("orphan: claimForProvider pay", IMOR(MOR).balanceOf(provider) - provBefore);
            } catch {
                emit log("orphan: claimForProvider reverted");
            }
            bool okClose = _closeTry(sid, uint128(block.timestamp), 100, 1000, providerKey, user);
            emit log_named_uint("orphan: closeSession ok", okClose ? 1 : 0);
        } catch {
            emit log("orphan: bid NOT deletable with active session - no orphan path");
        }
    }

    function _modelHead(bytes32 modelId_) internal view returns (bytes32, uint256, uint256, address) {
        (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSelector(0x21e7c498, modelId_));
        require(ok);
        bytes32 cid; uint256 fee; uint256 stake; address owner;
        assembly {
            cid := mload(add(ret, 64))
            fee := mload(add(ret, 96))
            stake := mload(add(ret, 128))
            owner := mload(add(ret, 160))
        }
        return (cid, fee, stake, owner);
    }

    /// BP-006c: scale - one provider registration + N bids on live models; measure fee + blocked stake.
    function test_bp006c_scale_live_models() public {
        (bytes32[] memory ids, uint256 total) = IDiamond(DIAMOND).getActiveModelIds(0, 10);
        emit log_named_uint("live active models total", total);
        assertGt(ids.length, 0);
        uint256 attackerKey = 0xA77A;
        address attacker = vm.addr(attackerKey);
        uint256 providerMin = IDiamond(DIAMOND).getProviderMinimumStake();
        uint256 bidFee = IDiamond(DIAMOND).getBidFee();
        (uint256 minP,) = IDiamond(DIAMOND).getMinMaxBidPricePerSecond();
        deal(MOR, attacker, providerMin + bidFee * ids.length + 1 ether);
        vm.startPrank(attacker);
        IMOR(MOR).approve(DIAMOND, type(uint256).max);
        IDiamond(DIAMOND).providerRegister(attacker, providerMin, "https://attacker.example");
        vm.stopPrank();
        uint256 locked;
        uint256 stakeBehind;
        uint256 spentFees;
        for (uint256 i; i < ids.length; i++) {
            vm.prank(attacker);
            IDiamond(DIAMOND).postModelBid(attacker, ids[i], minP);
            spentFees += bidFee;
            (bytes32[] memory active,) = IDiamond(DIAMOND).getModelActiveBids(ids[i], 0, 30);
            bool mine;
            for (uint256 j; j < active.length; j++) {
                (address p,,,,,) = IDiamond(DIAMOND).getBid(active[j]);
                if (p == attacker) mine = true;
            }
            if (mine) {
                locked++;
                // stake behind this model (raw positional read; flat tuple decode reverts)
                (, , uint256 st, ) = _modelHead(ids[i]);
                stakeBehind += st;
            }
        }
        emit log_named_uint("BP006c models locked by one wallet", locked);
        emit log_named_uint("BP006c escrowed stake behind locks MOR-wei", stakeBehind);
        emit log_named_uint("BP006c sunk bid fees MOR-wei", spentFees);
        emit log_named_uint("BP006c cost per locked model MOR-wei", locked > 0 ? spentFees / locked : 0);
        emit log_named_uint("BP006c extrapolated cost to lock all live models MOR-wei", bidFee * total);
    }
}
