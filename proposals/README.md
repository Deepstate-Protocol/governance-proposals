# Proposal index

No submission-ready governance proposals have been authored yet. The Rewarder V2 implementation candidate has been
relocated into `src/` and `test/`, but it remains unnumbered until its production deployment inputs and exact activation
payload are dictated and reviewed.

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
| [`DGP-001`](drafts/DGP-001.md) | Draft | Establish the Deepstate Inc endowment and activate the two-year controlled-minting policy. |
| [`DGP-002`](drafts/DGP-002.md) | Draft | Allocate exactly 10 million DEEP to three volunteer team members. |
| [`DGP-003`](drafts/DGP-003.md) | Draft | Activate the constrained Rewarder V2 market-deployment authority. |
