# Rewarder V2 production workflow

Production uses three operator-facing Foundry scripts:

1. `DeployContracts` deploys all four required contracts with ordinary `CREATE`.
2. `DeployDGP001` registers DGP-001 with the live Governor.
3. `DeployDGP002` registers DGP-002 with the live Governor after DGP-001 executes.

The first item is one script and one command. It necessarily produces four contract-creation transactions because it
deploys four contracts: `DeepstateMinterController`, `DGP001Bootstrap`, `DeepstateV1Controller`, and
`DeepstateRewarderFactory`. It does not use CREATE2 or a deployment proxy, and it has no separate plan/deploy
entrypoints or confirmation environment variable.

Deployment alone does not grant a DEEP role, grant a controller role, transfer the Router, appoint an operator, mint
DEEP, create a Sablier stream, or install a pool hook. Those changes remain in DGP-001's atomic Governor payload.

## 1. Prepare the repository and RPC

Use the exact reviewed commit with a clean tree and root-pinned submodules:

```bash
git fetch origin
git switch codex/rewarder-v2
git pull --ff-only
git -c submodule.recurse=false submodule update --init

git rev-parse HEAD
git status --porcelain=v1
bash script/check-dependency-layout.sh
```

Do not initialize submodules recursively. `git status --porcelain=v1` must print nothing.

Put only the RPC URL in an ignored `.env`; never put a private key there:

```bash
cp .env.example .env
chmod 600 .env
# Set ROBINHOOD_RPC_URL in .env to a reviewed archive-capable endpoint.

set -a
source .env
set +a

cast chain-id --rpc-url "$ROBINHOOD_RPC_URL"
```

The chain ID must be `4663`.

## 2. Import the key safely

Foundry stores an imported key in its encrypted keystore. This command prompts for the private key and a keystore
password without putting either value in the repository or command line:

```bash
cast wallet import deepstate --interactive
export SIGNER="$(cast wallet address --account deepstate)"
printf 'Signer: %s\n' "$SIGNER"
```

For the three-command workflow, `deepstate` must resolve to the exact pinned proposer
`0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2`, have enough delegated STATE votes at the Governor's clock checkpoint, and
hold enough Robinhood native token for gas. The deployment itself gives this signer no protocol authority.

Do not pass a raw private key with `--private-key`, export one in an environment variable, paste one into shell history,
or commit one anywhere. A separate gas-only deployer is supported, but is not required for this workflow.

## 3. Run the release gates

```bash
make check
make check-live
```

`make check-live` must use the archive RPC and pass immediately before the system deployment. It verifies the reviewed
live dependencies, DEEP role history, legacy Rewarder, Router, Safe, and Sablier compatibility. It is intentionally a
pre-activation check and will fail after DGP-001 changes the live role and ownership baseline.

## 4. Deploy all four contracts

First simulate the single system script without `--broadcast`:

```bash
forge script script/DeployContracts.s.sol:DeployContracts \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$SIGNER" \
  --account deepstate \
  -vvvv
```

Review the broadcaster, nonce, gas, constructor arguments, and four reported addresses. Then broadcast the same script:

```bash
forge script script/DeployContracts.s.sol:DeployContracts \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$SIGNER" \
  --account deepstate \
  --broadcast \
  --slow \
  -vvvv
```

The script deploys in dependency order:

1. Minter Controller;
2. DGP-001 Bootstrap;
3. V1 Controller; and
4. Rewarder Factory, using the actual Controller addresses returned earlier in the same run.

Ordinary `CREATE` addresses depend on the broadcaster and its nonce. Do not assume addresses from an earlier
simulation, branch, or manifest. Do not rerun the broadcast after a successful deployment: another run creates a
second independent set of contracts.

## 5. Record and pin the deployment

Copy [`rewarder-v2.template.json`](../deployments/robinhood-4663/rewarder-v2.template.json) to a completed release file
and record:

- the source commit and clean-tree status;
- preflight block and hash;
- broadcaster and starting nonce;
- all four actual addresses, transaction hashes, blocks, block hashes, and runtime code hashes;
- all constructor arguments;
- the legacy token0 and token1 `totalAccrued` values read by the Bootstrap constructor;
- the Bootstrap's constructor-frozen `endowmentAmount`;
- the Foundry broadcast artifact; and
- explorer source-verification status.

The Bootstrap amount is fixed by its deployment transaction as
`floor((legacy token0 totalAccrued + legacy token1 totalAccrued) * 30 / 100)`. Read the deployed address reported by the
script rather than using an old example:

```bash
cast call "$DGP001_BOOTSTRAP" 'endowmentAmount()(uint128)' --rpc-url "$ROBINHOOD_RPC_URL"
```

Verify every deployed runtime hash and immutable getter from a fresh RPC. Preserve the production artifact under
`broadcast/DeployContracts.s.sol/4663/`, after checking that it contains no secret.

## 6. Pin DGP-001 before registering it

This handoff is mandatory. After ordinary deployment, make and review a small code update that records the four actual
addresses and their runtime code hashes in `script/config/DeepstateAddresses.sol`. Then regenerate and pin:

- DGP-001's payload and proposal ID using the actual addresses and frozen Bootstrap amount;
- DGP-002's DGP-001 dependency ID and its resulting own proposal ID;
- the post-deployment archive block and hash used by proposal tests; and
- the completed deployment manifest.

Run `make check`, the concrete fork suites, and `make check-live` from that pinning commit. Merge it before registration.
Do not feed unreviewed addresses through environment variables: the governance targets and IDs are intentionally
compile-time pinned.

Print DGP-001's final payload without submitting it:

```bash
forge script script/DeployDGP001.s.sol:DeployDGP001 \
  --sig 'printProposal()' \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  -vvvv
```

The generated ID must equal the reviewed `EXPECTED_PROPOSAL_ID`.

## 7. Register DGP-001

Run its read-only precondition check, then simulate the default registration entrypoint:

```bash
forge script script/DeployDGP001.s.sol:DeployDGP001 \
  --sig 'validateSubmissionPreconditions()' \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  -vvvv

forge script script/DeployDGP001.s.sol:DeployDGP001 \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$SIGNER" \
  --account deepstate \
  -vvvv
```

After reviewing the simulation, register DGP-001:

```bash
forge script script/DeployDGP001.s.sol:DeployDGP001 \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$SIGNER" \
  --account deepstate \
  --broadcast \
  --slow \
  -vvvv
```

Verify it from fresh state:

```bash
forge script script/DeployDGP001.s.sol:DeployDGP001 \
  --sig 'verifySubmission()' \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  -vvvv
```

DGP-001 must pass, be voted through, and execute successfully before DGP-002 can be registered. Market preparation,
voting, execution, and post-execution verification are detailed in
[`DGP-001-TRANSACTION-RUNBOOK.md`](DGP-001-TRANSACTION-RUNBOOK.md).

## 8. Refresh and register DGP-002

After DGP-001 executes, pin a post-execution archive block and hash, rerun DGP-002's sequential fork suite, and confirm
that its compiled DGP-001 dependency ID matches the executed proposal. Then run the second proposal's preflight and
simulation:

```bash
forge script script/DeployDGP002.s.sol:DeployDGP002 \
  --sig 'validateSubmissionPreconditions()' \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  -vvvv

forge script script/DeployDGP002.s.sol:DeployDGP002 \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$SIGNER" \
  --account deepstate \
  -vvvv
```

Register DGP-002 only after that review succeeds:

```bash
forge script script/DeployDGP002.s.sol:DeployDGP002 \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$SIGNER" \
  --account deepstate \
  --broadcast \
  --slow \
  -vvvv
```

Finally, run `verifySubmission()` against fresh live state and preserve the proposal broadcast artifact. See
[`DGP-002-TRANSACTION-RUNBOOK.md`](DGP-002-TRANSACTION-RUNBOOK.md) for the full lifecycle.
