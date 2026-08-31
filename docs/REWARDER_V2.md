# Rewarder V2 candidate implementation

This document records the implementation relocated from
[`Deepstate-Protocol/deepstate-protocol#18`](https://github.com/Deepstate-Protocol/deepstate-protocol/pull/18). It is
technical review material, not a voter-facing proposal description and not an executable governance payload.

## Provenance

| Item | Pinned revision |
| --- | --- |
| Rewarder V2 source branch | [`codex/rewarder-v2` at `39a336f`](https://github.com/Deepstate-Protocol/deepstate-protocol/tree/39a336f0015d9a5c3f1029cde1191c1789e85587) |
| Protocol base library | [`bcad2fc`](https://github.com/Deepstate-Protocol/deepstate-protocol/tree/bcad2fc831f4830255e4cb113c62b1dd4a9aacb6) |
| Matching-engine library | `37aa0d2ecb4a1f37a45b473729c100b2991c4e2d` |
| Sablier Lockup | `lockup@v4.0.1` at `fae38dc7e43c6cab6de8f97124c559f42ed5b77a` |

The source branch is 25 linear commits ahead of its protocol base. Its final delta supplied the initial controllers,
Factory, Rewarder V2, interfaces, tests, mock, and dependency/documentation changes that this repository has since
hardened and extended. The first-party Solidity and tests are preserved here. At the time of relocation, pull request 18 remained
open with no recorded review or comments; its required CI checks passed. Pinning that revision records provenance and
does not constitute a security review or audit.

`DeepstateToken`, `IOrderBook`, `IBurnableERC20`, and the Rewarder base resolve through the root-pinned
`deepstate-protocol` library. Its pinned Rewarder revision adds only a no-op virtual lifecycle hook at the five
state-changing entry points; it does not change the base ABI, storage, reward calculation, or order-accounting
behavior. Rewarder V2 overrides that hook with the terminal lifecycle required for removed markets. The Factory also
adds a scale-independent quantity-growth ceiling, exact guarded legacy-hook migration, and complete 100-million-DEEP
market funding. Those deliberate
production changes mean Rewarder V2 and Factory bytecode no longer match the original source branch. Deployed code
hashes must be generated from this repository's artifacts.

The Sablier integration suite deploys the real v4.0.1 `SablierLockup` implementation locally with a Comptroller stub.
A separate opt-in live fork test creates, vests, withdraws, and checks a non-cancelable/non-transferable stream through
the actual Robinhood Lockup, with the actual Deepstate Inc Safe as recipient. The live checker pins the Lockup, its
replacement Comptroller proxy and implementation, administrator, oracle, and current Lockup withdrawal fee.

## Components

### DGP001Bootstrap

`DGP001Bootstrap` isolates DGP-001's one-time legacy-emissions endowment from every reusable protocol component. It is
deployed with immutable references to the Governor, Minter Controller, and exact live V1 Rewarder; it derives DEEP,
Sablier, and the Deepstate Inc recipient from the reviewed Minter Controller configuration. The permanent Minter
Controller has no legacy Rewarder reference, accrued-emissions snapshot state, or endowment entrypoint.

The Governor must temporarily grant the Bootstrap DEEP's token-level `MINTER_ROLE` and call `execute()` in the same
atomic proposal batch. `execute()` requires the Minter Controller to remain pristine, verifies the installed legacy
Rewarder's Router, pool, sorted tokens, and DEEP reward token, requires both Router book tops and both legacy Rewarder
cursors to be zero, and snapshots both live `totalAccrued` counters. It then mints
`floor((token0Accrued + token1Accrued) * 30 / 100)` DEEP into a complete one-year linear Sablier stream for Deepstate
Inc, with no cliff or initial unlock and with cancellation and NFT transfer disabled.

Because the deterministic address is public before deployment, `execute()` first burns and records any DEEP sent to
that address unsolicited; this prevents even one unit of ERC20 dust from blocking execution or changing the exact
endowment. The Bootstrap records the snapshot, endowment, burned preexisting balance, post-mint supply, and stream ID
and emits one semantic `EndowmentCreated` receipt. It renounces its temporary DEEP minter role before returning and
requires zero residual DEEP balance and Sablier allowance at that point. Its `executed` latch permanently prevents a
second execution; after the successful batch it is an inert audit record with no protocol authority. A later third-
party transfer can change its displayed balance but cannot restore authority or enable another execution.

### DeepstateMinterController

The Governor-owned controller is intended to become DEEP's sole administrator for an exact two-year term. Its one-time
owner-only `activateTokenAdministration()` call requires the Controller to be DEEP's sole default administrator and not
already hold DEEP's token-level minter role. It then self-grants that minter role, records the current full DEEP supply
as `grossIssued`, and starts the exact 730-day term. Because DGP-001 executes the Bootstrap first, this activation
baseline includes all pre-existing live supply and the new endowment before any Factory funding is minted.

For each later authorized primary mint `M`, the controller mints `M` to the requested account and
`floor(M * 30 / 70)` to itself for a separate one-year Sablier stream. The configured recipient and Sablier contract
are immutable. Streams are non-cancelable and their NFTs are non-transferable.

The controller enforces two independent immutable limits. The `3_000_000_000e18` live-supply cap bounds supply after
each mint, while the `3_000_000_000e18` gross-issuance cap counts the full activation-time supply plus every later
primary and vesting token minted through the Controller. Burns after activation reduce live supply but never reduce
`grossIssued`, so retiring and burning Rewarders cannot recycle issuance capacity. The activation baseline is a supply
snapshot rather than a reconstruction of all historical issuance, so tokens burned before activation are not counted.
Neither limit is native to `DeepstateToken`; any separately authorized token-level minter would bypass both, which is
why activation must leave the Controller as the sole token administrator and token-level minter.

While it administers DEEP, governance can call the deliberately one-way
`revokeExternalTokenMinter(address)` recovery path to remove any unexpected token-level minter discovered after
activation. It cannot grant a token role or revoke the controller itself. The exhaustive live role-history preflight
must still prove the expected zero-external-minter baseline before activation.

`activateTokenAdministration()` performs only the reusable administration transition and gross-supply baseline; it has
no legacy-market or endowment logic. Ordinary controlled minting is disabled before activation and at the exact deadline.
Administration cannot be returned early; at or after the deadline, anyone can return it to the controller's current
governance owner while atomically revoking the controller's token-level minter role. If administration was transferred
to the controller but the lock could not complete, the owner-only pre-activation recovery path returns administration
and revokes any controller minter role without starting the term.

### DeepstateV1Controller

This Governor-owned wrapper separates delegated pool-hook management from owner-only protocol fee and router ownership
capabilities. A hook manager can configure pool hooks but cannot change fees or transfer the live router.

### DeepstateRewarderFactory

The Governor-owned factory can appoint a revocable operator. The operator or Governor may create canonical USDG/stock
markets subject to one global three-day cooldown and a monotonic `1_000_000_000e18` primary-funding budget, which
permits exactly ten fully funded markets including the migrated NVDA/USDG market. Every stock must be a deployed
18-decimal token; USDG is pinned to the
live six-decimal contract. The Factory sorts token addresses internally, fixes the USDG full-reward ramp at 1 to
1,000,000 USDG, and permits a pool-specific stock ramp only between 1,000 and 1,000,000 times its nonzero start.
At least one semantic buy side must be active, ordinary operator launches cannot replace an existing Router hook, and
a pool can be deployed only once by this Factory even after retirement. A separate owner-only migration path can
replace one exact predecessor only after verifying its Router/pool/token/reward-token identity, both empty Router book
sides, and both zero predecessor cursors; clearing, deployment, full funding, and installation are atomic.

Factory operations pause whenever the Factory, Minter Controller, and V1 Controller owners are not the same address.
Direct and two-step Factory ownership transfers succeed only after both controllers already share the proposed new
owner, preventing a partially completed governance rotation from leaving the operator active across split authority.

Ownership and delegated authority are intentionally independent. The three reusable, owner-bearing governance
contracts retain Solady's immediate ownership-transfer path and optional recipient-requested handover path; production
ownership changes are Governor actions reviewed and executed through governance. Neither path implicitly revokes the
Minter Controller's `MINTER_ROLE`, the V1 Controller's `HOOK_MANAGER_ROLE`, or the Factory operator. A governance
migration must explicitly inventory those authorities and atomically revoke any delegate that should not survive
before transferring ownership; Factory operations remain paused until all three owners are aligned.

| Parameter | Value |
| --- | ---: |
| Complete primary funding | `100_000_000e18` DEEP |
| Additional vested allocation | `floor(100_000_000e18 * 30 / 70)` DEEP |
| Per-side emission cap | `50_000_000e18` DEEP |
| Combined market maximum | `100_000_000e18` DEEP |
| Emission duration | `365 days` |
| Vesting duration | `365 days` |

The factory deploys individual rewarders with `CREATE`; the Minter Controller, one-use Bootstrap, V1 Controller, and
Factory use a reviewed deterministic CREATE2 release. Market removal is bound to the caller's expected active
Rewarder, clears its hook, permanently retires it, burns its entire live DEEP balance, and renounces ownership before
the token call. A retired Rewarder cannot account, register, or distribute; anyone may burn DEEP sent to it later. Its
separate recipient stream continues vesting, while accrued but unpaid claims are permanently forfeited.

There is no top-up API or reserved later issuance. Each successful deployment emits
`RewarderDeployed(poolId, rewarder, token0, token1, token0Active, token1Active)` and receives the complete 100 million
DEEP that its two 50-million side schedules can ever accrue. `RewarderFunded(poolId, rewarder, rewardAmount)` records
that primary funding; the paired Deepstate Inc stream ID remains in the Minter Controller's `MintedWithVesting` event
rather than being mislabeled as market funding. A replacement additionally emits
`MarketRewarderReplaced(poolId, previousRewarder, newRewarder)`, which reports the exact Router-hook replacement and
does not imply that predecessor balances, claims, cursors, or accounting state moved into V2.

### DeepstateRewarderV2

Rewarder V2 directly inherits `DeepstateRewarder` from the pinned `deepstate-protocol` library. It owns the retirement
state and overrides the base lifecycle hook, preserving the library's reward math and accounting while adding an
owner-only, irreversible retire-and-burn operation and active-state gates around every reward state transition. The
current production Rewarder V1 is unchanged. Retirement and post-retirement cleanup are non-reentrant even if an
independently deployed instance is configured with a callback-capable reward token; production instances use the
pinned DEEP token.

## Authority, funding, and lock risks

- An appointed operator can launch a market for any deployed 18-decimal stock token paired with canonical USDG,
  choose the stock ramp and active sides, and retire an expected active market. Governance can revoke the operator;
  launch authority is bounded by the cooldown, ten-market lifetime budget, permanent one-launch-per-pool rule,
  fixed USDG schedule, stock growth limit, and existing-hook prohibition. This remains a deliberately trusted listing
  role rather than a stock-address allowlist.
- Every launch mints exactly `100_000_000e18` DEEP to the new rewarder and
  `42_857_142.857142857142857142` DEEP into the immutable recipient's one-year stream. The two 50-million side caps
  make that funding sufficient for the complete 365-day maximum schedule; there is no top-up path.
- Factory launches are available only before the minter controller's exact 730-day deadline.
  At and after that deadline every controller mint reverts, so later funding must come from existing DEEP supply.
- The Governor, as controller owner, can call `mint` directly without holding the controller's delegated `MINTER_ROLE`.
  It can select any primary recipient and amount, subject to the paired vesting calculation and live-supply cap. The
  factory is therefore not the controller's exclusive issuance path.
- Once activation leaves the minter controller as DEEP's sole default admin, it exposes no generic role-management
  passthrough or grant path. Governance can revoke an unexpected external token-level minter through the narrow
  recovery function, but DEEP admin changes and revocation of the controller's own token-level minter role remain
  unavailable during the exact 730-day lock. A bad immutable Sablier endpoint can make every controlled mint revert
  while no bypass minter or accessible token admin remains.
- Retiring a market burns all DEEP still held by its Rewarder, including funding needed for accrued but unpaid claims.
  The already-created recipient stream is unaffected. Retirement is terminal for both that Rewarder and the pool's
  Factory lifecycle; neither the burned funding budget nor deployment permission is restored.

## Candidate activation sequence

DGP-001 combines the endowment, controlled-minting activation, delegated Factory authority, and V1-to-V2 replacement
in one atomic Governor execution. DGP-002 remains the separate volunteer allocation and now has its own exact
three-mint payload plus sequential fork suite. The exact DGP-001 payload is now
encoded as a pre-deployment candidate; its submission preflight intentionally rejects missing target deployments,
configuration drift, insufficient cap headroom, or incompatible Sablier state. Market idleness is deliberately checked
immediately before execution so the market does not need to remain unavailable throughout the voting period.

Before proposal submission:

1. Select and verify a compatible Sablier Lockup v4 deployment and its Comptroller on Robinhood Chain, including exact
   runtime code, administrator and upgrade authority, trust configuration, and protocol withdrawal fees.
2. Deploy `DeepstateMinterController(GOVERNOR, DEEP, SABLIER, RECIPIENT, LIVE_CAP, GROSS_CAP)`.
3. Deploy `DGP001Bootstrap(GOVERNOR, MINTER_CONTROLLER, LEGACY_REWARDER)`.
4. Deploy `DeepstateV1Controller(GOVERNOR, ROUTER)`.
5. Deploy `DeepstateRewarderFactory(GOVERNOR, V1_CONTROLLER, MINTER_CONTROLLER, USDG, FUNDING_BUDGET)`.
6. Verify source, constructor immutables, runtime bytecode, ownership or Governor binding, pristine mutable state, and
   deployment provenance for all four deterministic contracts.

The first proposal's preparation and activation process is expected to:

1. require users or keepers to have registered any needed V1 claimants and emptied both NVDA/USDG book sides before
   execution, giving V1 its final hook callbacks; these are separate operational transactions, not proposal actions;
2. prove from the complete DEEP role-event history that no bypass token-level minter exists; any unexpected minter is a
   failed precondition that must be remediated before this exact payload is proposed;
3. grant DEEP's token-level `MINTER_ROLE` to the one-use Bootstrap and call `execute()`, which validates the exact idle
   V1 market, creates the execution-time accrued-emissions endowment, and renounces that temporary role;
4. grant DEEP's default admin role to the Minter Controller, have the Governor renounce DEEP administration, and call
   `activateTokenAdministration()` so the Controller self-grants its sole token-level minter role, baselines
   `grossIssued` to the full post-endowment supply, and starts the exact 730-day term;
5. grant the Factory only the Minter Controller's local `MINTER_ROLE`, transfer the Router to the V1 Controller, and
   grant the Factory only the V1 Controller's `HOOK_MANAGER_ROLE`;
6. call the Factory's owner-only migration with the exact V1 predecessor, reviewed NVDA quantity range, and both sides
   active, atomically creating and fully funding a 100-million/365-day V2; and
7. set the approved Deepstate Inc Safe operator last.

Steps 3 through 7 are encoded as ten calls in one atomic Governor execution. There is no Router pause, so a new
order between cleanup and execution makes the execution revert safely; the book and legacy-cursor checks must be
reopened immediately before broadcasting.

The second proposal makes three controlled primary mints directly to the exact volunteer recipients. Each mint creates
its own `1_428_571.428571428571428571`-DEEP one-year Deepstate Inc stream; the primary amounts sum to exactly 10 million
DEEP, while independent per-call flooring makes the three streams total `4_285_714.285714285714285713` DEEP.

The first proposal's fork test must prove the execution-time accrual snapshot and 30% endowment, Bootstrap role
renunciation and one-use state, both exact Sablier streams, the post-endowment gross baseline, 3-billion caps, exact
730-day deadline, exhaustive sole-admin/minter state, unchanged Router fee, exact V1 predecessor and idle handoff,
100-million V2 balance, 50-million side caps, 365-day duration, Factory mappings/budget, and final operator. The
Bootstrap and Factory must have no DEEP token role after execution; the Factory must never receive one at any point.

## Inputs required before creating a DGP

- DGP number, title, motivation, and intended proposer;
- production Sablier Lockup v4 and Comptroller addresses, runtime code hashes, administrator/upgrade authority,
  trust configuration, protocol withdrawal fees, and compatible-code evidence;
- immutable vesting recipient;
- whether an operator is appointed and its exact address;
- confirmation of the separate `3_000_000_000e18` live-supply and gross-issuance caps and the ten-market
  `1_000_000_000e18` primary-funding budget;
- confirmation or remediation of the Deepstate Inc Safe's current one-owner/one-signature threshold;
- deployed Minter Controller, DGP-001 Bootstrap, V1 Controller, and Factory addresses plus runtime code hashes;
- exhaustive token-level minter inventory proving none remain, with any remediation completed before the payload is
  pinned;
- reviewed archive fork block and block hash;
- a complete list of active V1 orders whose claimants must be registered before cancellation; and
- an execution plan that makes both Router sides and both V1 cursors zero before voting execution.

The live V1 Rewarder has no retirement, sweep, burn, or state-export function. The Factory can replace it only as the
active Router hook after the idle-state checks; V1's unused balance remains trapped, recorded historical claims remain
available, and V2 begins a fresh 100-million schedule without importing V1's balance, clock, cursors, or accrual.

## Live-check phase transition

`make check-live` currently defines the pre-activation production baseline. It pins the critical live runtime code
hashes and requires the Governor to own the Router and remain DEEP's sole default admin; it also verifies the current
10-bps STATE fee and NVDA/USDG Rewarder V1 hook. Rewarder V2 activation intentionally invalidates the ownership and
administration assertions.

The concrete DGP must therefore introduce explicit pre/post-activation modes or update the registry and checker after
execution. Use the pre-activation mode immediately before submission, prove the transition on a pinned fork, and run
the DGP's `verifyExecution()` against fresh live state after the mined execution receipt. Before any later DGP is
reviewed, record all four deterministic addresses and local-artifact runtime code hashes and promote the confirmed
post-activation roles, ownership, fees, and hooks to the live baseline.
