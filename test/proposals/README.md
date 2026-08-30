# Proposal tests

Each `DGP-NNN` deployment script has a paired `DGPNNN/Proposal.t.sol` test here. Tests must check the exact payload and
the intended postconditions at a pinned Robinhood Chain block through an archive RPC. They bind both the block number
and hash, exercise a full live-Governor proposal/vote/execution lifecycle, and call the script's live execution
verifier after execution.
