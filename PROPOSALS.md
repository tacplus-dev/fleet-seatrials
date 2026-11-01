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
- **What #8 needs besides the releases** (2026-10-29, #8, tacplus-dev/tacplus#180, #213 there): `version:` in
  `fleet.yaml` is refused before tacplus 2.6.0, so the fleet's floor moves from 2.2 to 2.6 (past #1's 2.4). The
  service release images are private packages: the `fleet build` that relocks needs `GH_TOKEN` with
  `read:packages` (the looper's token has none, so the relock runs in the pipeline or with a token added for
  it), and the cluster needs an image pull secret from a read-only packages token, held in GitLab, installed in
  `schematic` and in each tenant namespace nsproxy creates (nsproxy copying it, or the operator rendering it).
  Making the packages public would remove both, but the repos are private by choice.
- **Create and initialise a trial cluster from the pipeline** (2026-10-29, #17): `cluster/create.sh` and
  `deploy/init.sh` still run where someone has gcloud. A new trial's CA would then go straight into the
  project's variables, never through a laptop.
- **A dry run on every push to main** (2026-10-29, #17): the pipeline runs from the web, the API or a
  schedule. A GitHub webhook to a GitLab pipeline trigger, whose token is held where agents cannot read it,
  would show each commit's diff before anyone asks.
- **`schematic-operator init` stops writing a `tls` block into services/kernel.yaml** (2026-10-29, #22): `WriteServices`
  (tacplus-dev/operator `pkg/bootstrap/example.go`) puts a fresh self-signed P-384 key and a one-hour certificate
  (CN=mock-token) into the kernel.yaml it creates, and `buildKernelConfigProto` only checks that the key parses: no
  rendered config carries it. The kernel's TLS is the cluster PKI in crypto.yaml. A fleet that commits its
  services/*.yaml, as this one does, commits a private key for nothing, which is how #22 happened. Proposal: drop
  the block from the template and `TLSSourceConfig` (accepting and ignoring it in old files), in the operator.
- **Carry the Let's Encrypt state to the `tacplus` cluster, no new order** (2026-10-29, #24, design in its
  comments): the move off `seatrials` (#4) must not spend the nearly exhausted duplicate-certificate budget.
  letsencrypt already restores from its `LetsEncryptCert` row on start (same hostname set, no ACME call), so
  only the way in is missing. Proposal: a read-only `letsencrypt export` run as a one-shot Job (the live pod is
  untouched) into the protected file variable `LETSENCRYPT_STATE`. A `seed_file` in letsencrypt's config is
  adopted only when Stratum has no row, then written through the normal record path. A `cert-serial` check
  proves the same serial before DNS moves. The current certificate enters its renewal window around
  2026-12-24, so the move must be done by then.
- **Set up the deploy pipeline on GitLab in two phases, the cluster part on `tacplus`** (2026-11-01, #18, design
  in its comments): #18's setup (WIF, deploy runner, protected environments, variables) grants on and diffs
  against the `seatrials` cluster, which ROADMAP.md says was deleted 2026-10-29. Proposal: the hub does now what
  needs no cluster (the WIF pool and provider, `seatrials-deploy` with the Cloud Build, bucket and AR grants, the
  runner, the environments, the variables, `.gitlab-ci.yml`), proven by a pipeline whose tools, checks, images
  and generate are green. The cluster grants, the `diff` dry run and the letsencrypt guard proof follow on
  `tacplus` after #4, with `ci_kube`'s defaults and the scripts' kube-context checks moved to it. #27 waits on
  phase 1 only.

## Promoted / declined
- 2026-10-29 agent decision Service images for arm64, amd64 behind a setting: on ROADMAP.md (Next), at Jody's request (#23)
