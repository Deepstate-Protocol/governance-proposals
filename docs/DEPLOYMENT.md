# Rewarder V2 production deployment

The release deploys `DeepstateMinterController`, `DeepstateV1Controller`, and `DeepstateRewarderFactory` before any
governance proposal activates them. The deployment transaction does not transfer the Router, grant a DEEP role, grant
a controller role, set the Factory operator, mint DEEP, or install a pool hook. Those state changes belong in exact,
fork-tested governance payloads.

## Pinned release policy

These are governance-selected conservative limits, not facts discovered from the live protocol:

- the Minter Controller rejects a mint that would raise live DEEP supply above 3 billion DEEP;
- it also rejects aggregate issuance through the Controller above 3 billion DEEP, including the one-time legacy
  emissions endowment, and burns do
  not restore that gross allowance; and
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

Compare all three salts, init-code hashes, and predicted addresses with
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
`0x4e59b44847b379578588920cA78FbF26c0B4956C`; it deploys Minter, then V1 Controller, then Factory. It is idempotent:
an exact contract already present at a planned address is validated and skipped, while incompatible configuration
reverts.

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

Deployment and activation are separate review gates. Before Minter activation, the Governor is DEEP's sole default
admin and no address has DEEP's token-level `MINTER_ROLE`. Governance must revoke every unexpected token-level minter,
grant DEEP's default-admin role to the Minter Controller, and have the Governor renounce that role.

`lockTokenAdministration()` succeeds only when the Minter Controller is DEEP's **sole** default admin and the exact
legacy market is still installed and idle. In one call it grants itself DEEP's token-level minter role, samples both
live V1 `totalAccrued` counters, mints `floor(totalAccrued * 30 / 100)`, creates the complete one-year stream, and only
then starts the exact 730-day clock. The complete call reverts on any failed identity, idleness, cap, token, or Sablier
condition. No ordinary controlled mint can occur before that lock, and minting stops at the deadline. If governance
transfers DEEP administration but activation cannot complete, the owner-only
`returnPreActivationTokenAdministration()` recovery returns administration to the Governor and removes any controller
minter role; it is permanently unavailable after successful activation.

The same DGP-001 Governor execution must then:

- give the Factory only the Minter Controller's delegated mint role;
- give it only the V1 Controller's hook-manager role;
- transfer Router ownership to the V1 Controller; and
- call the owner-only `migrateMarket` path with the exact live V1 Rewarder, the reviewed NVDA ramp, and both sides
  active; and
- set the Deepstate Inc Safe as the revocable Factory operator.

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

The live V1 Rewarder cannot be retired, swept, or seeded into V2. Emptying both book sides before execution gives it its
final hook callbacks and makes the handoff safe, but its unused DEEP balance remains in that immutable contract and its
already-recorded historical claims remain available. V2 begins a new 100-million schedule; it does not inherit V1's
395-day clock, balances, cursors, or accrual counters.

## Post-activation verification

Pin a post-activation block and hash, then verify at minimum:

- all three deployed runtime code hashes and immutable constructor values;
- Minter `tokenAdministrationEndsAt`, sole DEEP admin status, token-level minter status, live/gross caps, gross issued,
  exact stream parameters, and zero residual allowance/balance not explained by a stream;
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
