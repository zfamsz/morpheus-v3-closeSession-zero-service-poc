// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {WorkerA, IDiamond, IMOR, Session} from "./WorkerA.t.sol";

/// Batch 2: duration formula + getter decoding + receipt-field identification.
contract WorkerA2 is WorkerA {
    function _registerProvider2(uint256 provStake_, uint256 modelStake_, bytes32 baseModel_)
        internal returns (bytes32 modelId_, bytes32 bidId_)
    {
        (modelId_, bidId_) = _registerProvider(provider, provStake_, modelStake_, baseModel_);
        _bid = bidId_;
    }

    function test_duration_formula() public {
        _registerProvider2(5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        // 1,000 MOR is below the minimum session size: openSession reverts SessionTooShort().
        bytes memory approval1k = _approval(_bidId(), user);
        bytes memory sig1k = _sign(providerKey, approval1k);
        vm.prank(user);
        vm.expectRevert(bytes4(0xf4d7eed5)); // SessionTooShort()
        IDiamond(DIAMOND).openSession(user, 1_000 ether, true, approval1k, sig1k);
        uint256[4] memory amounts = [uint256(10_000 ether), 50_000 ether, 100_000 ether, 200_000 ether];
        for (uint256 i; i < amounts.length; i++) {
            vm.warp(block.timestamp + 1); // fresh approval timestamp (approvals are single-use by content)
            bytes32 sid = _open(user, user, amounts[i], _bidId());
            Session memory s = IDiamond(DIAMOND).getSession(sid);
            emit log_named_uint("amount MOR-wei", amounts[i]);
            emit log_named_uint("duration s", uint256(s.endsAt) - uint256(s.openedAt));
            emit log_named_uint("implied maxEarn MOR-wei", (uint256(s.endsAt) - uint256(s.openedAt)) * PRICE_MAX);
        }
    }

    bytes32 internal _bid;
    function _bidId() internal returns (bytes32) { return _bid; }

    function test_getters_registered() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider2(5_000 ether, 1 ether, bytes32("base-model"));
        _bid = bidId;
        (bool okP, bytes memory retP) = DIAMOND.staticcall(abi.encodeWithSelector(0x55f21eb7, provider));
        emit log_named_uint("getProvider ok", okP ? 1 : 0);
        emit log_named_bytes("getProvider ret", retP);
        // 0xa9756858(address) -> uint256?
        (bool okA, bytes memory retA) = DIAMOND.staticcall(abi.encodeWithSelector(0xa9756858, provider));
        emit log_named_uint("0xa9756858 ok", okA ? 1 : 0);
        if (okA) emit log_named_uint("0xa9756858 value", abi.decode(retA, (uint256)));
        // 0x673a2a1f(address) -> 704 bytes
        (bool okB, bytes memory retB) = DIAMOND.staticcall(abi.encodeWithSelector(0x673a2a1f, provider));
        emit log_named_uint("0x673a2a1f ok", okB ? 1 : 0);
        emit log_named_uint("0x673a2a1f retlen", retB.length);
        emit log_named_bytes("0x673a2a1f ret head", _head(retB, 256));
        // 0x068bcd8d(address)
        (bool okC, bytes memory retC) = DIAMOND.staticcall(abi.encodeWithSelector(0x068bcd8d, provider));
        emit log_named_uint("0x068bcd8d ok", okC ? 1 : 0);
        emit log_named_uint("0x068bcd8d retlen", retC.length);
        emit log_named_bytes("0x068bcd8d ret", retC);
        modelId;
    }

    function _head(bytes memory b, uint256 n) internal pure returns (bytes memory) {
        if (b.length < n) n = b.length;
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; i++) out[i] = b[i];
        return out;
    }

    // Close with a provider-signed receipt; fields a/b varied. Measure provider pay (direct session)
    // and model-stats delta to identify which uint32 is TPS.
    function _closeReceipt(bytes32 sid_, uint128 ts_, uint32 a_, uint32 b_) internal returns (bytes memory) {
        return abi.encode(sid_, uint256(8453), ts_, a_, b_);
    }

    function test_receipt_fields_direct() public {
        (bytes32 modelId, bytes32 bidId) = _registerProvider2(5_000 ether, 1 ether, bytes32("base-model"));
        _setupActor(user, 500_000 ether);
        (bytes memory statsBefore) = _modelStatsRaw(modelId);
        emit log_named_bytes("modelStats before", statsBefore);

        // direct-payment session, 10k MOR
        bytes memory approval_ = _approval(bidId, user);
        bytes memory sig_ = _sign(providerKey, approval_);
        vm.prank(user);
        bytes32 sid = IDiamond(DIAMOND).openSession(user, 10_000 ether, true, approval_, sig_);
        Session memory s = IDiamond(DIAMOND).getSession(sid);
        emit log_named_uint("direct session duration s", uint256(s.endsAt) - uint256(s.openedAt));
        emit log_named_uint("direct session stake", s.stake);

        // close halfway with receipt a=100, b=1000, ts=now
        vm.warp(uint256(s.openedAt) + 1000);
        bytes memory receipt = _closeReceipt(sid, uint128(block.timestamp), 100, 1000);
        bytes memory rsig = _sign(providerKey, receipt);
        uint256 provBefore = IMOR(MOR).balanceOf(provider);
        uint256 userBefore = IMOR(MOR).balanceOf(user);
        vm.prank(user);
        IDiamond(DIAMOND).closeSession(receipt, rsig);
        Session memory s2 = IDiamond(DIAMOND).getSession(sid);
        emit log_named_uint("closedAt", s2.closedAt);
        emit log_named_uint("providerWithdrawnAmount", s2.providerWithdrawnAmount);
        emit log_named_uint("provider delta on close", IMOR(MOR).balanceOf(provider) - provBefore);
        emit log_named_uint("user delta on close", IMOR(MOR).balanceOf(user) - userBefore);
        emit log_named_uint("closeoutType", s2.closeoutType);
        (bytes memory statsAfter) = _modelStatsRaw(modelId);
        emit log_named_bytes("modelStats after", statsAfter);
        // withdraw user stakes after lock
        vm.warp(block.timestamp + 2 days);
        vm.prank(user);
        IDiamond(DIAMOND).withdrawUserStakes(user, 255);
        emit log_named_uint("user balance after withdraw", IMOR(MOR).balanceOf(user));
        emit log_named_uint("user net vs 500k start", 500_000 ether - IMOR(MOR).balanceOf(user));
    }

    function _modelStatsRaw(bytes32 modelId_) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = DIAMOND.staticcall(abi.encodeWithSelector(0xce535723, modelId_));
        require(ok);
        return ret;
    }
}
