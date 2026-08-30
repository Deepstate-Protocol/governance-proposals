# Proposal security

Deepstate governance executes successful proposals directly, with no timelock or post-vote escape window. A proposal
review is therefore a production deployment review.

Before submission:

- run `make check-dependencies` and confirm every root library is at its expected pinned gitlink revision;
- compare every address with the live Deepstate documentation and run `make check-live`;
- bind the final description to the intended signer with the generated terminal `#proposer=0x…` restriction;
- inspect the exact description hash, targets, values, calldata, proposer, and pinned proposal ID from the reviewed commit;
- use `abi.encodeCall` and minimal interfaces so compiler type checks cover every function argument;
- pin and verify the fixed block number and hash, then test exact preconditions and postconditions through an
  archive-capable Robinhood Chain RPC;
- confirm each privileged target is currently controlled by the Governor;
- verify every newly deployed contract's constructor immutables, owner, runtime code hash, and source revision;
- reconstruct non-enumerable role membership from deployment state and historical events before revoking or replacing
  any role holder;
- confirm nonzero ETH values are intentional and funded safely;
- confirm the proposer has enough delegated historical votes, not merely enough STATE balance;
- simulate with the exact proposer before adding `--broadcast`; and
- run `verifySubmission()` over the live RPC after submission;
- separately dry-run the pinned `execute()` payload after the proposal reaches Succeeded, broadcast only after review,
  then run `verifyExecution()` against fresh live state after the receipt is mined; and
- use an encrypted keystore or hardware-backed signer and never commit `.env`, private keys, or keystore passwords.

The checked-in address registry and source revisions are review inputs, not proof that deployed bytecode matches a
particular source commit. Live code, roles, ownership, and relevant state must be checked again for every proposal.

Report a vulnerability privately through a GitHub Security Advisory for this repository. Do not include an exploitable
proposal payload in a public issue before the maintainers have coordinated a response.
