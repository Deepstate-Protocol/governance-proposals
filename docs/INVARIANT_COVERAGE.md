# Rewarder V2 system-condition coverage

This matrix binds every production condition to an executable stateful invariant, a focused fuzz/property test, the
live preflight, or an explicit release responsibility. An EVM invariant can prove how reviewed bytecode behaves under
modeled calls; it cannot prove future external upgrades, honest governance, key custody, market legitimacy, timely
human action, or the provenance of a broadcast transaction.

## Automated state machines

| Surface | Stateful properties |
| --- | --- |
| Deterministic deployment | [`DeployRewarderV2SystemInvariant.t.sol`](../test/invariant/DeployRewarderV2SystemInvariant.t.sol) proves fixed CREATE2 plans, checked runtime/immutable/scalar state at occupied targets, partial-release recovery, idempotent retries, dependency order, no writes to external protocol dependencies, explicit confirmation, wrong-chain rejection, and failure on incompatible occupied addresses. |
| Exact activation model | [`DeepstateActivationConditionsInvariant.t.sol`](../test/invariant/DeepstateActivationConditionsInvariant.t.sol) seeds the existing 1 billion DEEP Rewarder allocation, executes its exact 300 million (30%) endowment before locking, the exact 10 million volunteer allocation and 30/70 stream, and the Factory's delegated-role activation. Random unauthorized callers then attempt token minting, controlled minting, fees, hook flags, Router ownership, roles, operator replacement, and early unlock while the exact economic and authority state remains invariant. |
| Minter lifecycle | [`DeepstateMinterSystemInvariant.t.sol`](../test/invariant/DeepstateMinterSystemInvariant.t.sol) randomizes pre-activation bypass minting, ordered sole-admin activation, delegated mint roles, ownership changes, successful and failed Sablier mints, burns, time, deadline behavior, and permissionless administration return. |
| Factory lifecycle | [`DeepstateFactorySystemInvariant.t.sol`](../test/invariant/DeepstateFactorySystemInvariant.t.sol) randomizes valid and invalid stocks, quantity ramps, semantic side flags, callers, cooldowns, funding limits, controller roles, Router custody, hooks, ownership alignment and migration, Sablier failure, cap exhaustion, top-ups, removals, and redeployment attempts. Every failed lifecycle call must roll back all observed state, and focused scenarios force compound success/failure branches to be reached. |
| Rewarder operation | [`DeepstateRewarderOperationalInvariant.t.sol`](../test/invariant/DeepstateRewarderOperationalInvariant.t.sol) randomizes hook transitions, caller/pool/token binding, both emission schedules, claim solvency, claimant registration, retirement, post-retirement cleanup, and real Router maker/taker matching against reverting, out-of-gas, and retired hooks. |

All stateful handlers use an explicit selector allowlist. Expected failures are caught inside the handler and must leave
state unchanged, while `foundry.toml` sets `invariant.fail_on_revert = true` so an unexpected handler revert fails the
campaign instead of silently discarding the action and its rolled-back evidence.

## Condition matrix

| ID | Production condition | Enforcement and executable evidence |
| --- | --- | --- |
| D-01 | Deploy only on Robinhood Chain ID 4663. | `DeployRewarderV2System` rejects every fuzzed non-4663 chain; `make check-live` proves the positive live case. |
| D-02 | Governor, DEEP, Router, USDG, Sablier, Comptroller, Safe, and CREATE2 deployer match the reviewed identities and proxy configuration. | Deployment codehash/identity checks plus `script/check-live-deployment.sh`; proxy slots, Safe state, Sablier fees, and full role history are intentionally checked by `make check-live` because they are live external state. |
| D-03 | Build from the exact reviewed compiler, source, and pinned submodules. | CI formatting/lint/dependency/build gates and deployment hash tests. A reviewer must still require a clean merged/tagged commit; the EVM cannot inspect Git provenance. |
| D-04 | A predicted target is empty or already contains the reviewed release state. | Empty targets and runtime/immutable/scalar checks are enforced by the deployment state machine and incompatible-occupant property. Because Solady Controller roles are non-enumerable, accepting an occupied Controller also requires an independent scan of every `RolesUpdated` event from its deployment block; the EVM verifier alone cannot prove that an unknown address has no role. |
| D-05 | Partial deployment is recoverable and a retry is idempotent. | Arbitrary partial-order deployment and recovery state machine using the canonical proxy runtime and the real release init code. |
| D-06 | Deployment grants no governance permission and changes no external protocol state. | Deployment invariant records storage accesses and rejects writes to DEEP, Router, USDG, Sablier, Governor, Safe, and other pinned dependencies; it also checks zero Controller roles/operator/counters/deadline/gross issuance after every deployment sequence. |
| A-00 | The referenced existing Rewarder allocation is exactly 1 billion DEEP and sufficient live/gross headroom exists. | The local exact-activation model seeds and preserves the 1 billion baseline and proves the 300 million ratio. The actual production supply, allocation, and headroom remain pinned-archive-fork preconditions. |
| A-01 | The complete 300 million DEEP endowment, exactly 30% of the existing 1 billion allocation, is streamed before DEEP administration is locked. | Exact activation model checks the ratio, stream 1, supply, balance, duration, zero unlocks, and noncancelable/nontransferable flags. The eventual DGP-001 payload must repeat this against a pinned archive fork. |
| A-02 | Every temporary/bypass DEEP minter is revoked before controlled minting starts. | Exact activation model plus Minter state machine with three modeled legacy token minters. The live role-history checker supplies the exhaustive production inventory because OpenZeppelin roles are not enumerable onchain. |
| A-03 | Minter Controller is DEEP's sole default administrator and `lockTokenAdministration()` is called last. | Exact activation and Minter phase/deadline invariants. |
| A-04 | The volunteer primary allocation is exactly 10 million DEEP split into the three dictated amounts. | Exact activation economic invariant; the three balances sum exactly to 10 million base-unit precise DEEP. |
| A-05 | The volunteer mint creates `floor(10M * 30 / 70)` in a separate one-year Inc stream. | Exact activation stream-2 and Controller gross-issuance invariants. |
| A-06 | Factory receives only Controller-local mint authority and V1 hook authority; V1 owns Router; approved Safe is operator. | Exact activation authority invariant and Factory authority state machine. Factory is asserted never to hold a DEEP token role. |
| A-07 | Existing Router fees, hook address, and both semantic hook-side flags are unchanged by activation. | Exact activation model seeds a 10-bps fee and legacy two-sided hook, exercises unauthorized direct/Controller hook and ownership calls, and holds the full state invariant. The concrete DGP must assert the actual production fee and hooks on a pinned fork. |
| M-01 | Controlled minting is inactive before lock and at/after the exact 730-day deadline. | Minter phase, strict-window, exact-deadline, and permanent-expiry properties. |
| M-02 | Only the Controller owner or explicit Controller-local minters can mint. | Random caller/role/ownership Minter state machine and exact activation unauthorized-caller campaign. |
| M-03 | Every primary mint produces `floor(primary * 30 / 70)` in an independent one-year, zero-cliff, noncancelable, nontransferable stream. | Per-stream Minter invariant over every successful randomized mint. Rounding is below exact 30% only by less than one DEEP base unit when the primary amount is not divisible by seven. |
| M-04 | Live supply and permanent Controller gross issuance never exceed 20 billion DEEP; burns never restore gross headroom. | Minter accounting/cap/burn invariants and Factory conservation invariant. |
| M-05 | A failed token/Sablier interaction is atomic. | Random Sablier failure state and focused failure/recovery property assert unchanged supply, gross issuance, balances, allowance, and stream ID. |
| M-06 | Controller ownership cannot become zero/self and expiration returns DEEP admin to the current owner. | Random invalid ownership, governance rotation, exact-deadline return, and permissionless unlock properties. |
| M-07 | Factory, Minter Controller, and V1 Controller retain a common governance owner for Factory operations. | Factory state machine randomizes split ownership, realignment, and full migration; misalignment must pause lifecycle calls. |
| F-01 | Only Factory owner/current operator can deploy or remove; only owner can top up or change operator. | Random caller Factory invariants and full rollback assertions. |
| F-02 | Factory operations require Controller-local mint and hook-manager roles plus V1 Router custody. | Activation proves the initial grants/custody. Factory roles/custody are then independently removed and restored; lifecycle success while a dependency is absent is an invariant violation. Continued retention is live governance state and must be monitored. |
| F-03 | Stock has code, is distinct from USDG, and reports 18 decimals; USDG reports six decimals. | Random zero/EOA/USDG/wrong-decimal/valid-token deployment state machine; constructor properties cover USDG. |
| F-04 | At least one semantic side is active and the Factory maps it correctly after sorting. | Random side flags are compared with the Router's actual packed token0/token1 activation state after every successful launch and in rollback snapshots. |
| F-05 | Stock ramp has nonzero start and 1,000x to 1,000,000x growth; USDG is fixed at 1 to 1,000,000 USDG. | Boundary/adversarial ramp state machine and immutable Rewarder configuration invariant. |
| F-06 | No existing hook, active market, previous Factory deployment, or retired pool can be replaced/relaunched. | Random external-hook mutation, deployment, retirement, and redeployment state machine with permanent provenance assertions. |
| F-07 | Global three-day cooldown and lifetime 1.5-billion initial-primary budget are respected. | Independent literal policy assertions, timestamp sequence, deterministic boundary scenarios, production constructor plan, and monotonic committed-budget invariants; retirement never restores provenance or budget. |
| F-08 | Every launch atomically deploys, funds with 150 million primary DEEP, creates the paired Inc stream, and installs the exact hook. | Factory market/provenance/configuration and mint-conservation invariants inspect each new stream's funder, recipient, amount, one-year duration, zero unlocks, and transfer/cancel flags. |
| F-09 | Top-up is governance-only, expected-Rewarder checked, active-hook checked, not retired, and one-shot for exactly 850 million. | Random and forced top-up lifecycle properties prove the amount, authority, atomicity, and one-shot state. The stale-active-but-retired guard is reached by `test_TopUpCannotFundRetiredRewarderEvenIfFactoryBookIsStale`. |
| F-10 | Mint-window, cap, Sablier, role, Router, or configuration failure rolls back deployment/top-up/removal completely. | Snapshots cover Factory mappings/counters, Router hook, DEEP supply/balances, gross issuance, stream IDs, Rewarder state, and ownership. |
| R-01 | Only Router can execute and only for the immutable pool and pool tokens. | Random unauthorized/wrong-pool/wrong-token calls with unchanged cursor/accounting state. |
| R-02 | Each enabled side activates independently, remains monotonic, and never exceeds its 500-million cap or the one-billion combined cap. | Rewarder schedule/accrual state machine and fuzzed monotonic/quantity-adjusted preview properties. |
| R-03 | Reviewed `execute()` paths fit Router's 200,000-gas hook budget. | Randomized successful-execution gas invariant plus a deterministic cold accrual call that succeeds with exactly 200,000 gas forwarded. This must be rerun after compiler, source, or gas-schedule changes. |
| R-04 | An underfunded claim fails atomically and succeeds after funding. | Fuzzed live-order claim rollback/retry property. |
| R-05 | Claimant registration before order deletion preserves a claim; an unregistered deleted owner cannot be reconstructed. | Paired registered/unregistered fuzz property using the Rewarder's real claim path. |
| R-06 | Router matching survives a reverting, out-of-gas, or retired hook, while the failed transition records no reward update. | Real Router fuzz properties execute an opposing maker/taker match with token exchange for all three hook failures. This proves trading isolation and makes the missed-accounting behavior explicit. |
| R-07 | Retirement is terminal, burns all remaining funding, forfeits unpaid claims, and permits later balance cleanup. | Stateful terminal-lifecycle invariant and focused unpaid-claim/direct-refunding property. |
| R-08 | An active market's Router hook remains its expected Rewarder for rewards to accrue. | Factory top-up/removal checks fail safely after drift, but governance can intentionally clear or replace a hook without changing `activeRewarder`. Continued alignment is therefore a live monitoring condition, not an immutable contract invariant. |
| E-01 | Minting stops at day 730 and anyone can return administration atomically to the current Controller owner. | Exact-boundary Minter property and stateful expiry invariant. |

## External conditions that tests cannot make true

The suite exercises failure behavior for these assumptions but cannot guarantee their future truth:

- Sablier Lockup and its upgradeable Comptroller remain compatible, available, `nativeToken != DEEP`, and zero-fee for
  the call used by the Minter. `make check-live` and the real Sablier fork test must run immediately before deployment,
  proposal submission, execution, and material minting.
- The Governor remains honest and functional, voters pass the intended payload, the proposer retains sufficient
  delegated STATE votes, and governance is not captured.
- Any pre-existing deterministic Controller target has a complete `RolesUpdated` event inventory proving there are no
  unknown delegated role holders. Runtime code and scalar getters cannot enumerate Solady's address-keyed role mapping.
- The Deepstate Inc Safe and deployment/proposer keys remain secure and available. Preflight verifies the expected Safe
  singleton, owner, threshold, and modules only at one snapshot.
- An operator-selected 18-decimal contract is a legitimate stock token with suitable behavior, liquidity, and economic
  ramp values. Bytecode cannot prove the legal or economic identity of an asset.
- Governance reserves sufficient live/gross headroom and tops up each 150-million-funded market before claims exhaust
  available liquidity. Tests prove failure/retry behavior, not that a human proposal will arrive on time.
- Users or keepers register claimants before order ownership is deleted, and the trusted operator does not retire a
  market before the intended claim window closes.
- Governance or its monitor keeps each intended active Rewarder installed as the Router hook with the reviewed side
  flags. An authorized hook replacement is permitted by design and stops future reward accounting for that side.
- A broadcaster has the correct wallet, gas, nonce, RPC, and explicit `--broadcast` intent; receipts, finality, explorer
  verification, and the release manifest are reviewed and recorded.
- Independent human review, a clean merged/tagged commit, and source/submodule provenance are release-process facts,
  not EVM state.

Concrete DGP-001/002/003 scripts do not exist yet. The local exact-activation invariant proves the current contracts
compose with the dictated order and amounts, but release readiness still requires exact payload tests against a pinned
Robinhood archive block and durable post-execution assertions for the deployed addresses.

## Commands

```bash
make invariants
make check
make check-live
```

`make invariants` is offline and includes deterministic, fuzz, and stateful tests under `test/invariant/`.
`make check-live` is a read-only production snapshot and real-Sablier fork gate. Both are required because neither can
prove the other's class of conditions.
