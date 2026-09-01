# Deepstate governance proposals

Foundry project for authoring, reviewing, simulating, and submitting proposals to the live Deepstate Governor. The
repository contains the hardened Rewarder V2 release candidate and deterministic deployment tooling, but no
submission-ready governance proposal yet. DGP-001 now has an exact executable payload candidate and proposal-specific
tests; it remains blocked from submission until the system contracts are deployed, receipts are recorded, the live
market is prepared, and the final archive-fork lifecycle test passes. DGP-002 now has an exact three-mint payload and
sequential fork suite, but must be repinned to a real production block after DGP-001 executes.

The project follows the Solidity and deployment conventions in
[`deepstate-contracts`](https://github.com/Deepstate-Protocol/deepstate-contracts) and
[`deepstate-protocol`](https://github.com/Deepstate-Protocol/deepstate-protocol): Solidity `0.8.28`, Cancun EVM,
optimized via-IR builds, pinned Foundry dependencies, type-safe calldata, proposal-specific scripts, and tests.

## Rewarder V2 candidate

The 25-commit implementation delta from `deepstate-protocol@codex/rewarder-v2` was relocated here at
[pinned source revision `39a336f`](https://github.com/Deepstate-Protocol/deepstate-protocol/tree/39a336f0015d9a5c3f1029cde1191c1789e85587).
Its production contracts, supporting interfaces, behavioral tests, Sablier v4.0.1 implementation test, and mock are
first-party files in `src/` and `test/`. In addition to the local implementation test, `make check-live` exercises the
actual Robinhood Lockup and Deepstate Inc Safe on a fork. Unchanged protocol and matching-engine contracts remain
pinned libraries. Rewarder V2 directly inherits the Rewarder base from the pinned `deepstate-protocol` library and
adds only an owner-only function that burns the contract's complete reward-token balance. The protocol's reward math
and accounting remain inherited rather than copied into this repository.

The system contracts have not been deployed. The repository includes a read-only deterministic CREATE2 plan, release
manifest template, pinned live dependencies, a live Sablier compatibility test, and DGP-001's exact fifteen-action
Governor payload with a provisional pre-deployment ID. The payload is deliberately not submission-ready until its
predicted targets are actual reviewed deployments and the final archive-fork release gates pass. See
[`docs/REWARDER_V2.md`](docs/REWARDER_V2.md) for the authority model and [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for
the production release procedure. The proposal-specific external transaction sequences are recorded in
[`docs/DGP-001-TRANSACTION-RUNBOOK.md`](docs/DGP-001-TRANSACTION-RUNBOOK.md) and
[`docs/DGP-002-TRANSACTION-RUNBOOK.md`](docs/DGP-002-TRANSACTION-RUNBOOK.md).

The current release policy caps live DEEP supply at 3 billion DEEP. When the DGP-001
Bootstrap is deployed, its constructor freezes `floor((token0 totalAccrued + token1 totalAccrued) * 30 / 100)` from the
legacy Rewarder; later accrual, including accrual during voting, is not included. DGP-001 atomically gives that contract
temporary mint authority, calls its minimal `mint()` to send the fixed amount to the Governor, revokes the authority,
and has the Governor directly approve Sablier and create the one-year endowment stream as both funder and sender. The
Bootstrap performs no runtime identity, idleness, cap, dust, snapshot, or one-use validation; those release conditions
remain offchain gates, while operational one-use comes from proposal execution plus immediate role revocation. The
same batch activates the exact 730-day mint policy and replaces the operationally prepared NVDA/USDG V1 hook with a fully funded Rewarder V2
capped at 100 million DEEP over exactly 365 days. Factory markets use two 50-million side caps and a global three-day
cooldown; each launch mints exactly 100 million primary DEEP, with the Minter Controller's 3-billion maximum supply
providing the issuance bound instead of a separate Factory budget. Burns reduce live supply and therefore restore
headroom under that maximum. There is no later market top-up path. Factory callers supply an already-canonical
`token0`/`token1` pair, a whole-token maximum and activation flag for
each side, and every reward side starts at one whole unit. The Factory reads `decimals()` for each nonzero token and
treats `address(0)` as an 18-decimal native asset. A launch may directly replace whatever Router hook is currently
installed for the pair, leaving the previous hook contract and its token balance untouched, and the same pair may be
launched again after the cooldown. Unlinking a Router hook and optionally burning a Factory-owned Rewarder's balance
are separate operator actions; the Factory stores neither an active-Rewarder registry nor a launch-history mapping.

## Live target

| Field | Value |
| --- | --- |
| Network | Robinhood Chain |
| Chain ID | `4663` |
| Governor | [`0x3DC3…111Ff`](https://robinhoodchain.blockscout.com/address/0x3DC3b787EBDC78bf916f4e30195C61c764C111Ff) |
| STATE voting token | [`0xbfb7…273D5`](https://robinhoodchain.blockscout.com/address/0xbfb7b3Ff3D498a559b946B836d26F0E168f273D5) |
| Immutable governance start | `2026-08-30T07:23:58Z` (`1788074638`) |
| Public RPC | `https://rpc.mainnet.chain.robinhood.com/` |
| Explorer | [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com/) |

The full documented deployment is recorded in [`DeepstateAddresses.sol`](script/config/DeepstateAddresses.sol). The address
source is the [Deepstate documentation](https://deepstate.sh/docs), specifically its
[Network & Addresses](https://docs-production-cdea.up.railway.app/contracts/deployments/) page, which says the
production addresses were recorded on August 16, 2026. Run `make check-live` before authoring or
submitting a proposal. The current check is specifically the Rewarder V2 **pre-activation** baseline: at one snapshot
block it verifies exact runtime/proxy implementation hashes, the replacement Sablier Comptroller and fee state, the
Deepstate Inc Safe's sole owner/threshold/module state, proposer votes, token decimals, Governor identity and mode,
current ownership, the 10-bps STATE fee, the NVDA/USDG Rewarder V1 hook, and DEEP's exhaustive five-event role history
from its pinned deployment block through the snapshot.

Rewarder V2 activation intentionally changes Router ownership and DEEP administration, so this pre-activation check
must fail after execution. A concrete DGP must add explicit pre/post-activation checks or replace the baseline after a
confirmed execution: run the pre-activation mode before submission, run the proposal's `verifyExecution()` against
the mined receipt, and make the post-activation state the baseline before reviewing any later DGP.

The official RPC is rate-limited and pruned. Set `ROBINHOOD_RPC_URL` to an archive-capable Robinhood Chain endpoint for
pinned historical fork tests and to a dedicated endpoint for production submission. Pull-request jobs never receive
an archive secret: they compile and discover proposal tests, while contributors run the forks locally. The trusted
main/merge-queue/manual CI job requires `ROBINHOOD_ARCHIVE_RPC_URL` for concrete proposal forks. The separate live-state
and Sablier compatibility job uses that secret when configured and otherwise falls back to the official public RPC;
the fallback is suitable only while it continues to serve the required historical logs and fresh fork state. A public,
read-only archive proxy can be added later if untrusted pull requests must run proposal forks pre-merge.

## Repository layout

```text
proposals/DGP-NNN.md                    voter-facing description body
script/proposals/DGPNNN/Deploy.s.sol   proposal-specific submission script
test/proposals/DGPNNN/Proposal.t.sol   exact payload and pinned-fork target-effects tests
src/Deepstate*Controller.sol           Rewarder V2 candidate controllers and factory
src/DGP001Bootstrap.sol                constructor-frozen endowment amount and temporary mint action for DGP-001
src/DeepstateRewarderV2.sol            candidate market rewarder implementation
lib/deepstate-contracts/               pinned matching-engine source dependency
lib/deepstate-protocol/                pinned protocol source, including the inherited Rewarder base
script/DeepstateProposal.sol           deterministic payload validation and proposal ID
script/DeepstateProposalScript.s.sol   chain, Governor, STATE, and launch preflight
script/DeployRewarderV2System.s.sol    read-only plan and guarded idempotent CREATE2 deployment
script/config/DeepstateAddresses.sol   canonical live deployment and release-policy registry
deployments/robinhood-4663/            production release manifest template and completed records
docs/DEPLOYMENT.md                     deployment, verification, and activation runbook
docs/INVARIANT_COVERAGE.md             executable system-condition and external-assumption matrix
templates/proposal/                     files copied for each new proposal
```

Every proposal must have its own deployment script. `DGP-NNN` is this repository's sequential naming convention; the
Governor itself does not require that identifier.

## Setup and verification

```bash
git clone git@github.com:Deepstate-Protocol/governance-proposals.git
cd governance-proposals
git -c submodule.recurse=false submodule update --init
cp .env.example .env
set -a
source .env
set +a

make check
make check-live
```

Do not initialize upstream submodules recursively. This repository promotes every compiler dependency to an explicit,
root-pinned library and disables automatic remapping discovery so nested copies cannot affect compilation.

`make check` verifies those pins and remappings, then runs formatting, lint, the one-to-one proposal layout policy,
production build-size checks, Rewarder V2 behavioral/integration tests, shared proposal tests, and all concrete
proposal fork tests. `make check-live` is read-only and also executes the live Sablier compatibility test against a
fresh Robinhood fork. `make invariants` runs the dedicated deployment, activation, Minter, Factory, and Rewarder
state machines. See [`docs/INVARIANT_COVERAGE.md`](docs/INVARIANT_COVERAGE.md) for the condition-by-condition mapping
and the assumptions that cannot be proven by an EVM test.

## Adding a proposal

For `DGP-001`, copy the three files in `templates/proposal/` into these paths:

```text
proposals/DGP-001.md
script/proposals/DGP001/Deploy.s.sol
test/proposals/DGP001/Proposal.t.sol
```

Then:

1. Put the voter-facing specification body in `proposals/DGP-001.md`. Do not add a `#proposer=` line: the base appends
   the exact OpenZeppelin proposer restriction as the final 52 bytes, after any Markdown trailing newline.
2. Set the intended `PROPOSER` in `Deploy.s.sol`. Only that address can submit the resulting payload, preventing
   another threshold holder from front-running and then canceling the reviewed proposal while it is pending.
3. Build every action with `abi.encodeCall`, using a minimal interface for the exact target function. Keep each
   `values` entry at zero unless the proposal intentionally sends ETH and its funding behavior is specified and tested.
4. Record an archive-available, pre-proposal `FORK_BLOCK` and its exact block hash. The template verifies that hash,
   rolls to the reviewed block, then asserts exact targets, values, calldata, description hash, target code,
   preconditions, and postconditions against that fixed Robinhood Chain state.
5. Run the proposal's `printProposal()` entrypoint, copy its final description hash into the test, and copy its generated
   ID into `EXPECTED_PROPOSAL_ID`. Submission and execution refuse any later payload or Markdown drift.
6. Run `make check`, the proposal's pinned fork test, and `make check-live` before review. The layout checker rejects
   missing per-proposal files, zero pins, and template placeholders in concrete proposal artifacts.

Generate the values to pin without submitting anything:

```bash
forge script \
  script/proposals/DGP001/Deploy.s.sol:DeployDGP001 \
  --sig "printProposal()" \
  --rpc-url robinhood \
  -vvvv
```

The [governance documentation](https://docs-production-cdea.up.railway.app/governance/) currently describes only the
onchain submission gate; it does not document a forum vote, proposal bond, or mandatory offchain schema. Repository
review is still required as project policy.

## Simulating and submitting

The signer needs enough **delegated votes** at `Governor.clock() - 1` to meet `proposalThreshold()`. A STATE balance by
itself is not sufficient. Use the same proposer address for simulation and broadcast.

Dry-run a proposal without changing chain state:

```bash
export PROPOSER=0xYourProposerAddress

# Required offchain complement to the Solidity preflight: DEEP roles are not enumerable onchain.
role_snapshot="$(cast block-number --rpc-url robinhood)"
bash script/check-deep-role-history.sh "$role_snapshot"

forge script \
  script/proposals/DGP001/Deploy.s.sol:DeployDGP001 \
  --sig "validateSubmissionPreconditions()" \
  --rpc-url robinhood \
  -vvvv

forge script \
  script/proposals/DGP001/Deploy.s.sol:DeployDGP001 \
  --rpc-url robinhood \
  --sender "$PROPOSER" \
  -vvvv
```

Only after the dry run and review succeed, import a key into Foundry's encrypted keystore and broadcast:

```bash
cast wallet import deepstate-proposer --interactive

forge script \
  script/proposals/DGP001/Deploy.s.sol:DeployDGP001 \
  --rpc-url robinhood \
  --sender "$PROPOSER" \
  --account deepstate-proposer \
  --broadcast \
  --slow \
  -vvvv
```

After broadcast, reopen the proposal through the live RPC. This checks the pinned ID and registered proposer and prints
the current proposal state:

```bash
forge script \
  script/proposals/DGP001/Deploy.s.sol:DeployDGP001 \
  --sig "verifySubmission()" \
  --rpc-url robinhood \
  -vvvv
```

Once the live `proposalSnapshot` has passed, every voter submits a separate vote transaction. Query the live deadline
rather than calculating it from the repository's recorded parameters because a late quorum vote can extend it:

```bash
export GOVERNOR=0x3DC3b787EBDC78bf916f4e30195C61c764C111Ff
export PROPOSAL_ID=0xYourPinnedProposalId
cast wallet import deepstate-voter --interactive

cast call "$GOVERNOR" 'proposalSnapshot(uint256)(uint256)' "$PROPOSAL_ID" --rpc-url robinhood
cast call "$GOVERNOR" 'proposalDeadline(uint256)(uint256)' "$PROPOSAL_ID" --rpc-url robinhood
cast send "$GOVERNOR" 'castVote(uint256,uint8)(uint256)' "$PROPOSAL_ID" 1 \
  --rpc-url robinhood \
  --account deepstate-voter
```

`support = 1` is a vote for the proposal. Reopen `state(proposalId)` and `proposalDeadline(proposalId)` after voting;
do not prepare the market based on an assumed deadline. See the DGP-001 transaction runbook for the claimant
registration and owner-cancellation transactions required between a successful vote and execution.

The base script refuses the wrong chain, a missing or misidentified Governor, an unexpected immutable launch time, a
Governor backed by a token other than the documented STATE contract, malformed arrays, an empty description, a zero
target/proposer, an unpinned or drifted proposal ID, insufficient delegated proposer votes, or premature submission.

Deepstate governance has no timelock or queue. After a proposal succeeds, execution calls the same targets with the
same values, calldata, and description hash directly from the Governor. Dry-run the pinned execution first, then add
`--broadcast` only after the expected post-vote state is confirmed:

```bash
export EXECUTOR=0xYourExecutorAddress
cast wallet import deepstate-executor --interactive

# Repeat immediately before execution; this is what substantiates "no bypass DEEP minter."
role_snapshot="$(cast block-number --rpc-url robinhood)"
bash script/check-deep-role-history.sh "$role_snapshot"

forge script \
  script/proposals/DGP001/Deploy.s.sol:DeployDGP001 \
  --sig "validateActivationPreconditions()" \
  --rpc-url robinhood \
  -vvvv

forge script \
  script/proposals/DGP001/Deploy.s.sol:DeployDGP001 \
  --sig "execute()" \
  --rpc-url robinhood \
  --sender "$EXECUTOR" \
  --account deepstate-executor \
  -vvvv

# Repeat the same command with --broadcast --slow after review.
```

Anyone may execute a succeeded proposal. For nonzero actions, `execute()` supplies the sum of `values` from the
executor to the Governor, preserving any ETH the Governor already held. The script refuses a non-Succeeded or queued
proposal and checks the simulated Executed state plus any proposal-specific `_afterExecution()` checks. Once the
broadcast receipt is mined, reopen live state in a fresh process so those checks are not limited to the simulation:

```bash
forge script \
  script/proposals/DGP001/Deploy.s.sol:DeployDGP001 \
  --sig "verifyExecution()" \
  --rpc-url robinhood \
  -vvvv
```

`verifyExecution()` regenerates the pinned payload, checks its registered proposer, requires the live `Executed`
state and direct-execution mode, and reruns the proposal-specific current postconditions. Run it immediately after
execution; later authorized mints, market launches, claims, hook unlinks, balance burns, or operator changes can legitimately invalidate
exact initial-state checks.

Production-chain Foundry broadcast artifacts are intentionally not ignored; preserve them with the reviewed commit so
the submission and execution payloads remain reproducible. Local chain `31337` and dry-run artifacts stay ignored.

## Current governance parameters

At repository initialization, the live configuration was a three-day voting delay, seven-day voting period, one-day
late-quorum extension, 1% delegated-vote proposal threshold, and 10% quorum. These settings are governance-controlled;
scripts and reviews must query the live Governor instead of assuming they are unchanged.

See [SECURITY.md](SECURITY.md) for the proposal review and key-handling checklist and
[`docs/STATIC_ANALYSIS.md`](docs/STATIC_ANALYSIS.md) for the reviewed Slither triage.
