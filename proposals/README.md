# Proposal index

No submission-ready governance proposals have been authored yet. The Rewarder V2 implementation candidate has been
relocated into `src/` and `test/`, but it remains unnumbered until its production deployment inputs and exact activation
payload are dictated and reviewed.

Each proposal added to this repository receives a sequential `DGP-NNN` identifier, a Markdown description in this
directory, its own deployment script under `script/proposals/DGPNNN/Deploy.s.sol`, and a corresponding test under
`test/proposals/DGPNNN/Proposal.t.sol`.

The Markdown file is the description body. The shared script appends an exact, terminal OpenZeppelin proposer
restriction before computing the description hash and pinned proposal ID.

`DGP-NNN` is a repository convention, not an onchain Governor requirement.

| Proposal | Status | Summary |
| --- | --- | --- |
| — | Candidate only | Rewarder V2 implementation imported; awaiting production inputs and a dictated DGP. |
