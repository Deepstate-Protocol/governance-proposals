# Rewarder V2 production deployment

The release deploys `DeepstateMinterController`, `DeepstateV1Controller`, and `DeepstateRewarderFactory` before any
governance proposal activates them. The deployment transaction does not transfer the Router, grant a DEEP role, grant
a controller role, set the Factory operator, mint DEEP, or install a pool hook. Those state changes belong in exact,
fork-tested governance payloads.

## Pinned release policy

These are governance-selected conservative limits, not facts discovered from the live protocol:

- the Minter Controller rejects a mint that would raise live DEEP supply above 20 billion DEEP;
- it also rejects aggregate primary-plus-vesting issuance through the Controller above 20 billion DEEP, and burns do
  not restore that gross allowance; and
- the Factory has a 1.5 billion DEEP lifetime **primary** initial-funding budget. At 150 million primary DEEP per new
  market, that permits exactly ten initial launches. Retiring a market does not restore budget.

Changing any policy constant, constructor, compiler setting, source file, or linked library changes the CREATE2 init
code, address, or both. Regenerate and review the plan after every such change.

## Live trust anchors

The canonical values are in [`DeepstateAddresses.sol`](../src/DeepstateAddresses.sol). The preflight checker pins all
runtime code hashes needed by the deployment, proxy implementations for USDG and the Sablier Comptroller, the NVDA
beacon implementation used by the baseline pool, the 1-of-1 Deepstate Inc Safe, and DEEP's complete role-event history
from its creation block.

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
admin and no address has DEEP's token-level `MINTER_ROLE`. `lockTokenAdministration()` succeeds only after governance
has made the Minter Controller DEEP's **sole** default admin; it then grants the Controller its operational token-level
minter role and starts the exact 730-day clock. No controlled mint can occur before that lock, and minting stops at the
deadline.

For Factory activation, governance must separately:

- give the Factory only the Minter Controller's delegated mint role;
- give it only the V1 Controller's hook-manager role;
- transfer Router ownership to the V1 Controller; and
- set the Deepstate Inc Safe as the revocable Factory operator.

The Factory must never own either Controller or receive DEEP's token-level minter/admin roles. The operator must never
own the Factory or either Controller. Governance retains fee configuration, Controller ownership, Factory ownership,
operator revocation, 850 million DEEP market top-ups, and eventual return of DEEP administration.

Every proposal script must encode and test the exact order of calls. In particular, governance must mint and stream the
initial 300 million DEEP endowment first, while the Governor still administers DEEP; only afterward may it hand sole
administration to the Minter Controller and call `lockTokenAdministration()` to start the 730-day controlled-minting
term. Proposal fork tests should assert every intermediate role count as well as final roles, because a final-state-only
assertion can miss a temporarily over-privileged call order.

## Post-activation verification

Pin a post-activation block and hash, then verify at minimum:

- all three deployed runtime code hashes and immutable constructor values;
- Minter `tokenAdministrationEndsAt`, sole DEEP admin status, token-level minter status, live/gross caps, gross issued,
  exact stream parameters, and zero residual allowance/balance not explained by a stream;
- V1 Controller ownership of the Router with the original fee recipient and 10 bps fee unchanged;
- Factory owner, operator, immutable USDG, 1.5 billion primary budget, zero or expected committed budget, and exact
  delegated roles on both Controllers;
- no unexpected DEEP admin or token-level minter; and
- proposal IDs, description hashes, execution transaction hashes, and all proposal-specific balance/stream outcomes.

Record that new baseline separately. Do not weaken the pre-activation checker to make it pass after governance changes;
the two states prove different security invariants.

## Static-analysis scope

CI pins `slither-analyzer==0.11.6`, filters dependencies, tests, and scripts, and fails High findings in first-party
production source. This is one release gate, not an assertion that Medium or lower findings are clean. Review and record
all remaining findings against [`STATIC_ANALYSIS.md`](STATIC_ANALYSIS.md) during release triage alongside compiler
warnings, test results, and independent audit results.
