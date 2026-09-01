# DGP-001 transaction runbook

This runbook describes the external transaction sequence after the Minter Controller, fixed-amount DGP-001 Bootstrap, V1
Controller, and Rewarder Factory have been deployed and independently verified. The current proposal ID is a
pre-deployment candidate and must be regenerated after the deployment receipts, post-deployment fork block, and final
Markdown are pinned.

## Transaction boundary

The fixed governance path is one proposal transaction, one transaction from each voter, and one execution transaction.
Claimant registration and order cancellation add a variable number of operational transactions. There is no queue or
timelock transaction.

1. **Run the submission gates without broadcasting.** Scan DEEP's complete `RoleGranted` and `RoleRevoked` history and
   call `validateSubmissionPreconditions()`. These are RPC reads, not transactions. They prove the reviewed deployments,
   dependency identities, the Bootstrap's deployment-frozen amount, pristine Controller and Factory state, issuance
   headroom, Sablier configuration, Safe configuration, and current absence of any bypass token-level minter. The
   Bootstrap constructor has already fixed `floor((token0 totalAccrued + token1 totalAccrued) * 30 / 100)`; accrual after
   deployment is intentionally excluded. Market idleness is deliberately not required at submission.
2. **Submit one proposal transaction.** The intended proposer
   `0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2` calls `Governor.propose(targets, values, calldatas,
   description)`. The description includes the generated proposer restriction. All fifteen action values are zero.
3. **Submit vote transactions after the live snapshot.** Each voter calls `castVote(proposalId, 1)` in a separate
   transaction. Wait for `Governor.state(proposalId) == Succeeded` and use the live `proposalDeadline`; late quorum can
   extend the deadline.
4. **Preserve any required V1 claimants.** Before an order is deleted, anyone may call the legacy Rewarder's
   `registerClaimant(bookId, order)`. `registerClaimants(orders)` can batch orders only when they resolve to the same
   claimant. Registration is unnecessary for an order whose historical reward will never be claimed, but omitting it
   makes a later claim impossible once the Router deletes the order owner.
5. **Empty the live NVDA/USDG book.** Each maker calls
   `Router.cancel(USDG, NVDA, epoch, order)` for each resting order it owns, or the orders are fully matched. A keeper can
   register another maker's claimant but cannot cancel that maker's order. The final removal on each side must invoke
   the legacy hook so both Router top-order observations and both Rewarder cursors become zero.
6. **Run the execution gates without broadcasting.** Repeat the exact DEEP role-history scan and call
   `validateActivationPreconditions()`. Confirm the proposal is still `Succeeded`, does not require queuing, both book
   tops are zero, both legacy cursors are zero, and every deployment, dependency, authority, cap, and fee check still
   passes. These are RPC reads, not transactions.
7. **Execute one atomic Governor transaction immediately after the gates.** Any address calls
   `Governor.execute(targets, values, calldatas, keccak256(bytes(description)))`. There is no onchain market pause and
   neither the Bootstrap nor the Governor payload separately rechecks predecessor identity, book tops, Rewarder
   cursors, aggregate issuance headroom, or the complete permission inventory. Those checks are offchain release gates:
   a new order or other state drift after step 6 invalidates the reviewed execution conditions and requires the
   operator to stop and rerun them, even if the payload itself could still execute. The Bootstrap mint does not apply
   the Minter Controller's maximum-supply check; the later Factory-controlled mint does enforce `maxSupply` and reverts
   the complete batch if that mint would exceed it, while role-protected calls fail naturally when their required
   permission is absent.
8. **Verify through a fresh RPC.** Immediately call `verifyExecution()` without broadcasting. This is a read-only check
   of the mined `Executed` state and the exact initial postconditions. Later authorized mints, market launches, claims,
   removals, or operator changes can legitimately make some exact initial-state checks fail.

The state-changing transaction count is therefore:

```text
2 + voter transactions + claimant-registration transactions + cancellation transactions
```

The fixed `2` is the proposal submission and atomic execution. Any prerequisite STATE delegation is separate and is
not included in this count.

## The fifteen calls inside the execution transaction

The Governor makes these calls in this exact order. If any call fails, EVM transaction atomicity rolls back every
earlier call.

1. DEEP explicitly revokes `MINTER_ROLE` from the deployer, the sole historical external minter. The role is already
   revoked in the reviewed live state, so this is an explicit defense-in-depth action.
2. DEEP grants its token-level `MINTER_ROLE` to `DGP001Bootstrap`.
3. The Bootstrap calls `mint()`, which does exactly one thing: mint its fixed deployment-time endowment amount
   directly to the Governor. It performs no Sablier interaction, identity check, idle-state check, cap check, dust burn,
   runtime snapshot, or execution-latch update.
4. DEEP explicitly revokes the Bootstrap's temporary token-level `MINTER_ROLE`. The exhaustive live role history has
   already proved that no pre-existing token-level minter remains. Operational one-use comes from the Governor proposal
   executing once and this immediate revocation; `mint()` could be called again only while the temporary role remained.
5. The Governor approves Sablier to transfer exactly the fixed endowment amount of DEEP.
6. The Governor calls Sablier directly to create the complete one-year linear stream for the Deepstate Inc Safe. The
   Governor is both funder and sender; the stream has no cliff or initial unlock and is neither cancelable nor transferable.
7. DEEP grants `DEFAULT_ADMIN_ROLE` to the Minter Controller.
8. The Governor renounces its DEEP `DEFAULT_ADMIN_ROLE`, leaving the Minter Controller as sole token administrator.
9. The Minter Controller calls `activateTokenAdministration()`. It verifies sole administration and that it does not
   already hold DEEP's minter role, self-grants that role, and starts the exact 730-day administration term. It
   contains no legacy Rewarder, endowment, or issuance-baseline logic.
10. The Minter Controller grants the Factory only its Controller-local `MINTER_ROLE`.
11. The Governor directly clears the legacy NVDA/USDG hook while it still owns the Router. Exact predecessor identity
    and market idleness were checked immediately beforehand as offchain release gates, not by this call or the Bootstrap.
12. The Router transfers ownership to the Governor-owned V1 Controller.
13. The V1 Controller grants the Factory only its Controller-local `HOOK_MANAGER_ROLE`.
14. The Factory calls its ordinary generic `deployMarket` path with canonical `token0 = USDG`, `token1 = NVDA`,
    `token0MaxUnits = 1_000_000`, `token1MaxUnits = 5_000`, and both sides active. It reads both tokens' decimal
    metadata and derives the raw one-unit starts and maxima (`1e6`/`1_000_000e6` for USDG and
    `1e18`/`5_000e18` for NVDA). It deploys Rewarder V2, mints the complete `100,000,000 DEEP` primary funding to it, creates the paired
    `floor(100,000,000 * 30 / 70)` one-year Deepstate Inc stream, and installs V2 as both Router hooks. V2 has two
    `50,000,000 DEEP` side caps over exactly 365 days.
15. The Factory appoints the Deepstate Inc Safe as its revocable operator.

The legacy Rewarder is no longer the Router hook, but it is not destroyed. Its historical registered claims remain
available, while its unused DEEP balance cannot be recovered by this proposal. The Bootstrap never receives the
endowment and has no burn, approval, stream, snapshot, or one-use storage; after call 4 it has no DEEP role. Tokens sent
to it by third parties are unrelated dust and are not cleaned up by DGP-001.
