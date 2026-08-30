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

Unchanged `DeepstateToken`, `IOrderBook`, and `IBurnableERC20` dependencies resolve through the root-pinned
`deepstate-protocol` library. The local `src/DeepstateRewarder.sol` is a source-pinned fork of that revision whose
reward calculation and order accounting are unchanged; it adds the terminal lifecycle required for removed V2
rewarders. The Factory also adds a scale-independent quantity-growth ceiling and uses 150 million DEEP of initial
funding. Those deliberate production changes mean Rewarder V2 and Factory bytecode no longer match the original
source branch. Deployed code hashes must be generated from this repository's artifacts.

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
term. Controlled minting is enabled by that activation and is disabled at the exact deadline. At or after the
deadline, anyone can trigger return to the controller's current owner; the return atomically revokes the controller's
token-level minter role before the controller relinquishes token administration.

### DeepstateV1Controller

This Governor-owned wrapper separates delegated pool-hook management from owner-only protocol fee and router ownership
capabilities. A hook manager can configure pool hooks but cannot change fees or transfer the live router.

### DeepstateRewarderFactory

The Governor-owned factory can appoint a revocable operator. The operator or Governor may create markets subject to
one global three-day deployment cooldown and may retire markets without a retirement cooldown. A caller chooses the
ordered token pair, both quantity-ramp endpoints, and the active reward sides. Factory validation requires an ordered pair, at least one active side, and no
existing hook. Both quantity schedules—even for an inactive side—must have a nonzero start and a maximum between
1,000 and 1,000,000 times that start. This ratio bound is scale-independent: the operator can keep the USDG maximum
at 1 million units while selecting a different absolute stock-token maximum for each pool. Deployment additionally
depends on caller authorization, the global cooldown, mint-cap headroom, and successful Sablier stream creation. Each
market uses these fixed factory constants:

| Parameter | Value |
| --- | ---: |
| Initial primary funding | `150_000_000e18` DEEP |
| Additional vested allocation | `floor(150_000_000e18 * 30 / 70)` DEEP |
| Per-side emission cap | `500_000_000e18` DEEP |
| Emission duration | `395 days` |
| Vesting duration | `365 days` |

The factory deploys rewarders with `CREATE`, not `CREATE2`. Market removal clears a factory-installed hook, permanently
retires the rewarder, burns its entire live DEEP balance, and renounces its ownership. A retired rewarder cannot process
hook updates, register claimants, or distribute rewards even if tokens are later transferred to it. The separate
recipient stream continues vesting, while accrued but unpaid claims in the retired rewarder are permanently forfeited.

### DeepstateRewarderV2

Rewarder V2 uses a source-pinned local fork of `DeepstateRewarder` from deepstate-protocol commit
`adfd9a8b662d7605c195d249b78e627b3aa87b6a`. It preserves that reward math and accounting while adding an owner-only,
irreversible retire-and-burn operation and active-state gates around every reward state transition. The current
production Rewarder V1 is unchanged.

## Authority, funding, and lock risks

- An appointed operator can launch a market for any ordered token-address pair with no existing hook, choose its
  quantity ramps and active sides, and retire any factory-created market. The only rate limit is one successful launch
  every three days across the factory. Governance can revoke the operator, but there is no allowlist, per-market
  approval, market-count limit, or aggregate issuance budget below the controller's live-supply cap.
- Every launch mints `150_000_000e18` DEEP to the new rewarder and approximately 64,285,714.286 DEEP into the
  immutable recipient's one-year stream. The rewarder nevertheless schedules as much as `1_000_000_000e18` across
  both sides. It therefore begins 850 million DEEP short of its maximum schedule. At maximum qualifying quantity on
  both sides, the initial funding provides approximately 14.649 days of claim liquidity; it is funding, not an
  accrual cap.
- Fully funding the remaining 850 million DEEP requires a separate transfer from existing supply or new issuance. A
  controller mint for that amount requires the Governor or a separately authorized controller minter and also creates
  approximately 364.286 million DEEP of additional recipient vesting. The factory has no top-up function, and the
  operator cannot mint a top-up unless governance separately grants it controller-level mint authority.
- Factory launches and newly issued top-ups are available only before the minter controller's exact 730-day deadline.
  At and after that deadline every controller mint reverts, so later funding must come from existing DEEP supply.
- The Governor, as controller owner, can call `mint` directly without holding the controller's delegated `MINTER_ROLE`.
  It can select any primary recipient and amount, subject to the paired vesting calculation and live-supply cap. The
  factory is therefore not the controller's exclusive issuance path.
- Once activation leaves the minter controller as DEEP's sole default admin, the controller has no generic role-management
  passthrough. DEEP admin changes and revocation of the controller's token-level minter role are effectively unavailable
  during the exact 730-day lock. A bad immutable Sablier endpoint can make every controlled mint revert while no bypass
  minter or accessible token admin remains.
- Retiring a market burns all DEEP still held by its rewarder, including funding needed for accrued but unpaid claims.
  The already-created recipient stream is unaffected. Retirement is terminal for that Rewarder, so those claims cannot
  be restored; the same pool may be relaunched after the deployment cooldown with a fresh Rewarder, schedule, mint,
  and recipient stream.

## Candidate activation sequence

The three dictated proposals require a staged sequence. This repository deliberately does not encode the executable
payloads until all production inputs and deployed addresses are fixed.

Before proposal submission:

1. Select and verify a compatible Sablier Lockup v4 deployment and its Comptroller on Robinhood Chain, including exact
   runtime code, administrator and upgrade authority, trust configuration, and protocol withdrawal fees.
2. Deploy `DeepstateMinterController(GOVERNOR, DEEP, SABLIER, RECIPIENT, MINT_CAP)`.
3. Deploy `DeepstateV1Controller(GOVERNOR, ROUTER)`.
4. Deploy `DeepstateRewarderFactory(GOVERNOR, V1_CONTROLLER, MINTER_CONTROLLER)`.
5. Verify source, constructor immutables, runtime bytecode, ownership, and deployment provenance for all three.

The first proposal's atomic payload is expected to:

1. temporarily grant the Governor DEEP's token-level `MINTER_ROLE`;
2. mint exactly 300 million DEEP to the Governor and create the specified non-cancelable, non-transferable one-year
   linear Sablier stream for the complete amount, with no cliff or initial unlock;
3. revoke the Governor's temporary token-level minter role;
4. grant DEEP's default admin role to the minter controller and call `lockTokenAdministration()`;
5. revoke every other token-level minter that could bypass the controller policy; and
6. renounce the Governor's DEEP default admin role last, leaving the controller as sole token admin and minter.

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
