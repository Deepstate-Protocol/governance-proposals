# Rewarder V2 production deployment

The release deploys `DeepstateMinterController`, `DGP001Bootstrap`, `DeepstateV1Controller`, and
`DeepstateRewarderFactory` before any governance proposal activates them. The deployment transactions do not transfer
the Router, grant a DEEP role, grant a controller role, set the Factory operator, mint DEEP, or install a pool hook.
Those state changes belong in exact, fork-tested governance payloads.

`DGP001Bootstrap` fixes the endowment during construction, not during governance execution. Its constructor reads the
legacy Rewarder's token0 and token1 `totalAccrued` counters and stores
`floor((token0 accrued + token1 accrued) * 30 / 100)` as an immutable `uint128`; later accrual, including accrual during
the voting period, is excluded. The deployment receipt and manifest therefore define the economic snapshot and must
record the observed counters and resulting amount.

## Pinned release policy

These are governance-selected conservative limits, not facts discovered from the live protocol:

- the Minter Controller rejects a primary-plus-vesting mint that would raise live DEEP supply above its immutable
  3-billion-DEEP `maxSupply`; burns reduce live supply and therefore restore headroom under that maximum; and
- each Factory launch fully funds one Rewarder with 100 million primary DEEP for a 100-million maximum schedule over
  exactly 365 days. The Factory has no separate funding budget or committed-funding counter: each launch must fit the
  Minter Controller's 3-billion maximum supply, including its paired Inc stream. A launch may
  replace the pair's current Router hook without modifying the old hook contract or its balance, and the same pair can
  be deployed again after the global cooldown; and
- every Rewarder side starts at one whole unit. Each `deployMarket` accepts a caller-canonical token pair and a
  whole-unit maximum for each side, reads `decimals()` for each nonzero token, and treats `address(0)` as an 18-decimal
  native asset. All raw quantities must fit `uint160`, and each side's effective growth range is 1,000x through
  1,000,000x.

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
Controller, then the Factory. The Bootstrap depends directly on the pinned DEEP token and legacy Rewarder, while the
Factory depends on both reusable Controllers. The release is idempotent: an exact contract already present at a planned address is
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
not an authority that the fixed DGP-001 payload silently tolerates. The pinned five-event live history proves that the
deployer's only minter grant was revoked and that no other pre-existing minter grant remains active.

The DGP-001 Governor execution makes exactly fifteen calls in this order:

1. DEEP explicitly revokes `MINTER_ROLE` from the deployer, the sole historical external token-level minter. The
   reviewed live state already has this role revoked, so this is an explicit defense-in-depth action.
2. DEEP grants its token-level `MINTER_ROLE` to `DGP001Bootstrap`.
3. The Bootstrap calls `mint()`, which only mints its fixed deployment-time amount directly to the Governor.
4. DEEP explicitly revokes the Bootstrap's temporary token-level `MINTER_ROLE`; this immediate revocation plus the
   Governor proposal's one-time execution supplies the operational one-use boundary.
5. The Governor approves Sablier for exactly the fixed endowment amount.
6. The Governor calls Sablier directly to create the noncancelable, nontransferable one-year stream for the Deepstate Inc
   Safe, with the Governor as both funder and sender and no cliff or initial unlock.
7. DEEP grants `DEFAULT_ADMIN_ROLE` to the Minter Controller.
8. The Governor renounces DEEP's `DEFAULT_ADMIN_ROLE`, leaving the Minter Controller as sole token administrator.
9. The Minter Controller calls `activateTokenAdministration()`: it verifies sole administration and that it does not
   already hold DEEP's minter role, self-grants that role, and starts the exact 730-day clock.
10. The Minter Controller grants the Factory only its Controller-local `MINTER_ROLE`.
11. The Governor directly clears the legacy hook while it still owns the Router.
12. The Router transfers ownership to the V1 Controller.
13. The V1 Controller grants the Factory only its Controller-local `HOOK_MANAGER_ROLE`.
14. The Factory calls its ordinary generic `deployMarket` path with the canonical `(USDG, NVDA)` pair,
    `token0MaxUnits = 1_000_000`, `token1MaxUnits = 5_000`, and both sides active. It derives raw one-unit starts and
    maxima from USDG's and NVDA's decimal metadata.
15. The Factory sets the Deepstate Inc Safe as its revocable operator.

The Bootstrap's entire runtime responsibility is the one-line frozen-amount mint to the Governor. It has no Sablier,
Minter Controller, Router, recipient, cap, dust, execution-latch, or runtime-snapshot logic; repeated calls are possible
only while it retains DEEP's minter role. The Minter Controller has no legacy Rewarder reference or endowment entrypoint;
its reusable responsibilities are the 730-day administration term, 30/70 controlled mints, one-year Inc streams, and
the immutable 3-billion-DEEP maximum supply. No ordinary controlled mint can occur before activation or at the
deadline. The admin grant, Governor renunciation, and Controller activation are deliberately consecutive actions
inside one atomic Governor execution, so any failed activation rolls back the complete handoff.

Immediately before execution, the release preflight must report the exact expected predecessor, both sides of the active
book empty, both legacy Rewarder cursors zero, and the predecessor bound to the pinned Router, pool, tokens, and DEEP.
These are offchain release gates: neither the Bootstrap nor the Governor payload validates them, so any drift between
the read and the execution requires stopping and rerunning the gate. The later ordinary Factory deployment fully funds
V2 with 100 million DEEP, creates the corresponding `floor(100 million * 30 / 70)` one-year stream, and installs the V2
hook. A reverting direct call, mint, Sablier interaction, deployment, or hook installation still rolls back the complete
Governor execution.

As an unenforced operational policy, the Factory should never own either Controller or receive DEEP's token-level
minter/admin roles, and the operator should never own the Factory or either Controller. Contract ownership and
delegated roles are independent. Governance retains fee configuration, Controller ownership, Factory ownership,
direct hook configuration, operator revocation, and eventual return of DEEP administration. There is no market top-up
function: 100 million DEEP is both the one-time funding and the complete maximum reward schedule. The operator is
deliberately trusted to choose generic canonical pairs, replace or unlink whatever hook is current for a supplied pair,
and invoke the separate balance-burn path; the Factory stores no active-Rewarder or deployment-history mapping and no
expected-Rewarder guard.

Every proposal script must encode and test the exact order of calls. DGP-001 combines the deployment-frozen endowment, sole token
administration, controller lock, delegated Factory permissions, Router custody, exact V1-to-V2 replacement, and operator
appointment in one atomic Governor execution. Proposal fork tests should assert every intermediate role count as well
as final roles, because a final-state-only assertion can miss a temporarily over-privileged call order.

The expected DGP-001 DEEP role-event sequence is likewise exact: the already-revoked deployer action emits no event,
followed by temporary Bootstrap minter grant, proposal-directed Bootstrap minter revocation, Minter Controller admin
grant, Governor admin renunciation, and Minter Controller minter self-grant, all in the execution transaction.
Post-execution, the Minter Controller is DEEP's sole admin and minter; the Governor,
Bootstrap, Factory, operator, legacy Rewarder, and deployer hold neither DEEP role.

The live V1 Rewarder cannot be retired, swept, or seeded into V2. Emptying both book sides before execution gives it its
final hook callbacks and makes the handoff safe, but its unused DEEP balance remains in that immutable contract and its
already-recorded historical claims remain available. V2 begins a new 100-million schedule; it does not inherit V1's
395-day clock, balances, cursors, or accrual counters.

## Post-activation verification

Pin a post-activation block and hash, then verify at minimum:

- all four deployed runtime code hashes and immutable constructor values;
- Bootstrap Governor, DEEP token, constructor-frozen endowment amount, and final role revocation; the helper
  has no execution record, stream ID, allowance, or dust-cleanup state;
- the Governor-funded and Governor-sent endowment stream's exact amount, recipient, one-year duration, zero cliff and
  initial unlock, noncancelable/nontransferable flags, and zero residual Governor-to-Sablier allowance;
- Minter `tokenAdministrationEndsAt`, sole DEEP admin status, token-level minter status, immutable 3-billion-DEEP
  `maxSupply`, exact later stream parameters, and zero residual allowance; an unsolicited ERC20 transfer to the
  Controller does not alter its supply check or streaming behavior;
- V1 Controller ownership of the Router with the original fee recipient and 10 bps fee unchanged;
- Factory owner, operator, Controller dependencies, the replacement first market's exact 100-million primary mint,
  its canonical USDG/NVDA tokens, one-to-1,000,000-whole-USDG and
  one-to-5,000-whole-NVDA ramps, 50-million-per-side caps and 365-day duration, and exact delegated roles on both
  Controllers; the Router hook is the source of the current Rewarder because the Factory stores no active registry;
- the exact previous V1 address, idle replacement preconditions from the execution block, new V2 hook and side flags,
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
