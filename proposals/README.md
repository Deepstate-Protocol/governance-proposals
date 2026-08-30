# Proposal index

No proposal is ready to submit yet. DGP-001 has a numbered, exact payload candidate and matching tests, but its three
deterministic target contracts are not deployed and its final unmocked archive-fork release test is outstanding.
DGP-002 remains voter-facing draft text without a payload.

Voter-facing text that has been dictated but does not yet have a deployable, fully tested payload is preserved under
`proposals/drafts/`. A draft moves into this directory only when its matching deployment script and pinned-fork test
are ready, at which point the one-to-one proposal layout policy applies.

Each proposal added to this repository receives a sequential `DGP-NNN` identifier, a Markdown description in this
directory, its own deployment script under `script/proposals/DGPNNN/Deploy.s.sol`, and a corresponding test under
`test/proposals/DGPNNN/Proposal.t.sol`.

The Markdown file is the description body. The shared script appends an exact, terminal OpenZeppelin proposer
restriction before computing the description hash and pinned proposal ID.

`DGP-NNN` is a repository convention, not an onchain Governor requirement.

| Proposal | Status | Summary |
| --- | --- | --- |
| [`DGP-001`](DGP-001.md) | Pre-deployment payload candidate | Establish the Deepstate Inc endowment, activate controlled minting, and atomically replace the live Rewarder with Rewarder V2. |
| [`DGP-002`](drafts/DGP-002.md) | Draft | Allocate exactly 10 million DEEP to three volunteer team members. |
