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

The source branch is 25 linear commits ahead of its protocol base. Its final delta adds five production contracts,
three interfaces, five behavioral/integration test files, one mock, and dependency/documentation changes. The
first-party Solidity and tests are preserved in this repository. At the time of relocation, pull request 18 remained
open with no recorded review or comments; its required CI checks passed. Pinning that revision records provenance and
does not constitute a security review or audit.

`DeepstateToken`, `IOrderBook`, `IBurnableERC20`, and the Rewarder base resolve through the root-pinned
`deepstate-protocol` library. Its pinned Rewarder revision adds only a no-op virtual lifecycle hook at the five
state-changing entry points; it does not change the base ABI, storage, reward calculation, or order-accounting
behavior. Rewarder V2 overrides that hook with the terminal lifecycle required for removed markets. The Factory also
adds a scale-independent quantity-growth ceiling and uses 150 million DEEP of initial funding. Those deliberate
production changes mean Rewarder V2 and Factory bytecode no longer match the original source branch. Deployed code
hashes must be generated from this repository's artifacts.

The Sablier integration suite deploys the real v4.0.1 `SablierLockup` implementation locally with a Comptroller stub.
A separate opt-in live fork test creates, vests, withdraws, and checks a non-cancelable/non-transferable stream through
the actual Robinhood Lockup, with the actual Deepstate Inc Safe as recipient. The live checker pins the Lockup, its
replacement Comptroller proxy and implementation, administrator, oracle, and current Lockup withdrawal fee.

## Components

### DeepstateMinterController

The Governor-owned controller is intended to become DEEP's sole administrator for an initial two-year term. For each
authorized primary mint `M`, it mints `M` to the requested account and
`floor(M * 30 / 70)` to itself for a separate one-year Sablier stream. The configured recipient and Sablier contract
are immutable. Streams are non-cancelable and their NFTs are non-transferable.

The controller enforces two independent immutable limits. The `20_000_000_000e18` live-supply cap bounds supply after
each mint, while the `20_000_000_000e18` gross-issuance cap permanently counts every primary and vesting token minted
through the controller. Burns reduce live supply but never reduce gross issuance, so retiring and burning Rewarders
cannot recycle issuance capacity. Neither limit is native to `DeepstateToken`; any separately authorized token-level
minter would bypass both, which is why activation must leave the controller as the sole token administrator and
token-level minter.

While it administers DEEP, governance can call the deliberately one-way
`revokeExternalTokenMinter(address)` recovery path to remove any unexpected token-level minter discovered after
activation. It cannot grant a token role or revoke the controller itself. The exhaustive live role-history preflight
must still prove the expected zero-external-minter baseline before activation.

`lockTokenAdministration()` requires the controller already to be DEEP's only default administrator, then starts the
exact `2 * 365 days` term and grants the controller its token-level minter role. Controlled minting is disabled before
activation and at the exact deadline. Administration cannot be returned early; at or after the deadline, anyone can
return it to the controller's current governance owner while atomically revoking the controller's token-level minter
role.

### DeepstateV1Controller

This Governor-owned wrapper separates delegated pool-hook management from owner-only protocol fee and router ownership
capabilities. A hook manager can configure pool hooks but cannot change fees or transfer the live router.

### DeepstateRewarderFactory

The Governor-owned factory can appoint a revocable operator. The operator or Governor may create canonical USDG/stock
markets subject to one global three-day cooldown and a monotonic `1_500_000_000e18` initial-primary-funding budget,
which permits exactly ten successful launches. Every stock must be a deployed 18-decimal token; USDG is pinned to the
live six-decimal contract. The Factory sorts token addresses internally, fixes the USDG full-reward ramp at 1 to
1,000,000 USDG, and permits a pool-specific stock ramp only between 1,000 and 1,000,000 times its nonzero start.
At least one semantic buy side must be active, an existing Router hook can never be replaced, and a pool can be
deployed only once by this Factory even after retirement.

Factory operations pause whenever the Factory, Minter Controller, and V1 Controller owners are not the same address.
Direct and two-step Factory ownership transfers succeed only after both controllers already share the proposed new
owner, preventing a partially completed governance rotation from leaving the operator active across split authority.

| Parameter | Value |
| --- | ---: |
| Initial primary funding | `150_000_000e18` DEEP |
| Additional vested allocation | `floor(150_000_000e18 * 30 / 70)` DEEP |
| Per-side emission cap | `500_000_000e18` DEEP |
| Emission duration | `395 days` |
| Vesting duration | `365 days` |

The factory deploys individual rewarders with `CREATE`; the three system contracts themselves use a reviewed
deterministic CREATE2 release. Market removal is bound to the caller's expected active Rewarder, clears its hook,
permanently retires it, burns its entire live DEEP balance, and renounces ownership before the token call. A retired
Rewarder cannot account, register, or distribute; anyone may burn DEEP sent to it later. Its separate recipient stream
continues vesting, while accrued but unpaid claims are permanently forfeited.

Governance alone can call the Factory's expected-rewarder-checked top-up. It verifies that the Rewarder is active,
factory-created, not retired, still installed as the Router hook, and not previously topped up before issuing exactly
`850_000_000e18` additional primary DEEP. The associated stream ID and both the initial and top-up amounts are emitted
for receipt verification.

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
- Every launch mints `150_000_000e18` DEEP to the new rewarder and approximately 64,285,714.286 DEEP into the
  immutable recipient's one-year stream. The rewarder nevertheless schedules as much as `1_000_000_000e18` across
  both sides. It therefore begins 850 million DEEP short of its maximum schedule. At maximum qualifying quantity on
  both sides, the initial funding provides approximately 14.649 days of claim liquidity; it is funding, not an
  accrual cap.
- Fully funding the remaining 850 million DEEP requires governance to call the Factory's exact active-market top-up
  or transfer existing supply. A controller-funded top-up also creates approximately 364.286 million DEEP of recipient
  vesting. The operator cannot call this function, redirect it, replay it, or top up a retired/replaced hook.
- Factory launches and newly issued top-ups are available only before the minter controller's exact 730-day deadline.
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

The three dictated proposals require a staged sequence. This repository deliberately does not encode the executable
payloads until all production inputs and deployed addresses are fixed.

Before proposal submission:

1. Select and verify a compatible Sablier Lockup v4 deployment and its Comptroller on Robinhood Chain, including exact
   runtime code, administrator and upgrade authority, trust configuration, and protocol withdrawal fees.
2. Deploy `DeepstateMinterController(GOVERNOR, DEEP, SABLIER, RECIPIENT, LIVE_CAP, GROSS_CAP)`.
3. Deploy `DeepstateV1Controller(GOVERNOR, ROUTER)`.
4. Deploy `DeepstateRewarderFactory(GOVERNOR, V1_CONTROLLER, MINTER_CONTROLLER, USDG, INITIAL_FUNDING_BUDGET)`.
5. Verify source, constructor immutables, runtime bytecode, ownership, and deployment provenance for all three.

The first proposal's atomic payload is expected to:

1. temporarily grant the Governor DEEP's token-level `MINTER_ROLE`;
2. mint exactly 300 million DEEP to the Governor and create the specified non-cancelable, non-transferable one-year
   linear Sablier stream for the complete amount, with no cliff or initial unlock;
3. revoke the Governor's temporary token-level minter role;
4. grant DEEP's default admin role to the minter controller;
5. revoke every other token-level minter that could bypass the controller policy;
6. have the Governor renounce DEEP administration, leaving the controller as the sole default admin; and
7. call `lockTokenAdministration()` last to start the 730-day clock and grant the controller's token-level minter role.

The second proposal is expected to make one controlled 10-million-DEEP primary mint to the Governor, creating the
corresponding Deepstate Inc stream, and then transfer the exact three volunteer allocations from the Governor.

The third proposal's atomic payload is expected to:

1. grant the factory the minter controller's controller-level `MINTER_ROLE`;
2. transfer the live router to the V1 controller;
3. grant the factory the V1 controller's `HOOK_MANAGER_ROLE`; and
4. set the explicitly approved operator.

The first proposal's fork test must prove the 300-million-DEEP supply increase, exact Sablier stream, constructor
immutables, exact 730-day deadline, exhaustive sole-admin/minter state, and unchanged Router configuration. The third
proposal's fork test must prove unchanged supply and stream count during permission activation, unchanged fees and
existing hooks, empty factory market mappings, and `nextDeploymentAt() == 0`. The factory itself must never receive
DEEP's token-level minter role.

## Inputs required before creating a DGP

- DGP number, title, motivation, and intended proposer;
- production Sablier Lockup v4 and Comptroller addresses, runtime code hashes, administrator/upgrade authority,
  trust configuration, protocol withdrawal fees, and compatible-code evidence;
- immutable vesting recipient;
- whether an operator is appointed and its exact address;
- confirmation of the separate `20_000_000_000e18` live-supply and gross-issuance caps and the ten-market
  `1_500_000_000e18` initial-primary-funding budget;
- confirmation or remediation of the Deepstate Inc Safe's current one-owner/one-signature threshold;
- deployed minter controller, V1 controller, and factory addresses plus runtime code hashes;
- exhaustive token-level minter inventory and the exact set to revoke;
- reviewed archive fork block and block hash; and
- an explicit decision on whether a separate action will migrate the current NVDA/USDG Rewarder V1.

The factory rejects a new market when the pool already has a hook and can remove only rewarders that it created. The
candidate activation therefore does not replace or migrate the current NVDA/USDG rewarder by itself.

## Live-check phase transition

`make check-live` currently defines the pre-activation production baseline. It pins the critical live runtime code
hashes and requires the Governor to own the Router and remain DEEP's sole default admin; it also verifies the current
10-bps STATE fee and NVDA/USDG Rewarder V1 hook. Rewarder V2 activation intentionally invalidates the ownership and
administration assertions.

The concrete DGP must therefore introduce explicit pre/post-activation modes or update the registry and checker after
execution. Use the pre-activation mode immediately before submission, prove the transition on a pinned fork, and run
the DGP's `verifyExecution()` against fresh live state after the mined execution receipt. Before any later DGP is
reviewed, record the controller/factory addresses and local-artifact runtime code hashes and promote the confirmed
post-activation roles, ownership, fees, and hooks to the live baseline.
