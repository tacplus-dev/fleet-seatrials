# Proposals: fleet-seatrials

Written by loopers. Each proposal: what, why, links. Jody promotes accepted ones into ROADMAP.md (via an agent);
the looper then marks it `promoted` or `declined` here with the date.

## Open
- **<title>** (<date>, <issue/run link>): <what and why>
- **The client generates against the fleet's locked contracts** (2026-10-28, nightly scan, #14): `client/`'s
  `depends` resolve through the registry at `latest` (each contract's main), not at the commits in `fleet.lock`, so
  the client can call a contract newer than the one deployed, and it broke when those mains raised their floor to
  2.4. Proposal: a fleet's client (`kind: client` inside a fleet repo) resolves `depends` from `fleet.lock`
  (`contract_commit`), or from `build/proto`, as the README already says. That is new tacplus behaviour
  (tacplus `pkg/runner/depends.go`), so it needs design. Pinning by release line (#8, tacplus-dev/tacplus#180)
  narrows the drift but doesn't remove it.

## Promoted / declined
