# Rewarder V2 candidate implementation

This document records the implementation relocated from
[`Deepstate-Protocol/deepstate-protocol#18`](https://github.com/Deepstate-Protocol/deepstate-protocol/pull/18). It is
technical review material, not a voter-facing proposal description and not an executable governance payload.

## Provenance

| Item | Pinned revision |
| --- | --- |
| Rewarder V2 source branch | [`codex/rewarder-v2` at `39a336f`](https://github.com/Deepstate-Protocol/deepstate-protocol/tree/39a336f0015d9a5c3f1029cde1191c1789e85587) |
| Protocol base library | [`adfd9a8`](https://github.com/Deepstate-Protocol/deepstate-protocol/tree/adfd9a8b662d7605c195d249b78e627b3aa87b6a) |
| Matching-engine library | `37aa0d2ecb4a1f37a45b473729c100b2991c4e2d` |
| Sablier Lockup | `lockup@v4.0.1` at `fae38dc7e43c6cab6de8f97124c559f42ed5b77a` |

The source branch is 25 linear commits ahead of its protocol base. Its final delta supplied the initial controllers,
Factory, Rewarder V2, interfaces, tests, mock, and dependency/documentation changes that this repository has since
hardened and extended. The first-party Solidity and tests are preserved here. At the time of relocation, pull request 18 remained
open with no recorded review or comments; its required CI checks passed. Pinning that revision records provenance and
does not constitute a security review or audit.

`DeepstateToken`, `IOrderBook`, `IBurnableERC20`, and the Rewarder base resolve through the root-pinned
`deepstate-protocol` library. Rewarder V2 inherits the base reward calculation and order-accounting behavior without a
runtime lifecycle override and adds only an owner-only complete-balance burn. The Factory also adds a
scale-independent quantity-growth ceiling and complete 100-million-DEEP market funding. Those deliberate production
changes mean Rewarder V2 and Factory bytecode no longer match the original source branch. Deployed code hashes must
be generated from this repository's artifacts.

The Sablier integration suite deploys the real v4.0.1 `SablierLockup` implementation locally with a Comptroller stub.
A separate opt-in live fork test creates, vests, withdraws, and checks a non-cancelable/non-transferable stream through
the actual Robinhood Lockup, with the actual Deepstate Inc Safe as recipient. The live checker pins the Lockup, its
replacement Comptroller proxy and implementation, administrator, oracle, and current Lockup withdrawal fee.

## Components

### DGP001Bootstrap

`DGP001Bootstrap` isolates only the irreducible frozen-amount mint from every reusable protocol component. During
construction it reads the supplied legacy Rewarder's token0 and token1 `totalAccrued` counters and stores
`floor((token0Accrued + token1Accrued) * 30 / 100)` as an immutable `uint128`. It retains only immutable Governor, DEEP,
and endowment-amount values; later legacy accrual, including accrual during voting, cannot change the amount.

At runtime `mint()` checks only that its caller is the immutable Governor and asks DEEP to mint the fixed amount
directly to that Governor. It has no Minter Controller, Router, Sablier, recipient, identity, idle-state, cap, dust,
snapshot, event, allowance, stream-ID, or execution-latch logic. DGP-001 temporarily grants the Bootstrap DEEP's
token-level `MINTER_ROLE`, calls `mint()` once, and immediately revokes the role. The proposal's one-time execution plus
that revocation is the operational one-use boundary; another call could mint again only while the role remained.

The Governor then directly approves Sablier for the exact fixed amount and creates the complete one-year linear
Deepstate Inc stream. The Governor is both funder and sender, the Safe is owner and recipient, there is no cliff or
initial unlock, and cancellation and NFT transfer are disabled. Exact predecessor identity, book idleness, legacy
cursor state, cap headroom, permissions, Sablier compatibility, and Safe configuration remain offchain release gates;
neither the Bootstrap nor the ordinary Governor calls separately revalidate those observations. The Bootstrap mint
does not apply the Minter Controller's maximum-supply check, while the later Factory-controlled mint does enforce
`maxSupply` and reverts the atomic batch if that mint would exceed it.

### DeepstateMinterController

The Governor-owned controller is intended to become DEEP's sole administrator for an exact two-year term. Its one-time
owner-only `activateTokenAdministration()` call requires the Controller to be DEEP's sole default administrator and not
already hold DEEP's token-level minter role. It then self-grants that minter role and starts the exact 730-day term.

For each later authorized primary mint `M`, the controller mints `M` to the requested account and
`floor(M * 30 / 70)` to itself for a separate one-year Sablier stream. The configured recipient and Sablier contract
are immutable. Streams are non-cancelable and their NFTs are non-transferable.

The controller enforces one immutable `3_000_000_000e18` `maxSupply`. Before every controlled mint it checks that the
current DEEP total supply plus both the primary and vesting amounts will not exceed that maximum. Burns reduce live
supply and therefore restore minting headroom. This limit is not native to `DeepstateToken`; any separately authorized
token-level minter would bypass it, which is
why activation must leave the Controller as the sole token administrator and token-level minter. The exhaustive live
role-event history identifies the deployer as the sole historical external minter and proves that its role is already
revoked before DGP-001. The proposal explicitly re-revokes that deployer and revokes the only temporary minter it
grants before transferring sole administration to the Controller.

`activateTokenAdministration()` performs only the reusable administration transition; it has
no legacy-market or endowment logic. Ordinary controlled minting is disabled before activation and at the exact deadline.
Administration cannot be returned early; at or after the deadline, anyone can return it to the controller's current
governance owner while atomically revoking the controller's token-level minter role. DGP-001 orders the admin grant,
Governor renunciation, and activation within one atomic Governor execution, so a failed activation rolls back the
entire administration handoff.

### DeepstateV1Controller

This Governor-owned wrapper separates delegated pool-hook management from owner-only protocol fee and router ownership
capabilities. A hook manager can configure pool hooks but cannot change fees or transfer the live router.

### DeepstateRewarderFactory

The Governor-owned factory can appoint a revocable operator. The operator or Governor may create a Rewarder for any
caller-supplied canonical token pair subject to one global three-day cooldown and the Minter Controller's maximum
supply. A launch directly installs the new Rewarder even when another hook is already configured; it
does not modify the prior hook contract or its balance. The Factory has no separate lifetime funding budget,
committed-funding counter, deployment-history mapping, or active Rewarder registry, and it does not pin USDG, sort
tokens, or classify either token as a stock.

`MarketConfig` contains `token0`, `token1`, a whole-unit maximum for each token, and the two Router side flags. The
caller supplies canonical order directly (`token0 < token1`), and the pool ID is
`keccak256(abi.encode(token0, token1))` without a resolution layer. Every side starts at one whole unit. For each
nonzero token, the Factory reads `decimals()` and derives raw quantities as `10 ** decimals` and
`maxUnits * 10 ** decimals`; `address(0)` is the native-asset sentinel and uses an 18-decimal scale without a metadata
call. Every raw quantity must fit the Rewarder's `uint160` fields. The inherited Rewarder enforces the 1,000x minimum,
while the Factory enforces a 1,000,000x maximum independently on both sides.

For example, DGP-001 supplies the reviewed live pair explicitly:

```solidity
MarketConfig({
    token0: USDG,
    token1: NVDA,
    token0MaxUnits: 1_000_000,
    token1MaxUnits: 5_000,
    token0Active: true,
    token1Active: true
})
```

With the reviewed six-decimal USDG and 18-decimal NVDA, the raw ranges are `1e6` through `1_000_000e6` and `1e18`
through `5_000e18`, respectively.

Both supplied sides may be inactive, and the same pair may be launched again after the global cooldown whether its
current hook is zero or nonzero. DGP-001 nevertheless performs its one-time V1 replacement at the Governor batch level:
offchain release gates first verify the exact installed predecessor and idle Router/Rewarder state, the Governor
directly clears that hook, and the Factory's ordinary `deployMarket` path creates, fully funds, and installs V2 later in
the same atomic execution. The direct clear is explicit proposal ordering, not a Factory prerequisite; those identity
and idle observations are not asserted by the payload itself.

`removeMarket(token0, token1)` and `burnBalance(rewarder)` are deliberately separate owner/operator operations.
Removal simply tells the V1 Controller to clear the current hook and side flags for the supplied pair; it neither checks
an expected Rewarder nor burns any balance. The Router is the source of current-hook state. The independent burn path
calls `burnBalance()` on the supplied target and succeeds for a Factory-owned Rewarder; it does not unlink the hook or
record a removed/active mapping. This is an explicitly trusted operator surface: governance revocation, not a Factory
provenance registry, is the control.

The Factory does not inspect either Controller's owner during construction, market operations, or ownership changes.
Authorization is enforced by the Factory's owner/operator gate and by the independent Controller-local roles and
Router custody required by the underlying mint and hook calls; if those permissions are absent, those calls revert.

Ownership and delegated authority are intentionally independent. The three reusable, owner-bearing governance
contracts retain Solady's immediate ownership-transfer path and optional recipient-requested handover path; production
ownership changes are Governor actions reviewed and executed through governance. Neither path implicitly revokes the
Minter Controller's `MINTER_ROLE`, the V1 Controller's `HOOK_MANAGER_ROLE`, or the Factory operator. A governance
ownership change must explicitly inventory those authorities and atomically revoke or reassign any delegate that
should not survive.

| Parameter | Value |
| --- | ---: |
| Complete primary funding | `100_000_000e18` DEEP |
| Additional vested allocation | `floor(100_000_000e18 * 30 / 70)` DEEP |
| Per-side emission cap | `50_000_000e18` DEEP |
| Combined market maximum | `100_000_000e18` DEEP |
| Emission duration | `365 days` |
| Vesting duration | `365 days` |

The factory deploys individual rewarders with `CREATE`; the Minter Controller, fixed-amount Bootstrap, V1 Controller, and
Factory use the existing reviewed deterministic CREATE2 release. Unlinking a Rewarder from the Router stops normal
Router hook callbacks but does not disable inherited permissionless distribution or change its funding. A separate
optional burn leaves the Rewarder owned by the Factory and introduces no retirement state. If its stored cursor still
matches the live order-book top, `distributeRewards` can lazily accrue after unlinking; after a separate balance burn, a
positive distribution reverts atomically until the Rewarder is directly refilled. Its recipient stream continues
vesting independently.

There is no top-up API or reserved later issuance. Each successful deployment emits
`RewarderDeployed(poolId, rewarder, token0, token1, token0Active, token1Active)` and receives the complete 100 million
DEEP that its two 50-million side schedules can ever accrue. `RewarderFunded(poolId, rewarder, rewardAmount)` records
that primary funding; the paired Deepstate Inc stream ID remains in the Minter Controller's `MintedWithVesting` event
rather than being mislabeled as market funding. DGP-001's direct Router clear and ordinary Factory deployment are
observable through the Router configuration events plus `RewarderDeployed` and `RewarderFunded`; there is no Factory
event implying that predecessor balances, claims, cursors, or accounting state moved into V2.

### DeepstateRewarderV2

Rewarder V2 directly inherits `DeepstateRewarder` from the pinned `deepstate-protocol` library and adds one function:
the owner may burn the contract's entire current reward-token balance. Factory-created instances are owned by the
Factory, so only the Factory can invoke that function, either directly through its separate wrapper or after any hook
state. There is no retirement flag, lifecycle gate, or Rewarder-specific event; the current production Rewarder V1 is
unchanged.

## Authority, funding, and lock risks

- An appointed operator can launch any canonical pair, including a pair whose lower token is the zero-address native
  asset, choose both whole-unit maxima and active sides, unlink the current hook for any supplied pair without naming
  an expected Rewarder, and separately request a balance burn from a Factory-owned Rewarder. The Factory reads nonzero
  token decimals to scale quantities but cannot validate metadata truthfulness, token behavior, or economic identity.
  Governance can revoke the operator; launch authority is bounded by the cooldown, per-side growth limits, exact
  730-day mint window, and the Minter Controller's maximum supply. It is deliberately not bounded by current
  hook identity: the operator can replace a governance-installed or previously deployed hook. Unlink and burn authority
  is likewise deliberately trusted.
- Every launch mints exactly `100_000_000e18` DEEP to the new rewarder and
  `42_857_142.857142857142857142` DEEP into the immutable recipient's one-year stream. The two 50-million side caps
  make that funding sufficient for the complete 365-day maximum schedule; there is no top-up path.
- Factory launches are available only before the minter controller's exact 730-day deadline.
  At and after that deadline every controller mint reverts, so later funding must come from existing DEEP supply.
- The Governor, as controller owner, can call `mint` directly without holding the controller's delegated `MINTER_ROLE`.
  It can select any primary recipient and amount, subject to the paired vesting calculation and maximum supply. The
  factory is therefore not the controller's exclusive issuance path.
- Once activation leaves the minter controller as DEEP's sole default admin, it exposes no token role-management
  passthrough. The exhaustive pre-activation role history and explicit Bootstrap revocation are therefore hard safety
  conditions: an external token-level minter missed before activation could not be revoked during the exact 730-day
  lock. A bad immutable Sablier endpoint can make every controlled mint revert while no bypass minter or accessible
  token admin remains.
- Unlinking and burning are independent. Unlinking does not change the Rewarder's DEEP balance; burning can destroy
  funding needed for accrued but unpaid claims without unlinking the hook. Neither operation erases inherited cursor,
  accrual, or claim state or disables permissionless distribution, and the already-created recipient stream is
  unaffected. The same pair may be launched again after the global cooldown if the new issuance fits the Minter
  Controller's remaining maximum-supply headroom; a new launch replaces any hook then installed without changing the old
  hook's state or balance.

## Candidate activation sequence

DGP-001 combines the endowment, controlled-minting activation, delegated Factory authority, and V1-to-V2 replacement
in one atomic Governor execution. DGP-002 remains the separate volunteer allocation and now has its own exact
three-mint payload plus sequential fork suite. The exact DGP-001 payload is now
encoded as a pre-deployment candidate; its submission preflight intentionally rejects missing target deployments,
configuration drift, insufficient cap headroom, or incompatible Sablier state. Market idleness is deliberately checked
immediately before execution so the market does not need to remain unavailable throughout the voting period. These
preflights are offchain release gates and are not assertions executed inside the Governor payload.

Before proposal submission:

1. Select and verify a compatible Sablier Lockup v4 deployment and its Comptroller on Robinhood Chain, including exact
   runtime code, administrator and upgrade authority, trust configuration, and protocol withdrawal fees.
2. Deploy `DeepstateMinterController(GOVERNOR, DEEP, SABLIER, RECIPIENT, MAX_SUPPLY)`.
3. Deploy `DGP001Bootstrap(GOVERNOR, DEEP, LEGACY_REWARDER)`; this transaction fixes
   `floor((token0 totalAccrued + token1 totalAccrued) * 30 / 100)`, so record both counters and the immutable result.
4. Deploy `DeepstateV1Controller(GOVERNOR, ROUTER)`.
5. Deploy `DeepstateRewarderFactory(GOVERNOR, V1_CONTROLLER, MINTER_CONTROLLER)`.
6. Verify source, constructor immutables, runtime bytecode, ownership or Governor binding, pristine mutable state, and
   deployment provenance for all four deterministic contracts.

The first proposal's preparation and activation process is expected to:

1. require users or keepers to have registered any needed V1 claimants and emptied both NVDA/USDG book sides before
   execution, giving V1 its final hook callbacks; these are separate operational transactions, not proposal actions;
2. prove from the complete DEEP role-event history that no bypass token-level minter exists; any unexpected minter is a
   failed precondition that must be remediated before this exact payload is proposed;
3. explicitly re-revoke DEEP's token-level `MINTER_ROLE` from the deployer, grant that role to the Bootstrap, call
   `mint()` once to send its deployment-frozen amount to the Governor, and immediately revoke the temporary role;
4. have the Governor approve Sablier for that exact amount and directly create the one-year Deepstate Inc stream with
   the Governor as funder and sender;
5. grant DEEP's default admin role to the Minter Controller, have the Governor renounce DEEP administration, and call
   `activateTokenAdministration()` so the Controller self-grants its sole token-level minter role and starts the exact
   730-day term;
6. grant the Factory only the Minter Controller's local `MINTER_ROLE`, directly clear the exact V1 Router hook while
   the Governor still owns the Router, transfer the Router to the V1 Controller, and grant the Factory only the V1
   Controller's `HOOK_MANAGER_ROLE`;
7. call the Factory's ordinary `deployMarket` path with canonical `(USDG, NVDA)`, maxima of 1,000,000 and 5,000 whole
   units, and both sides active; the Factory reads both decimal scales and creates and fully funds a
   100-million/365-day V2; and
8. set the approved Deepstate Inc Safe operator last.

Steps 3 through 8 are encoded as fifteen calls in one atomic Governor execution. There is no Router pause, and the
payload does not recheck the book or legacy cursors. A new order or any other drift after the offchain gate requires
stopping and rerunning the checks before broadcasting; it is not safe to assume the transaction will reject that drift.

The second proposal makes three controlled primary mints directly to the exact volunteer recipients. Each mint creates
its own `1_428_571.428571428571428571`-DEEP one-year Deepstate Inc stream; the primary amounts sum to exactly 10 million
DEEP, while independent per-call flooring makes the three streams total `4_285_714.285714285714285713` DEEP.

The first proposal's fork test must prove the deployment-frozen 30% endowment, exact Bootstrap mint, explicit temporary
role revocation, Governor-funded and Governor-sent endowment stream, both exact Sablier streams, the 3-billion maximum supply, exact
730-day deadline, exhaustive sole-admin/minter state, unchanged Router fee, exact V1 predecessor and idle handoff,
100-million V2 balance, 50-million side caps, 365-day duration, Router hook, cooldown deadline, and final operator. The
Bootstrap and Factory must have no DEEP token role after execution; the Factory must never
receive one at any point.

## Inputs required before creating a DGP

- DGP number, title, motivation, and intended proposer;
- production Sablier Lockup v4 and Comptroller addresses, runtime code hashes, administrator/upgrade authority,
  trust configuration, protocol withdrawal fees, and compatible-code evidence;
- immutable vesting recipient;
- whether an operator is appointed and its exact address;
- each pair's canonical token order, two reviewed whole-unit maxima, two side flags, and trustworthy, representable
  `decimals()` metadata for every nonzero token; `address(0)` explicitly means the 18-decimal native asset;
- confirmation of the immutable `3_000_000_000e18` maximum supply and sufficient remaining
  headroom for each planned launch's 100-million primary mint plus its paired Inc stream;
- confirmation or remediation of the Deepstate Inc Safe's current one-owner/one-signature threshold;
- deployed Minter Controller, DGP-001 Bootstrap, V1 Controller, and Factory addresses plus runtime code hashes;
- exhaustive token-level minter inventory proving none remain, with any remediation completed before the payload is
  pinned;
- reviewed archive fork block and block hash;
- a complete list of active V1 orders whose claimants must be registered before cancellation; and
- an execution plan that makes both Router sides and both V1 cursors zero before voting execution.

The live V1 Rewarder has no retirement, sweep, burn, or state-export function. DGP-001 relies on an offchain release gate
for the exact idle state, directly clears the Router hook, and then uses the Factory's ordinary deployment path in the
same atomic Governor batch; V1's unused balance remains trapped, recorded historical claims
remain available, and V2 begins a fresh 100-million schedule without importing V1's balance, clock, cursors, or
accrual.

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
