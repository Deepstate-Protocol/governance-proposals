# Static-analysis triage

The release runs `slither-analyzer==0.11.6` against first-party production source and the exact inherited
`lib/deepstate-protocol/src/DeepstateRewarder.sol` base, with every other library, test, and script excluded. CI fails
any High-severity result. This file records the reviewed Medium detectors that remain after the
checks-effects-interactions and reentrancy hardening; a new detector or materially changed code requires fresh triage.

| Detector | Scope | Disposition |
| --- | --- | --- |
| `divide-before-multiply` | `DeepstateRewarder._e1ContinuedFractionFactor` | Intentional fixed-point continued-fraction recurrence in the source-pinned reward algorithm. Independent numerical vectors, additive integration fuzzing, maximum-growth one-second fragmentation regressions, and cross-scale 1,000-run partition fuzzing bound the resulting error. |
| `incorrect-equality` | Rewarder activation sentinels, zero balances, order identity, and zero elapsed time | These are exact discrete states, not manipulable price or balance thresholds. Tests cover the zero/nonzero boundaries and order/book identity checks. |
| `uninitialized-local` | Reward accumulator, batch claimant, and batch total | Solidity/EVM locals intentionally begin at zero; the functions use zero as their accumulator/sentinel value. Behavioral and invariant suites cover empty and populated paths. |

Slither also reports Low/Informational items for bounded user-paid loops, timestamp-based vesting/emission deadlines,
intentional revocation through `setOperator(address(0))`, a defensive metadata `staticcall`, source-pinned assembly,
interface naming, abstract proposal functions, and events emitted after calls into pinned live DEEP/Router contracts.
These are design properties or false positives, not suppressed findings. Re-run and review the complete tool output at
the final source commit; this triage is not a substitute for an independent audit.
