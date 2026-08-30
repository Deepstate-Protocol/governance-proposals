# Rewarder V2 system-condition coverage

This matrix binds every production condition to an executable stateful invariant, a focused fuzz/property test, the
live preflight, or an explicit release responsibility. An EVM invariant can prove how reviewed bytecode behaves under
modeled calls; it cannot prove future external upgrades, honest governance, key custody, market legitimacy, timely
human action, or the provenance of a broadcast transaction.

## Automated state machines

| Surface | Stateful properties |
| --- | --- |
| Deterministic deployment | [`DeployRewarderV2SystemInvariant.t.sol`](../test/invariant/DeployRewarderV2SystemInvariant.t.sol) proves fixed CREATE2 plans, checked runtime/immutable/scalar state at occupied targets, partial-release recovery, idempotent retries, dependency order, no writes to external protocol dependencies, explicit confirmation, wrong-chain rejection, and failure on incompatible occupied addresses. |
| Exact activation model | [`DeepstateActivationConditionsInvariant.t.sol`](../test/invariant/DeepstateActivationConditionsInvariant.t.sol) seeds the legacy Rewarder's balance and two accrued-emission counters, creates the execution-time 30% endowment, establishes sole token administration, performs the guarded idle V1-to-V2 replacement with full 100-million funding, appoints the operator last, and then executes the exact 10-million volunteer allocation. Random unauthorized callers attack every authority while the economic and permission state remains invariant. |
| Minter lifecycle | [`DeepstateMinterSystemInvariant.t.sol`](../test/invariant/DeepstateMinterSystemInvariant.t.sol) randomizes the atomic idle-legacy snapshot/endowment and sole-admin activation, delegated mint roles, pre-activation recovery, ownership changes, successful and failed Sablier mints, burns, time, 3-billion caps, deadline behavior, and permissionless administration return. |
| Factory lifecycle | [`DeepstateFactorySystemInvariant.t.sol`](../test/invariant/DeepstateFactorySystemInvariant.t.sol) randomizes valid and invalid stocks, quantity ramps, semantic side flags, callers, cooldowns, the 1-billion funding limit, controller roles, Router custody, ordinary hooks, exact-predecessor migrations, ownership alignment, Sablier failure, cap exhaustion, removals, and redeployment attempts. Every failed lifecycle call must roll back all observed state, and focused scenarios force compound success/failure branches to be reached. |
| Rewarder operation | [`DeepstateRewarderOperationalInvariant.t.sol`](../test/invariant/DeepstateRewarderOperationalInvariant.t.sol) randomizes hook transitions, caller/pool/token binding, both emission schedules, claim solvency, claimant registration, retirement, post-retirement cleanup, and real Router maker/taker matching against reverting, out-of-gas, and retired hooks. |

All stateful handlers use an explicit selector allowlist. Expected failures are caught inside the handler and must leave
state unchanged, while `foundry.toml` sets `invariant.fail_on_revert = true` so an unexpected handler revert fails the
campaign instead of silently discarding the action and its rolled-back evidence.

## Condition matrix

| ID | Production condition | Enforcement and executable evidence |
| --- | --- | --- |
| D-01 | Deploy only on Robinhood Chain ID 4663. | `DeployRewarderV2System` rejects every fuzzed non-4663 chain; `make check-live` proves the positive live case. |
| D-02 | Governor, DEEP, Router, legacy Rewarder, USDG, Sablier, Comptroller, Safe, and CREATE2 deployer match the reviewed identities and proxy configuration. | Deployment codehash/identity checks plus `script/check-live-deployment.sh`; legacy pool/token/schedule identity, proxy slots, Safe state, Sablier fees, and full role history are intentionally checked by `make check-live` because they are live external state. |
| D-03 | Build from the exact reviewed compiler, source, and pinned submodules. | CI formatting/lint/dependency/build gates and deployment hash tests. A reviewer must still require a clean merged/tagged commit; the EVM cannot inspect Git provenance. |
| D-04 | A predicted target is empty or already contains the reviewed release state. | Empty targets and runtime/immutable/scalar checks are enforced by the deployment state machine and incompatible-occupant property. Because Solady Controller roles are non-enumerable, accepting an occupied Controller also requires an independent scan of every `RolesUpdated` event from its deployment block; the EVM verifier alone cannot prove that an unknown address has no role. |
| D-05 | Partial deployment is recoverable and a retry is idempotent. | Arbitrary partial-order deployment and recovery state machine using the canonical proxy runtime and the real release init code. |
| D-06 | Deployment grants no governance permission and changes no external protocol state. | Deployment invariant records storage accesses and rejects writes to DEEP, Router, legacy Rewarder, USDG, Sablier, Governor, Safe, and other pinned dependencies; it also checks zero Controller roles/operator/counters/deadline/gross issuance and an uncreated legacy endowment after every deployment sequence. |
| A-00 | The immutable legacy Rewarder identifies the reviewed Router, DEEP, pool, and two pool tokens, and sufficient 3-billion live/gross headroom exists. | Constructor/deployment identity checks, exact activation model, and deployment invariants. The final production values remain pinned-archive-fork preconditions. |
| A-01 | As DEEP administration is atomically locked, exactly `floor((token0 totalAccrued + token1 totalAccrued) * 30 / 100)` is placed in one complete one-year stream. | Exact activation and Minter state machines check the one-shot snapshot fields, gross accounting, stream, duration, zero unlocks, and noncancelable/nontransferable flags. The DGP-001 candidate repeats these assertions; the final deployed-state archive run remains a release gate. |
| A-02 | Every temporary/bypass DEEP minter is revoked before controlled minting starts. | Exact activation model plus Minter state machine with three modeled legacy token minters. The live role-history checker supplies the exhaustive production inventory because OpenZeppelin roles are not enumerable onchain. |
| A-03 | `lockTokenAdministration()` succeeds only with the Minter Controller as DEEP's sole default administrator and an exact idle legacy market; it creates the endowment before starting the 730-day term. | Exact activation and Minter phase/deadline/rollback invariants. |
| A-04 | The volunteer primary allocation is exactly 10 million DEEP split into the three dictated amounts. | Exact activation economic invariant; the three balances sum exactly to 10 million base-unit precise DEEP. |
| A-05 | The volunteer mint creates `floor(10M * 30 / 70)` in a separate one-year Inc stream. | Exact activation stream 3 and Controller gross-issuance invariants. |
| A-06 | Factory receives only Controller-local mint authority and V1 hook authority; V1 Controller owns Router; approved Safe is operator. | Exact activation authority invariant and Factory authority state machine. Factory is asserted never to hold a DEEP token role. |
| A-07 | The Router fee and two active hook flags are preserved while the exact V1 hook is replaced by the exact Factory-created V2. | Exact activation model checks the 10-bps fee, packed flags, predecessor, V2 address/configuration, Factory provenance, funding, and permissions. DGP-001 checks the public hook and fee state; its final archive test must also inspect the Router's packed side flags. |
| A-08 | DGP-001 succeeds only if the pool has no bid/ask top and V1 has no token0/token1 cursor; every action rolls back if replacement fails. | Factory migration unit/state-machine rollback properties and the exact activation composition model. The DGP-001 candidate includes a real-Governor lifecycle and forced migration-failure rollback test; the final unmocked deployed-state archive run remains required. |
| M-01 | Controlled minting is inactive before lock and at/after the exact 730-day deadline. | Minter phase, strict-window, exact-deadline, and permanent-expiry properties. |
| M-02 | Only the Controller owner or explicit Controller-local minters can mint. | Random caller/role/ownership Minter state machine and exact activation unauthorized-caller campaign. |
| M-03 | Every primary mint produces `floor(primary * 30 / 70)` in an independent one-year, zero-cliff, noncancelable, nontransferable stream. | Per-stream Minter invariant over every successful randomized mint. Rounding is below exact 30% only by less than one DEEP base unit when the primary amount is not divisible by seven. |
| M-04 | Live supply and permanent Controller gross issuance never exceed 3 billion DEEP; burns never restore gross headroom. | Minter accounting/cap/burn invariants and Factory conservation invariant. |
| M-05 | A failed token/Sablier interaction is atomic. | Random Sablier failure state and focused failure/recovery property assert unchanged supply, gross issuance, balances, allowance, and stream ID. |
| M-06 | Controller ownership cannot become zero/self; a failed pre-activation handoff is recoverable; expiration returns DEEP admin to the current owner. | Random invalid ownership, pre-activation recovery, governance rotation, exact-deadline return, and permissionless unlock properties. |
| M-07 | Factory, Minter Controller, and V1 Controller retain a common governance owner for Factory operations. | Factory state machine randomizes split ownership, realignment, and full migration; misalignment must pause lifecycle calls. |
| F-01 | Only Factory owner/current operator can deploy or remove; only owner can migrate an existing hook or change operator. | Random caller Factory invariants and full rollback assertions. |
| F-02 | Factory operations require Controller-local mint and hook-manager roles plus V1 Router custody. | Activation proves the initial grants/custody. Factory roles/custody are then independently removed and restored; lifecycle success while a dependency is absent is an invariant violation. Continued retention is live governance state and must be monitored. |
| F-03 | Stock has code, is distinct from USDG, and reports 18 decimals; USDG reports six decimals. | Random zero/EOA/USDG/wrong-decimal/valid-token deployment state machine; constructor properties cover USDG. |
| F-04 | At least one semantic side is active and the Factory maps it correctly after sorting. | Random side flags are compared with the Router's actual packed token0/token1 activation state after every successful launch and in rollback snapshots. |
| F-05 | Stock ramp has nonzero start and 1,000x to 1,000,000x growth; USDG is fixed at 1 to 1,000,000 USDG. | Boundary/adversarial ramp state machine and immutable Rewarder configuration invariant. |
| F-06 | An ordinary launch cannot replace any hook, active market, previous Factory deployment, or retired pool. | Random external-hook mutation, deployment, retirement, and redeployment state machine with permanent provenance assertions. |
| F-07 | Global three-day cooldown and lifetime 1-billion primary budget are respected. | Independent literal policy assertions, timestamp sequence, deterministic boundary scenarios, production constructor plan, and monotonic committed-budget invariants; retirement never restores provenance or budget. |
| F-08 | Every market atomically deploys, fully funds with 100 million primary DEEP, creates the paired Inc stream, and installs a 50-million-per-side, 365-day hook. | Factory market/provenance/configuration and mint-conservation invariants inspect each Rewarder and stream's funder, recipient, amount, one-year duration, zero unlocks, and transfer/cancel flags. |
| F-09 | Migration is governance-only and checks the exact predecessor identity, current hook, empty Router book, and zero legacy cursors before any clear. | Focused and stateful migration properties force every stale, mismatched, non-idle, unauthorized, and rollback branch. |
| F-10 | Mint-window, cap, Sablier, role, Router, migration, or configuration failure rolls back deployment/removal completely. | Snapshots cover Factory mappings/counters, Router hook, DEEP supply/balances, gross issuance, stream IDs, Rewarder state, and ownership. |
| R-01 | Only Router can execute and only for the immutable pool and pool tokens. | Random unauthorized/wrong-pool/wrong-token calls with unchanged cursor/accounting state. |
| R-02 | Each enabled V2 side activates independently, remains monotonic, and never exceeds its 50-million cap or the 100-million combined cap over 365 days. | Rewarder schedule/accrual state machine and fuzzed monotonic/quantity-adjusted preview properties. Separate reproduction tests intentionally retain V1's immutable 500-million/395-day parameters. |
| R-03 | Reviewed `execute()` paths fit Router's 200,000-gas hook budget. | Randomized successful-execution gas invariant plus a deterministic cold accrual call that succeeds with exactly 200,000 gas forwarded. This must be rerun after compiler, source, or gas-schedule changes. |
| R-04 | An underfunded claim fails atomically and succeeds after funding. | Fuzzed live-order claim rollback/retry property. |
| R-05 | Claimant registration before order deletion preserves a claim; an unregistered deleted owner cannot be reconstructed. | Paired registered/unregistered fuzz property using the Rewarder's real claim path. |
| R-06 | Router matching survives a reverting, out-of-gas, or retired hook, while the failed transition records no reward update. | Real Router fuzz properties execute an opposing maker/taker match with token exchange for all three hook failures. This proves trading isolation and makes the missed-accounting behavior explicit. |
| R-07 | Retirement is terminal, burns all remaining funding, forfeits unpaid claims, and permits later balance cleanup. | Stateful terminal-lifecycle invariant and focused unpaid-claim/direct-refunding property. |
| R-08 | An active market's Router hook remains its expected Rewarder for rewards to accrue. | Factory removal checks fail safely after drift, but governance can intentionally clear or replace a hook without changing `activeRewarder`. Continued alignment is therefore a live monitoring condition, not an immutable contract invariant. |
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
- Governance reserves sufficient live/gross headroom for each fully funded 100-million market and its paired stream.
  Tests prove cap failure and rollback behavior, not that future headroom will remain available.
- Before DGP-001 execution, users or keepers register all V1 claimants that must survive order deletion and empty both
  sides so the final V1 callbacks clear its cursors. The contract can enforce the empty execution state but cannot make
  users prepare it.
- V1's unused balance remains permanently in the immutable legacy contract because it has no retirement or sweep path.
- Users or keepers register claimants before order ownership is deleted, and the trusted operator does not retire a
  market before the intended claim window closes.
- Governance or its monitor keeps each intended active Rewarder installed as the Router hook with the reviewed side
  flags. An authorized hook replacement is permitted by design and stops future reward accounting for that side.
- A broadcaster has the correct wallet, gas, nonce, RPC, and explicit `--broadcast` intent; receipts, finality, explorer
  verification, and the release manifest are reviewed and recorded.
- Independent human review, a clean merged/tagged commit, and source/submodule provenance are release-process facts,
  not EVM state.

DGP-001 now has a concrete eight-action script, pinned payload/description checks, submission and execution preflights,
intermediate authorized-call assertions, immediate postconditions, a real-Governor lifecycle, and an atomic rollback
test. Its current fork models the not-yet-completed operational idle handoff and locally deploys the deterministic
targets; release readiness still requires actual deployment receipts, naturally idle live state, and a final unmocked
run against a pinned Robinhood archive block. DGP-002 does not yet have a concrete script.

## Commands

```bash
make invariants
make check
make check-live
```

`make invariants` is offline and includes deterministic, fuzz, and stateful tests under `test/invariant/`.
`make check-live` is a read-only production snapshot and real-Sablier fork gate. Both are required because neither can
prove the other's class of conditions.
