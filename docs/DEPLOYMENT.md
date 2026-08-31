# Rewarder V2 production deployment

The release deploys `DeepstateMinterController`, `DGP001Bootstrap`, `DeepstateV1Controller`, and
`DeepstateRewarderFactory` before any governance proposal activates them. The deployment transactions do not transfer
the Router, grant a DEEP role, grant a controller role, set the Factory operator, mint DEEP, or install a pool hook.
Those state changes belong in exact, fork-tested governance payloads.

## Pinned release policy

These are governance-selected conservative limits, not facts discovered from the live protocol:

- the Minter Controller rejects a mint that would raise live DEEP supply above 3 billion DEEP;
- on activation it sets `grossIssued` to the full then-current supply, which includes the one-time Bootstrap endowment,
  and rejects later primary-plus-vesting issuance that would raise that counter above 3 billion DEEP; burns after
  activation do not restore gross allowance, while historical burns before the supply snapshot cannot be reconstructed;
  and
- the Factory has a 1 billion DEEP lifetime **primary** funding budget. Each Rewarder is fully funded with 100 million
  primary DEEP for a 100-million maximum schedule over exactly 365 days, permitting exactly ten markets including the
  migrated NVDA/USDG market. Retiring a market does not restore budget.

Changing any policy constant, constructor, compiler setting, source file, or linked library changes the CREATE2 init
code, address, or both. Regenerate and review the plan after every such change.

## Live trust anchors

The canonical values are in [`DeepstateAddresses.sol`](../script/config/DeepstateAddresses.sol). The preflight checker pins all
runtime code hashes needed by the deployment, proxy implementations for USDG and the Sablier Comptroller, the NVDA
beacon implementation used by the baseline pool, the 1-of-1 Deepstate Inc Safe, and DEEP's complete role-event history
from its creation block. It also requires Sablier Lockup's one-time `nativeToken` not to be DEEP; that configuration
would make future DEEP stream creation revert. The slot is currently unset, while any permanently selected non-DEEP
token would also satisfy this invariant.

Sablier's official Robinhood Lockup v4 is `0x548129a58bC230549DF7F9e33f27E77F6779ff0f`, deployed at block
10,420,411. It is wired to replacement Comptroller proxy `0x12d70713796A9460314C282c613DE307FdED1a36`, version `v1.1`;
the original vanity Comptroller was initialized by an unauthorized account and must not be used. The checker pins the
replacement proxy's current implementation and asserts that the Lockup protocol fee is zero. Authoritative references
are Sablier's [Lockup v4 deployment registry](https://github.com/sablier-labs/sdk/blob/main/src/evm/releases/lockup/v4.0/deployments.ts),
[Comptroller deployment registry](https://github.com/sablier-labs/sdk/blob/main/src/evm/comptroller/deployments.ts), and
[Sablier's incident report for the abandoned vanity proxy](https://github.com/sablier-labs/evm-monorepo/discussions/1528).

The Comptroller and token dependencies are upgradeable external systems. Passing preflight is evidence about one
identified block, not a permanent guarantee; rerun it immediately before deployment, proposal submission, and proposal
execution.

## Preflight

Use a reviewed, clean commit with initialized pinned submodules. An archive-capable RPC is preferred because the role
checker reads logs from DEEP's deployment block.

```bash
export ROBINHOOD_RPC_URL=https://your-reviewed-robinhood-rpc.example
make check
make check-live
```

`make check-live` validates the live registry and exact five-event pre-activation DEEP role history, then executes the
live Sablier compatibility test on a fork. It must remain a pre-activation check: any governance role transition makes
its old role baseline fail by design.

Print the CREATE2 plan without sending a transaction:

```bash
forge script script/DeployRewarderV2System.s.sol:DeployRewarderV2System \
  --sig 'run()' \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  -vvv
```

Compare all four salts, init-code hashes, and predicted addresses with
[`rewarder-v2.template.json`](../deployments/robinhood-4663/rewarder-v2.template.json). Fill its source commit, clean-tree
flag, and preflight snapshot. A source change after this review invalidates the plan.

The manifest also pins the expected post-constructor runtime code hash for each system contract. The guarded deployer
checks those hashes, immutable getters, zero mutable state, and zero premature Factory roles before accepting an
existing deployment; matching getters alone are not sufficient.

Controller-local roles use Solady's non-enumerable address-keyed mapping. Therefore, when either Controller target is
already occupied, runtime/getter checks alone cannot prove that an unknown address has no delegated role. Before an
idempotent retry is accepted for release, independently scan every `RolesUpdated(address,uint256)` event from that
Controller's deployment block through the preflight snapshot and require an empty role inventory. Record the queried
block range and result in the release manifest; an empty target does not need this additional history check.

## Deliberate deployment

The default `run()` entrypoint is read-only. The state-changing entrypoint requires the explicit function selection and
confirmation variable; Foundry still will not submit anything unless `--broadcast` is separately supplied.

First simulate the exact deployment without `--broadcast`:

```bash
DEEPSTATE_CONFIRM_CREATE2_DEPLOYMENT=true \
forge script script/DeployRewarderV2System.s.sol:DeployRewarderV2System \
  --sig 'deploy()' \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --account deepstate-deployer \
  -vvvv
```

Review the simulation, broadcaster, balances, gas, nonce, addresses, and constructor values. Only then repeat the same
command with `--broadcast`. The script calls Arachnid's canonical deterministic deployment proxy at
`0x4e59b44847b379578588920cA78FbF26c0B4956C`; it deploys the Minter Controller, then the Bootstrap, then the V1
Controller, then the Factory. The Bootstrap depends on the already-deployed Minter Controller, and the Factory depends
on both reusable Controllers. The release is idempotent: an exact contract already present at a planned address is
validated and skipped, while incompatible configuration reverts.

No private key, keystore password, or RPC credential belongs in the repository, shell history, manifest, or Foundry
broadcast artifact committed to Git.

## Deployment record and verification

After finality:

1. rerun read-only `run()` and record each nonzero runtime code hash;
2. copy the manifest template to a release file and fill the snapshot, Git commit, broadcaster, transaction hashes,
   blocks, runtime code hashes, and explorer source-verification status;
3. independently recompute each CREATE2 address from deployer, salt, and init-code hash;
4. verify all immutable constructor getters, ownership, zero/unprivileged initial state, and source metadata on the
   explorer; and
5. have a second reviewer reproduce `make check-live`, the plan, receipts, and manifest from the pinned commit.

Do not mark a manifest `deployed` while any transaction, block, runtime hash, or source-verification field is missing.

## Governance activation order and role inventory

Deployment and activation are separate review gates. Immediately before DGP-001, the Governor must be DEEP's sole
default admin and no address may have DEEP's token-level `MINTER_ROLE`. An unexpected token minter is a failed preflight,
not an authority that the fixed DGP-001 payload silently tolerates.

The DGP-001 Governor execution makes exactly ten calls in this order:

1. DEEP grants its token-level `MINTER_ROLE` to `DGP001Bootstrap`.
2. The Bootstrap calls `execute()`: it verifies the pristine Minter configuration and exact installed, idle V1 market,
   snapshots both live `totalAccrued` counters, mints `floor(totalAccrued * 30 / 100)`, creates the complete one-year
   stream, records the result, and renounces its temporary minter role.
3. DEEP grants `DEFAULT_ADMIN_ROLE` to the Minter Controller.
4. The Governor renounces DEEP's `DEFAULT_ADMIN_ROLE`, leaving the Minter Controller as sole token administrator.
5. The Minter Controller calls `activateTokenAdministration()`: it verifies sole administration and that it does not
   already hold DEEP's minter role, self-grants that role, records the full post-Bootstrap DEEP supply as `grossIssued`,
   and starts the exact 730-day clock.
6. The Minter Controller grants the Factory only its Controller-local `MINTER_ROLE`.
7. The Router transfers ownership to the V1 Controller.
8. The V1 Controller grants the Factory only its Controller-local `HOOK_MANAGER_ROLE`.
9. The Factory calls owner-only `migrateMarket` with the exact live V1 Rewarder, reviewed NVDA ramp, and both sides
   active.
10. The Factory sets the Deepstate Inc Safe as its revocable operator.

The Bootstrap is the only contract with one-off legacy-endowment logic. The Minter Controller has no legacy Rewarder
reference or endowment entrypoint; its reusable responsibilities are the 730-day administration term, 30/70 controlled
mints, one-year Inc streams, and the two 3-billion caps. No ordinary controlled mint can occur before activation or at
the deadline. If DEEP administration is transferred to the Controller outside the atomic proposal but activation
cannot complete, the owner-only `returnPreActivationTokenAdministration()` path returns administration and removes any
Controller minter role; it is permanently unavailable after successful activation.

The migration is allowed only when the Router still reports the exact expected predecessor, both sides of the active
book are empty, both legacy Rewarder cursors are zero, and the predecessor identifies the same Router, pool, tokens,
and DEEP reward token. It clears V1, deploys and fully funds V2 with 100 million DEEP, creates the corresponding
`floor(100 million * 30 / 70)` one-year stream, and installs the V2 hook inside one Factory call. Any failed condition,
mint, Sablier interaction, deployment, or hook installation reverts the complete Governor execution.

The Factory must never own either Controller or receive DEEP's token-level minter/admin roles. The operator must never
own the Factory or either Controller. Governance retains fee configuration, Controller ownership, Factory ownership,
owner-only hook migration, operator revocation, and eventual return of DEEP administration. There is no market top-up
function: 100 million DEEP is both the one-time funding and the complete maximum reward schedule.

Every proposal script must encode and test the exact order of calls. DGP-001 combines the dynamic endowment, sole token
administration, controller lock, delegated Factory permissions, Router custody, exact V1-to-V2 migration, and operator
appointment in one atomic Governor execution. Proposal fork tests should assert every intermediate role count as well
as final roles, because a final-state-only assertion can miss a temporarily over-privileged call order.

The expected DGP-001 DEEP role-event sequence is likewise exact: temporary Bootstrap minter grant, Bootstrap
self-renunciation, Minter Controller admin grant, Governor admin renunciation, and Minter Controller minter self-grant,
all in the execution transaction. Post-execution, the Minter Controller is DEEP's sole admin and minter; the Governor,
Bootstrap, Factory, operator, legacy Rewarder, and deployer hold neither DEEP role.

The live V1 Rewarder cannot be retired, swept, or seeded into V2. Emptying both book sides before execution gives it its
final hook callbacks and makes the handoff safe, but its unused DEEP balance remains in that immutable contract and its
already-recorded historical claims remain available. V2 begins a new 100-million schedule; it does not inherit V1's
395-day clock, balances, cursors, or accrual counters.

## Post-activation verification

Pin a post-activation block and hash, then verify at minimum:

- all four deployed runtime code hashes and immutable constructor values;
- Bootstrap snapshot block/time/tokens/accrual, exact endowment and stream, any unsolicited preexisting balance burned
  during execution, `executed` state, role renunciation, and zero residual Sablier allowance; do not use its later
  ERC20 balance as an authority or execution invariant because anyone can transfer dust to it;
- Minter `tokenAdministrationEndsAt`, sole DEEP admin status, token-level minter status, full activation supply
  baseline, live/gross caps, gross issued, exact later stream parameters, and zero residual allowance; an unsolicited
  ERC20 transfer to the Controller does not alter its issuance accounting or streaming behavior;
- V1 Controller ownership of the Router with the original fee recipient and 10 bps fee unchanged;
- Factory owner, operator, immutable USDG, 1 billion primary budget, exactly 100 million committed by the migrated
  first market, its 50-million-per-side caps and 365-day duration, and exact
  delegated roles on both Controllers;
- the exact previous V1 address, idle migration preconditions from the execution block, new V2 hook and side flags,
  unchanged Router fee, and the V1 residual balance and claimability limitation;
- no unexpected DEEP admin or token-level minter; and
- proposal IDs, description hashes, execution transaction hashes, and all proposal-specific balance/stream outcomes.

Record that new baseline separately. Do not weaken the pre-activation checker to make it pass after governance changes;
the two states prove different security invariants.

## Static-analysis scope

CI pins `slither-analyzer==0.11.6`, analyzes first-party production source plus the exact inherited protocol Rewarder
base, filters every other dependency along with tests and scripts, and fails High findings. This is one release gate,
not an assertion that Medium or lower findings are clean. Review and record all remaining findings against
[`STATIC_ANALYSIS.md`](STATIC_ANALYSIS.md) during release triage alongside compiler warnings, test results, and
independent audit results.
