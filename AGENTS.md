# Agent instructions

This repository is the source of truth for deployable Unraid, Compose, Caddy,
and Forge configuration. The private
[`naamqul/homelab-agent-docs`](https://github.com/naamqul/homelab-agent-docs)
repository is the source of truth for architecture, inventory, dependencies,
access policy, runbooks, and project handoffs.

Forge is a trusted administrative workstation. Interactive harnesses run
directly as `luqmaan`. Recommend a standalone service account only when a real
unattended daemon would benefit from its own runtime identity.

Before a net-new task or the next checkpoint of a larger workstream:

1. Read the relevant `homelab-agent-docs` records and runbook.
2. Confirm the requested outcome and give a concise plan.
3. Identify privileged, disruptive, external-control-plane, or irreversible
   actions and get task-level approval before executing them.
4. Prefer an equally effective non-privileged approach when one exists.

An approved plan covers its disclosed commands, including sudo/SSH use and
listed container recreations. Prepare and validate everything possible before
downtime, then give a just-in-time heads-up or ask for a go/no-go based on
likely impact. A new or broader impact needs new approval. Never restart or
shut down Forge, the Arc Docker daemon, or Arc without a final explicit
go-ahead. Diagnosis alone does not authorize a restart.

Operational defaults:

- Use Komodo for Arc deployment and container lifecycle management. Direct
  `docker exec`, `docker inspect`, and log reads are normal diagnostics.
- Do not install or upgrade packages, images, firmware, or dependencies unless
  necessary to the approved task and explicitly approved.
- Prefer an upstream `stable` or `lts` image channel when offered; otherwise
  use the documented `latest` channel. Pin a numbered tag only for a stated
  compatibility, migration, reproducibility, or regression reason.
- Do not pull and redeploy a moving tag without approval.
- Treat Git as the reconciled source of truth: declarative changes normally
  start here; exploratory live work is acceptable but must be codified before
  completion.
- Preserve unrelated changes. Keep secrets and mutable state out of Git, and
  avoid exposing credentials or unintended personal data to model providers.
- New Arc web services normally include Caddy HTTPS, Homepage, authentication
  review, health checks, backup consideration, verification, and documentation.
- Removing a service never implies deleting its data.
- A finite approved job may remain in tmux. New daemons, timers, cron jobs, or
  indefinite recurring work require explicit approval.
- Ordinary task-related documentation commits and pushes are implicit. Propose
  a branch/PR when risk, scope, experimentation, or review value warrants it.
- Keep the Git author as Luqmaan and add an `Assisted-by:` trailer naming the
  harness/model when practical.

Before declaring work complete, run the documentation-impact check in
`homelab-agent-docs/docs/agent-contract.md`. Net-new, removed, renamed, or
materially changed nodes, services, dependencies, networking, access, or
operations always have documentation impact. Update the docs in the same task
or create/link a `documentation-drift` issue containing the exact required
change and verification evidence.
