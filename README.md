# PoC — Morpheus SessionRouter: close pays provider full price for zero service

Foundry proof of concept for a Morpheus bug bounty report (LumerinDiamond, Base).

## Finding

In a direct-payment session the provider is paid `price × elapsed` from the
user's escrowed stake on close, and the closeout receipt plays **no role**
in the payment:

1. Provider registers (0.2 MOR minimum stake), posts a max-price bid
   (0.01 MOR/s), renders nothing.
2. Victim opens a direct session (10,000 MOR staked).
3. At session end the victim closes with a valid provider-signed receipt
   reporting **TPS = 0, tokens = 0** → provider is paid the full 29.21 MOR
   (~$20.15); the user loses exactly that amount.
4. Receipt timestamp ignored (close at block +500 with receipt-ts +2500
   pays on block-time elapsed).
5. Receipt **signer not bound to the session provider**: closing provider B's
   session with provider A's signature pays B in full; closing with a
   **complete stranger's** signature also pays in full. Only a malformed
   signature reverts (pay 0).
6. **Close is the user's only exit**: `withdrawUserStakes` without closing
   reverts and recovers 0; sessions never auto-expire.

Target: LumerinDiamond `0x6aBE1d282f72B474E54527D93b979A4f64d3030a` (Base),
SessionRouter facet `0x3a3952F0e57B343F00B31f7da039Ef16389B7260`,
`closeSession`.

## Measured impact (fork, Base block 58,661,283)

- 0.29% of session stake lost per close, unbounded by size: 10,000 MOR
  session → 29.21 MOR (~$20.15); 1,000,000 MOR session → 2,921.59 MOR
  (~$2,015.60). Provider cost: zero.

## How to run

```bash
forge test
```

No setup needed: dependencies are vendored under `lib/`, and the tests fork
Base at block 58,661,283 via the `base` RPC alias (`https://mainnet.base.org`,
public RPC). Expected output: **45 passed, 0 failed**. The 6 close tests
(`WorkerA3/8/9.t.sol`) assert provider pay == full earned on a zero-TPS
receipt, full pay on a stranger-signed receipt, revert on a garbage
signature, and revert on withdraw-without-close; the other 39 tests are
negative proofs showing the surrounding guards hold.

## Note on related work

The public C6 PoC (Yuahaah, Oct 2026) closes a session with a
stranger-signed receipt in stipend mode and asserts the close succeeds, but
measures no provider payment on that close and draws no finding from it.
This finding is the direct-mode payment: the user loses full price × elapsed
for zero attested service. Disclosed so triage can judge grouping on the
facts.

## Fix

Tie the provider payment on close to the receipt's attested service
(TPS = 0 ⇒ pay 0; otherwise pay proportional to attested TPS/tokens),
verify the receipt signer equals the session's provider, and give the user
a close path that refunds the stake without paying for unrendered service.
