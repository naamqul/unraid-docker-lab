# Agent instructions

This repository is the source of truth for deployable Unraid, Compose, Caddy,
and Forge configuration. The private
[`naamqul/homelab-agent-docs`](https://github.com/naamqul/homelab-agent-docs)
repository is the source of truth for architecture, inventory, dependencies,
access policy, runbooks, and project handoffs.

Before changing infrastructure:

1. Preserve unrelated changes and verify the live authority.
2. Read the relevant records and runbook in `homelab-agent-docs`.
3. Prefer Komodo for registered stack operations.
4. Keep secrets out of both repositories.

Before declaring work complete, run the documentation-impact check in
`homelab-agent-docs/docs/agent-contract.md`. Net-new, removed, renamed, or
materially changed services always have documentation impact. Update the docs
in the same task or link a `documentation-drift` issue with the exact required
change and verification evidence.
