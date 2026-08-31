# DGP-001 transaction runbook

This runbook describes the external transaction sequence after the Minter Controller, one-use DGP-001 Bootstrap, V1
Controller, and Rewarder Factory have been deployed and independently verified. The current proposal ID is a
pre-deployment candidate and must be regenerated after the deployment receipts, post-deployment fork block, and final
Markdown are pinned.

## Transaction boundary

The fixed governance path is one proposal transaction, one transaction from each voter, and one execution transaction.
Claimant registration and order cancellation add a variable number of operational transactions. There is no queue or
timelock transaction.

1. **Run the submission gates without broadcasting.** Scan DEEP's complete `RoleGranted` and `RoleRevoked` history and
   call `validateSubmissionPreconditions()`. These are RPC reads, not transactions. They prove the reviewed deployments,
   dependency identities, pristine Bootstrap, Controller, and Factory state, issuance headroom, Sablier configuration,
   Safe configuration, and current absence of any bypass token-level minter. Market idleness is deliberately not
   required at submission.
2. **Submit one proposal transaction.** The intended proposer
   `0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2` calls `Governor.propose(targets, values, calldatas,
   description)`. The description includes the generated proposer restriction. All ten action values are zero.
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
7. **Execute one atomic Governor transaction.** Any address calls
   `Governor.execute(targets, values, calldatas, keccak256(bytes(description)))`. There is no onchain market pause; if a
   new order appears after step 6, the internal idle checks revert the whole transaction without leaving a partial
   authority transfer or mint.
8. **Verify through a fresh RPC.** Immediately call `verifyExecution()` without broadcasting. This is a read-only check
   of the mined `Executed` state and the exact initial postconditions. Later authorized mints, market launches, claims,
   removals, or operator changes can legitimately make some exact initial-state checks fail.

The state-changing transaction count is therefore:

```text
2 + voter transactions + claimant-registration transactions + cancellation transactions
```

The fixed `2` is the proposal submission and atomic execution. Any prerequisite STATE delegation is separate and is
not included in this count.

## The ten calls inside the execution transaction

The Governor makes these calls in this exact order. If any call fails, EVM transaction atomicity rolls back every
earlier call.

1. DEEP grants its token-level `MINTER_ROLE` to the one-use `DGP001Bootstrap`.
2. The Bootstrap calls `execute()`. It verifies the exact installed and idle V1 market and pristine Minter Controller,
   snapshots both legacy `totalAccrued` counters, mints
   `floor((USDG accrued + NVDA accrued) * 30 / 100)` DEEP into a noncancelable and nontransferable one-year linear
   Sablier stream for the Deepstate Inc Safe, records the snapshot and stream, and renounces its temporary DEEP minter
   role. Its `executed` latch makes the contract permanently one-use.
3. DEEP grants `DEFAULT_ADMIN_ROLE` to the Minter Controller.
4. The Governor renounces its DEEP `DEFAULT_ADMIN_ROLE`, leaving the Minter Controller as sole token administrator.
5. The Minter Controller calls `activateTokenAdministration()`. It verifies sole administration and that it does not
   already hold DEEP's minter role, self-grants that role, records the full post-endowment DEEP supply as its
   `grossIssued` baseline, and starts the exact 730-day administration term. It contains no legacy Rewarder or endowment
   logic.
6. The Minter Controller grants the Factory only its Controller-local `MINTER_ROLE`.
7. The Router transfers ownership to the Governor-owned V1 Controller.
8. The V1 Controller grants the Factory only its Controller-local `HOOK_MANAGER_ROLE`.
9. The Factory calls `migrateMarket` for NVDA with the `1 NVDA` to `5,000 NVDA` quantity range and both buy sides active.
   It verifies and clears the exact legacy hook, deploys Rewarder V2, mints the complete `100,000,000 DEEP` primary
   funding to it, creates the paired `floor(100,000,000 * 30 / 70)` one-year Deepstate Inc stream, and installs V2 as
   both Router hooks. V2 has two `50,000,000 DEEP` side caps over exactly 365 days.
10. The Factory appoints the Deepstate Inc Safe as its revocable operator.

The legacy Rewarder is no longer the Router hook, but it is not destroyed. Its historical registered claims remain
available, while its unused DEEP balance cannot be recovered by this proposal. The Bootstrap burns and records any
DEEP sent to its deterministic address before execution, then remains deployed only as an immutable-configuration and
execution-record contract with no DEEP role or Sablier allowance. Anyone can transfer dust to it later, but that cannot
restore authority or bypass the permanent one-use latch.
