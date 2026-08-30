# Rewarder V2 candidate implementation

This document records the implementation relocated from
[`Deepstate-Protocol/deepstate-protocol#18`](https://github.com/Deepstate-Protocol/deepstate-protocol/pull/18). It is
technical review material, not a voter-facing proposal description and not an executable governance payload.

## Provenance

| Item | Pinned revision |
| --- | --- |
| Rewarder V2 source branch | [`codex/rewarder-v2` at `39a336f`](https://github.com/Deepstate-Protocol/deepstate-protocol/tree/39a336f0015d9a5c3f1029cde1191c1789e85587) |
| Protocol base library | `adfd9a8b662d7605c195d249b78e627b3aa87b6a` |
| Matching-engine library | `37aa0d2ecb4a1f37a45b473729c100b2991c4e2d` |
| Sablier Lockup | `lockup@v4.0.1` at `fae38dc7e43c6cab6de8f97124c559f42ed5b77a` |

The source branch is 25 linear commits ahead of its protocol base. Its final delta adds five production contracts,
three interfaces, five behavioral/integration test files, one mock, and dependency/documentation changes. The
first-party Solidity and tests are preserved in this repository. At the time of relocation, pull request 18 remained
open with no recorded review or comments; its required CI checks passed. Pinning that revision records provenance and
does not constitute a security review or audit.

Three production files and four test files rewrite imports of unchanged `DeepstateToken`, `DeepstateRewarder`, and
`IBurnableERC20` through the root-pinned `deepstate-protocol` library. Metadata-free creation and runtime bytecode for
the production contracts matches the pinned branch revision. Full bytecode metadata differs because source paths and
repository layout changed, so deployed code hashes must be generated from this repository's artifacts. The only
non-import source edit removes stale “deterministic” NatSpec left behind when the branch switched factory deployment
from `CREATE2` to `CREATE`; it does not affect runtime behavior.

The Sablier integration suite deploys the real v4.0.1 `SablierLockup` implementation locally with a Comptroller stub.
It proves the expected interface and stream behavior in that harness, but does not validate a Robinhood Chain Lockup
deployment, its actual Comptroller, administrators, trust settings, or protocol fees.

## Components

### DeepstateMinterController

The Governor-owned controller is intended to become DEEP's sole administrator for an initial two-year term. For each
authorized primary mint `M`, it mints `M` to the requested account and
`floor(M * 30 / 70)` to itself for a separate one-year Sablier stream. The configured recipient and Sablier contract
are immutable. Streams are non-cancelable and their NFTs are non-transferable.

The controller enforces an immutable live-supply cap. The branch's intended production value is
`20_000_000_000e18`. Burns reduce live supply and therefore reopen capacity below this controller-level cap. This is
not a hard cap in `DeepstateToken`; a future token-level minter could bypass the policy.

Token administration cannot be returned early after `lockTokenAdministration()` starts the exact `2 * 365 days`
term. At or after the deadline, anyone can trigger return to the controller's current owner. The controller retains
its ordinary token minter role until governance later revokes it.

### DeepstateV1Controller

This Governor-owned wrapper separates delegated pool-hook management from owner-only protocol fee and router ownership
capabilities. A hook manager can configure pool hooks but cannot change fees or transfer the live router.

### DeepstateRewarderFactory

The Governor-owned factory can appoint a revocable operator. The operator or Governor may create or retire markets,
subject to one global three-day deployment cooldown. A caller chooses the ordered token pair, both quantity-ramp
endpoints, and the active reward sides. Factory validation requires an ordered pair, at least one active side, and no
existing hook. The inherited rewarder also requires both quantity schedules—even for an inactive side—to have a
nonzero start and a maximum at least 1,000 times the start. Deployment additionally depends on caller authorization,
the global cooldown, mint-cap headroom, and successful Sablier stream creation. Each market uses these fixed factory
constants:

| Parameter | Value |
| --- | ---: |
| Initial primary funding | `100_000_000e18` DEEP |
| Additional vested allocation | `floor(100_000_000e18 * 30 / 70)` DEEP |
| Per-side emission cap | `500_000_000e18` DEEP |
| Emission duration | `395 days` |
| Vesting duration | `365 days` |

The factory deploys rewarders with `CREATE`, not `CREATE2`. Market removal clears a factory-installed hook and burns
the rewarder's entire live DEEP balance. The separate recipient stream continues vesting. Burning may leave accrued
but unpaid claims unfunded unless governance later restores funding.

### DeepstateRewarderV2

Rewarder V2 inherits the current protocol rewarder and adds an owner-only operation that burns its complete live reward
token balance. The current production Rewarder V1 is unchanged.

## Authority, funding, and lock risks

- An appointed operator can launch a market for any ordered token-address pair with no existing hook, choose its
  quantity ramps and active sides, and retire any factory-created market. The only rate limit is one successful launch
  every three days across the factory. Governance can revoke the operator, but there is no allowlist, per-market
  approval, market-count limit, or aggregate issuance budget below the controller's live-supply cap.
- Every launch mints `100_000_000e18` DEEP to the new rewarder and approximately 42,857,142.857 DEEP into the
  immutable recipient's one-year stream. The rewarder nevertheless schedules as much as `1_000_000_000e18` across
  both sides. It therefore begins 900 million DEEP short of its maximum schedule.
- Fully funding the remaining 900 million DEEP requires a separate transfer from existing supply or new issuance. A
  controller mint for that amount requires the Governor or a separately authorized controller minter and also creates
  approximately 385.714 million DEEP of additional recipient vesting. The factory has no top-up function, and the
  operator cannot mint a top-up unless governance separately grants it controller-level mint authority.
- The Governor, as controller owner, can call `mint` directly without holding the controller's delegated `MINTER_ROLE`.
  It can select any primary recipient and amount, subject to the paired vesting calculation and live-supply cap. The
  factory is therefore not the controller's exclusive issuance path.
- Once activation leaves the minter controller as DEEP's sole default admin, the controller has no generic role-management
  passthrough. DEEP admin changes and revocation of the controller's token-level minter role are effectively unavailable
  during the exact 730-day lock. A bad immutable Sablier endpoint can make every controlled mint revert while no bypass
  minter or accessible token admin remains.
- Retiring a market burns all DEEP still held by its rewarder, including funding needed for accrued but unpaid claims.
  The already-created recipient stream is unaffected. Restoring detached claims would require a later governance mint.

## Candidate activation sequence

The source branch describes this intended sequence, but this repository deliberately does not encode it until all
production inputs and deployed addresses are fixed.

Before proposal submission:

1. Select and verify a compatible Sablier Lockup v4 deployment and its Comptroller on Robinhood Chain, including exact
   runtime code, administrator and upgrade authority, trust configuration, and protocol withdrawal fees.
2. Deploy `DeepstateMinterController(GOVERNOR, DEEP, SABLIER, RECIPIENT, MINT_CAP)`.
3. Deploy `DeepstateV1Controller(GOVERNOR, ROUTER)`.
4. Deploy `DeepstateRewarderFactory(GOVERNOR, V1_CONTROLLER, MINTER_CONTROLLER)`.
5. Verify source, constructor immutables, runtime bytecode, ownership, and deployment provenance for all three.

The atomic governance payload is expected to:

1. grant DEEP's default admin role to the minter controller;
2. call `lockTokenAdministration()`;
3. revoke every token-level minter that could bypass the controller policy;
4. renounce the Governor's DEEP default admin role, leaving the controller as sole admin;
5. grant the factory the minter controller's controller-level `MINTER_ROLE`;
6. transfer the live router to the V1 controller;
7. grant the factory the V1 controller's `HOOK_MANAGER_ROLE`; and
8. optionally set the explicitly approved operator.

An exact DGP test must prove these postconditions, all constructor immutables, the two-year deadline, unchanged router
fees and existing hooks, unchanged DEEP supply, zero new Sablier streams, empty factory market mappings, and
`nextDeploymentAt() == 0`. The factory itself must not receive DEEP's token-level minter role.

## Inputs required before creating a DGP

- DGP number, title, motivation, and intended proposer;
- production Sablier Lockup v4 and Comptroller addresses, runtime code hashes, administrator/upgrade authority,
  trust configuration, protocol withdrawal fees, and compatible-code evidence;
- immutable vesting recipient;
- whether an operator is appointed and its exact address;
- confirmation of the `20_000_000_000e18` live-supply cap;
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
