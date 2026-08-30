# Deepstate governance proposals

Foundry project for authoring, reviewing, simulating, and submitting proposals to the live Deepstate Governor. The
repository contains the hardened Rewarder V2 release candidate and deterministic deployment tooling, but no
submission-ready governance proposal yet. The three dictated descriptions remain drafts until the system contracts
are deployed and their addresses, runtime hashes, receipts, and proposal fork block are pinned.

The project follows the Solidity and deployment conventions in
[`deepstate-contracts`](https://github.com/Deepstate-Protocol/deepstate-contracts) and
[`deepstate-protocol`](https://github.com/Deepstate-Protocol/deepstate-protocol): Solidity `0.8.28`, Cancun EVM,
optimized via-IR builds, pinned Foundry dependencies, type-safe calldata, proposal-specific scripts, and tests.

## Rewarder V2 candidate

The 25-commit implementation delta from `deepstate-protocol@codex/rewarder-v2` was relocated here at
[pinned source revision `39a336f`](https://github.com/Deepstate-Protocol/deepstate-protocol/tree/39a336f0015d9a5c3f1029cde1191c1789e85587).
Its production contracts, three interfaces, behavioral tests, Sablier v4.0.1 implementation test, and mock are
first-party files in `src/` and `test/`. In addition to the local implementation test, `make check-live` exercises the
actual Robinhood Lockup and Deepstate Inc Safe on a fork. Unchanged protocol and matching-engine contracts remain
pinned libraries; the local rewarder base is a documented source-pinned fork that adds terminal retirement for
Rewarder V2 instances.

This candidate is not a concrete DGP and has not been deployed. It includes a read-only deterministic CREATE2 plan,
release manifest template, pinned live dependencies, and a live Sablier compatibility test; it does not yet include a
submission-ready Governor action array or proposal ID. See [`docs/REWARDER_V2.md`](docs/REWARDER_V2.md) for the
authority model and [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for the production release procedure.

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

The full documented deployment is recorded in [`DeepstateAddresses.sol`](src/DeepstateAddresses.sol). The address
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
src/DeepstateRewarder.sol              source-pinned rewarder base with terminal retirement
src/DeepstateRewarderV2.sol            candidate market rewarder implementation
lib/deepstate-contracts/               pinned matching-engine source dependency
lib/deepstate-protocol/                pinned live-protocol source dependency
src/DeepstateAddresses.sol             canonical live deployment registry
src/DeepstateProposal.sol              deterministic payload validation and proposal ID
script/DeepstateProposalScript.s.sol   chain, Governor, STATE, and launch preflight
script/DeployRewarderV2System.s.sol    read-only plan and guarded idempotent CREATE2 deployment
deployments/robinhood-4663/            production release manifest template and completed records
docs/DEPLOYMENT.md                     deployment, verification, and activation runbook
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

`make check` verifies those pins and remappings, reconstructs the local Rewarder fork from its reviewed retirement
patch, then runs formatting, lint, the one-to-one proposal layout policy, production build-size checks, Rewarder V2
behavioral/integration tests, shared proposal tests, and all concrete proposal fork tests. `make check-live` is
read-only and also executes the live Sablier compatibility test against a fresh Robinhood fork.

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

The base script refuses the wrong chain, a missing or misidentified Governor, an unexpected immutable launch time, a
Governor backed by a token other than the documented STATE contract, malformed arrays, an empty description, a zero
target/proposer, an unpinned or drifted proposal ID, insufficient delegated proposer votes, or premature submission.

Deepstate governance has no timelock or queue. After a proposal succeeds, execution calls the same targets with the
same values, calldata, and description hash directly from the Governor. Dry-run the pinned execution first, then add
`--broadcast` only after the expected post-vote state is confirmed:

```bash
export EXECUTOR=0xYourExecutorAddress
cast wallet import deepstate-executor --interactive

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
state and direct-execution mode, and reruns the proposal-specific durable postconditions.

Production-chain Foundry broadcast artifacts are intentionally not ignored; preserve them with the reviewed commit so
the submission and execution payloads remain reproducible. Local chain `31337` and dry-run artifacts stay ignored.

## Current governance parameters

At repository initialization, the live configuration was a three-day voting delay, seven-day voting period, one-day
late-quorum extension, 1% delegated-vote proposal threshold, and 10% quorum. These settings are governance-controlled;
scripts and reviews must query the live Governor instead of assuming they are unchanged.

See [SECURITY.md](SECURITY.md) for the proposal review and key-handling checklist and
[`docs/STATIC_ANALYSIS.md`](docs/STATIC_ANALYSIS.md) for the reviewed Slither triage.
