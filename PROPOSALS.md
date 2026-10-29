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
- **Rotate the Microsoft client secret inside the pipeline** (2026-10-29, #17, #6): today a rotation is by hand:
  a new Entra secret, pasted into `FLEET_MICROSOFT_CLIENT_SECRET`, then the `signin-secrets` job. Proposal: a
  scheduled job that does it all, well before expiry. It authenticates to Entra with the job's GitLab OIDC token
  (a federated credential on an app allowed `addPassword`/`removePassword` on `seatrials-web` only, no secret).
  It confirms the new secret with a client-credentials token request, installs it, then removes the old one.
  It needs a place for the new value: the job can write the project variable only with a token that can also
  read every variable, so the design must settle that first.
- **A sign-in smoke test with a credential pair** (2026-10-29, #17): `deploy/checks.sh signin` checks the sign-in
  config down to each IdP's authorize URL, without a person. A deeper check would sign in with a tenant
  credential pair held as a file variable (`seatrials login` plus `ping`; `served_by` names the tenant). That
  waits for the client to generate on main (#14).
- **The test stage proves the cluster is the render** (2026-10-29, #17): after `apply`, `deploy/diff.sh` should
  report no difference. Needs a check on seatrials for diffs that never settle (defaults filled in by the
  server) before it can be a gate.
- **An apply deploys rebuilt images** (2026-10-29, #17): the operator renders every image as `:local`, so a
  rebuilt image leaves the pod template unchanged and the apply does not roll it out. Render the `fp-` (or
  digest) tag instead; pinning by release line (#8) covers release images by digest.
- **Create and initialise a trial cluster from the pipeline** (2026-10-29, #17): `cluster/create.sh` and
  `deploy/init.sh` still run where someone has gcloud. A new trial's CA would then go straight into the
  project's variables, never through a laptop.
- **A dry run on every push to main** (2026-10-29, #17): the pipeline runs from the web, the API or a
  schedule. A GitHub webhook to a GitLab pipeline trigger, whose token is held where agents cannot read it,
  would show each commit's diff before anyone asks.

## Promoted / declined
