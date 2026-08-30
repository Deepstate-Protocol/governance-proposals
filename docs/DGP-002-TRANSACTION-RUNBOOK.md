# DGP-002 transaction runbook

DGP-002 is valid only after the exact DGP-001 proposal has executed and while its Minter Controller administration
window remains active. Its current fork is a sequential pre-deployment model: it starts from block `50358350`, deploys
the reviewed deterministic contracts locally, executes DGP-001 through the live Governor, and only then executes
DGP-002. Before production submission, replace that model pin with a real archive block mined after the production
DGP-001 execution and rerun the suite without deployment or market-idleness mocks.

## External transaction sequence

1. **Reopen the DGP-001 result.** Confirm DGP-001 is `Executed`, verify the three production deployment receipts and
   code hashes, scan DEEP's complete role history, and run DGP-001's immediate verifier before any later authorized
   issuance changes its exact initial-state assertions.
2. **Run DGP-002's submission gates without broadcasting.** Call `validateSubmissionPreconditions()`. It requires the
   pinned DGP-001 proposal to be executed, the reviewed Controller/Factory/Router authority graph to remain intact,
   controlled minting to remain inside its 730-day term, enough live-supply and permanent gross-issuance headroom for
   `14,285,714.285714285714285713 DEEP`, and enough time for the live voting delay, voting period, maximum late-quorum
   extension, and an execution buffer.
3. **Submit one proposal transaction.** The intended proposer
   `0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2` calls `Governor.propose` with the exact pinned arrays and description.
   All three action values are zero.
4. **Submit vote transactions after the live snapshot.** Each voter calls `castVote(proposalId, 1)`. Query the live
   `proposalDeadline` after voting because late quorum can extend it, then wait for `state(proposalId) == Succeeded`.
5. **Run the execution gates without broadcasting.** Repeat the complete DEEP role-history scan and call
   `validateExecutionPreconditions()`. Confirm the pinned proposal is still `Succeeded`, controlled minting is still
   active, and both caps still have complete issuance headroom.
6. **Execute one atomic Governor transaction.** Any address calls
   `Governor.execute(targets, values, calldatas, keccak256(bytes(description)))`. No ETH is required. Failure of the
   mint or Sablier deposit reverts the entire execution and leaves the proposal `Succeeded`.
7. **Verify the receipt and fresh archive state immediately.** Record the Minter Controller's three
   `MintedWithVesting` events to obtain the transaction-scoped stream IDs, verify every stream field and exact DEEP
   transfer log, then call `verifyExecution()`. Sablier stream IDs are global, so the receipt is definitive if another
   authorized mint occurs before the read-only verifier is run.

The fixed state-changing transaction count is:

```text
2 + voter transactions
```

The fixed `2` is proposal submission plus atomic execution. Any prerequisite STATE delegation is separate.

## The three calls inside the execution transaction

The Governor makes these calls in this exact order:

1. Call `MinterController.mint(0x1fb3A8192d00aDe0ddC0EEcB4D872149Eb9C4157,
   3,333,333.333333333333333334 DEEP)`.
2. Call `MinterController.mint(0x5715d61f99487abD65D1091b5d3a46c1b2879355,
   3,333,333.333333333333333333 DEEP)`.
3. Call `MinterController.mint(0xEb01dF2A97A966f96B1765c78ccD97f3412765F0,
   3,333,333.333333333333333333 DEEP)`.

The three direct primary mints sum to exactly `10,000,000 DEEP`; the first recipient receives the one indivisible
base-unit remainder. Each call separately creates a noncancelable, nontransferable Sablier stream containing
`1,428,571.428571428571428571 DEEP` for the Deepstate Inc Safe, unlocking linearly over exactly 365 days with no cliff
or initial unlock. Because the Controller floors each call's 30/70 calculation independently, the three streams total
`4,285,714.285714285714285713 DEEP`, one DEEP base unit less than a single 10-million-DEEP mint would create.

## Required receipt and state deltas

- DEEP total supply and Minter Controller `grossIssued` each increase by exactly
  `14,285,714.285714285714285713 DEEP`.
- Each volunteer balance increases by its exact allocation, regardless of any pre-existing balance.
- The Governor's DEEP balance after execution equals its pre-execution balance.
- Exactly three controller-created streams each contain `1,428,571.428571428571428571 DEEP`, with the Controller as
  sender, the Deepstate Inc Safe as owner and recipient, DEEP as the asset, a 365-day linear duration, zero cliff,
  one-second granularity, and both cancellation and transfer disabled.
- The Minter Controller finishes with zero DEEP and zero Sablier allowance.
- A replay attempt fails because the Governor proposal is already `Executed`.
