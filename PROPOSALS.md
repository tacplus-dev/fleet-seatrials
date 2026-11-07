# Proposals: fleet-seatrials

Written by loopers. Each proposal: what, why, links. Jody promotes accepted ones into ROADMAP.md (via an agent);
the looper then marks it `promoted` or `declined` here with the date.

## Open
- **<title>** (<date>, <issue/run link>): <what and why>
- **The fleet's gateway behind the Gateway on the reserved address `gateway`** (2026-11-06, #39; split out by
  the hub, 2026-11-05, which files the roadmap item once Jody says where TLS ends): the operator renders the
  gateway as a `type: LoadBalancer` Service, a regional passthrough load balancer that the global address
  `gateway` (34.54.57.155, tacplus-dev/cloud#13) cannot back. The recommendation on #39: tacplus-dev/cluster
  owns one `gke-l7-global-external-managed` Gateway naming `gateway`, each namespace (seatrials, the test IdP)
  attaches HTTPRoutes, tacplus-dev/operator renders the gateway's Service as its backend (NEG, `appProtocol`
  HTTP/2) instead of a LoadBalancer, and #35's certificate goes on the Gateway, with `idp.test.tacplus.dev`
  covered too. Until then `operator.yaml` keeps `external_ip: 146.148.80.132`, so on `dev` the `-lb` Service
  stays pending instead of taking an ephemeral public IP.
- **Clear the security exceptions before they expire, 2026-12-04** (2026-11-04, #36): the security job's first
  run accepted 28 ids in `security-exceptions.yaml`, none with a fix this repository can take. 25 are the
  operator pin's (#11, waiting on #1 and tacplus-dev/operator#1): moving the pin past operator#9 and #10 clears
  them. lego 5.6.0 carries GO-2026-5932 (x/crypto openpgp): bump it to the first release with the fix and drop
  the entry. Trivy's and gitleaks' (6860, 6866, GO-2025-3922) are cleared: #40 builds them from source with the
  fixed dependencies (`ci/tools.sh`, `go_build_fixed`).
  On 2026-12-04 every pipeline fails until each is cleared or decided again. Why: an expired entry fails the
  job, by design. A warning a week before expiry, in the job's summary, would make that date visible sooner.
- **Move the CI image to the rebuilt line, before 2026-11-19** (2026-11-06, #40): `build:2.3` (Debian 13.7)
  carries ImageMagick deb13u13 (CVE-2026-109258, -109260, -109262, -109263, -109268, -116149) and apt 3.0.3
  (CVE-2026-109518), accepted until 2026-11-19 (as tacplus-dev/cluster#8). When tacplus-dev/tacplus#283 rebuilds
  the line's images, move every `image:` of `ci/*.gitlab-ci.yml`, `.github/workflows/security.yml` and
  `images/tacplus-build.Dockerfile`'s `BUILD_IMAGE` to the rebuilt one and drop the seven entries; build:2.5
  carries the same CVEs today (cluster#8), so 2.5 alone does not clear them.
- **Drop the fixed-dependency overrides when the tools' releases take them** (2026-11-06, #40): `ci/tools.sh`
  builds opa, gitleaks, osv-scanner and Trivy with klauspost/compress v1.20.3, gitleaks also with brotli v1.2.8
  and xz v0.5.17, because no release of theirs requires them yet. Each override is checked on every build
  (selected version and module hash); once a tool's release requires the fixed version, bump the tool and drop its
  override (and build it with `go_install` again, if it needs none).
- **Trivy scans the CI image by tag** (2026-11-04, #36): the security job scans
  `ghcr.io/tacplus-dev/tacplus/build:2.3`, the tag the jobs run, which moves with each 2.3 patch. Pinning the
  jobs' `image:` by digest would make the scanned image and the one the jobs run provably the same, and fit
  `decisions/deterministic-deployments-2026-11-02.md`. Each tacplus build image patch would then be a commit
  here.
- **Move the test IdP's Keycloak before its exceptions expire, 2026-12-06** (2026-11-07, #41): the security job
  now scans every container of `test-idp/*.yaml` (Jody's decision in #41), and Keycloak 26.8.1-2 has four HIGH CVEs
  no Keycloak release fixes yet (26.8.2-0, 2026-11-05, has the same): Guava CVE-2026-102554 (fixed in Guava
  33.7.2), sqlite-libs CVE-2026-119373 and CVE-2026-119586 and OpenJDK CVE-2026-91403 (Red Hat 9.8, no fix yet).
  They are accepted until 2026-12-06. When a Keycloak release ships the fixes, move `test-idp/keycloak.yaml` to it
  by tag and digest, run `test-idp/local.sh`, and remove the four entries; otherwise every pipeline fails from
  2026-12-06 until they are decided again.
- **Scan the fleet's own service images** (2026-11-07, #41): the security job scans the images this repository
  deploys from pinned manifests (`test-idp/*.yaml`), not the service images `images/build.sh` builds and the
  operator renders (`deploy/bootstrap/services/*.yaml` name them by a `:local` tag, not a digest). Scanning them
  would need the digests the `images` job builds as Trivy targets, once they are built on Cloud Build (#23).
  Why: they are what seatrials runs. Whether they belong in this scan was left open in #41.
- **The checks job's secrets scan reads one commit** (2026-11-04, #36): every child job fetches this repository
  at depth 1, so `ci/secrets.sh` in `checks` sees only the deployed commit's history, not the whole history it
  says it scans. The security job fetches the whole history (`FLEET_FETCH_HISTORY=1`) and runs gitleaks on it.
  Either drop `ci/secrets.sh` from `checks` in the pipeline (GitHub's `secrets` workflow still runs it, with the
  full history) or set the same variable there.
- **Compare each security run with the last** (2026-11-04, #36): looper-scan publishes each run's findings as
  the next run's baseline and lists the new ones. `ci/security.sh` reports every finding each time. A baseline
  in the GitLab project's package registry, as looper-scan's `report` does, would show what changed overnight.
- **The certificate's follow-ups** (2026-11-05, #35; tacplus-dev/roadmap
  `decisions/certificates-by-pipeline-2026-11-03.md`). The pipeline owns the certificate now (`ci/cert.sh`, the
  `cert` stage, the daily schedule), by the interim route of #35's design: the version is installed as the job's
  `crypto.yaml` `pki.edge_tls[0]`, which the pinned operator (3d0e4b7) serves in `CERT_CHAIN` mode once
  `operator.yaml` has no `tls`. What is left:
  - **Move the gateway pin past gateway#25 (0b0743f)** and the operator pin past operator#21 (4dc0a3d), then drop
    letsencrypt from `fleet.yaml` and `fleet.lock` (relock) and ask for its registry entry's removal. The pinned
    gateway (32cd7a6) still imports `LetsEncryptState`, so the closure keeps letsencrypt's contract until then.
    Both new pins declare the tacplus 2.5 floor, and this fleet is on 2.2, so this waits on #1.
  - **Reference the version in the uni-config** once #28 (operator#17) lands, in place of `edge_tls[0]` in
    memory: the gateway's part of the uni-config names `tls-seatrials` and the version.
  - **The gateway's `root_ca`**: in `CERT_CHAIN` mode the operator also hands the gateway the fleet's private
    root (`pki.root_ca`). Check what the gateway uses it for; it must not be advertised as the edge's anchor.
  - **The acceptance on the cluster**: a run forced against Let's Encrypt's staging gives a new version, a new
    render and an apply, and every gateway pod serves the new serial (`openssl s_client` to each pod, before and
    after) with its `restartCount` and start time unchanged. It needs the first deploy on `dev` (#39, #4) and
    the challenge zone's delegation (tacplus-dev/cloud#13's cutover).
  - **lego and the challenge zone**: `GCE_ZONE_ID` names the zone, so lego shouldn't need to list the project's
    zones (the deploy account has `dns.admin` on that zone only, tacplus-dev/cloud#6). Untried until the first
    `cert` run.
- **The functional suite's RPC items without waiting for the client** (2026-11-03, #17, #14): most of
  `deploy/e2e.yaml`'s items (tenants, public RPCs, records, streams, kernel restart) wait on #14, because they
  would call the fleet through its generated client. The gateway already answers JSON over HTTP (oauth's
  `Auth/*` calls in `deploy/checks.sh` and `test-idp/testidp.py`), and the test IdP's sign-ins give a kernel
  session with no person. Proposal: write those items in `testidp.py`'s style, as JSON calls with that session
  (tenantecho's `Ping` names `served_by` and `caller_namespace`, for routing and cross-tenant refusal). They
  could then run as soon as #27 and #4 are done, not after #14. It needs the gateway's JSON route for a
  tenant-owned service and the records API's JSON shape confirmed, which nothing here records yet.
- **A login-continuity gate around every deploy** (2026-11-03, #17; Jody, 2026-11-01, "later"): before the
  deploy, a fixed set of long-lived test identities on the test IdP are signed in, linked and members of
  tenants. Their XIDs, links, memberships and live sessions and refresh tokens are recorded. After the deploy,
  each signs in again and must land on the same account. Its existing sessions and refresh tokens must still
  work, unless the deploy declares itself session-breaking (a trust-domain change, #16), in the deploy, not
  discovered. A failure is a failed deploy. Design questions: where the recorded state lives between the two
  jobs (it holds refresh tokens, so not an artifact), how a deploy declares itself session-breaking, and the
  identities' setup through `PersonalIdentity`/`TenantAdmin`, which waits on the same client as the suite. It
  isn't needed for the SeaBeam gate.
- **Microsoft sign-in without a client secret** (2026-11-03, #17, #6): Jody wants Entra federated credentials,
  so the Microsoft provider has no secret to rotate. That needs oauth to authenticate to Entra with a client
  assertion (a JWT that oauth, or kernel's issuer, signs, and that a federated credential on `seatrials-web`
  trusts) in place of `client_secret`. It's an oauth change (tacplus-dev/oauth), with a design for the
  assertion's issuer and subject. The issuer must be publicly discoverable, which seatrials.tacplus.dev is.
  Until then, the secret is rotated by hand (docs/deploy-pipeline.md).
- **The applied render's digest is the uni-config record's** (2026-11-03, #34, #28): `apply` now runs by
  itself and applies only the render whose digest `diff` recorded. Until #28, that digest is a SHA-256 of
  `schematic-operator apply --dry-run`, recomputed in `apply` before the operator renders again for the real
  apply. When #28 lands, `diff` should record the uni-config record's digest, and `apply` should apply that
  record by digest (the operator's `--bundle`, say), so the check and the apply read one artifact and don't
  render twice. That record holds secrets, so it can't be a job artifact as the digest is: the design must
  say where it lives between the jobs.
- **A service's fingerprint covers the build image it is built in** (2026-11-02, #33): a service image's
  `fp-` tag covers the compiler's MAJOR.MINOR, its own commit, its inputs_digest and the platforms, but not the
  build image's fingerprint (`ci/tacplus-build:fp-<hash>`, #33). A new toolchain, launcher or tacplus patch
  therefore rebuilds no service that is already built, and its image keeps the old launcher. Proposal: add the build
  image's fingerprint to each service's. It is one line in `images/build.sh`, but it rebuilds all 13 services on
  every build-image change, so the cost needs Jody's call.
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
- **Initialise a trial's CA from the pipeline** (2026-10-29, #17; narrowed 2026-11-05, #39: the cluster is
  tacplus-dev/cloud's `dev`, and `cluster/` is gone): `deploy/init.sh` still runs where someone has the tools.
  A new trial's CA would then go straight into the project's variables, never through a laptop.
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
- **The test IdP's follow-ups** (2026-11-01, #27): (1) Apple's form post: oauth posts `response_mode=form_post`
  only for a provider with `apple` set, which needs a .p8 key, so `Test Apple` is plain OIDC. Neither the form
  post nor the name on first sign-in (the `user` field) is emulated. A Keycloak form-post realm, plus an oauth
  `apple` mode with a client secret, would cover both. (2) The seeds are written with a Maintainer project access
  token that can read every variable. A narrower writer (a GitLab feature, or a job in a separate project) would
  remove it. Until then the hub revokes it after the first run. (3) Keycloak's signing keys rotate when a
  realm's settings change (the realm is recreated). Importing fixed keys derived from the seed would keep them.
  (4) `test-idp-signin` on a schedule, nightly beside the dry run, once it is green.
- **One signing path for the reader token** (2026-11-02, #30): `.github-reader` asks Cloud KMS as the job's
  federated principal, then, on a 401 or 403, as `fleet-seatrials-reader@`. Because the first dry run's error was
  dropped, nobody knew which path KMS accepts, so both are there. Once a dry run's log shows which one signs,
  keep that one: drop the other path from the block, and drop its binding (the key's principalSet binding, or the
  service account and its two bindings). Then every job makes one KMS call and has one binding fewer.
  If it is the service account, tacplus-dev/build and tacplus-dev/looper probably need the same change.

## Promoted / declined
- 2026-10-29 agent decision Service images for arm64, amd64 behind a setting: on ROADMAP.md (Next), at Jody's request (#23)
- **`ci_gcp` fails silently too** (2026-11-02, #31): every job calls `ci/lib.sh`'s helpers in an `&&` list, where
  bash turns errexit off inside the functions, so a failed step inside one is ignored unless the function returns
  on it. #31 made `ci_kube` do so (dry run 2 ran `test-idp/signin.sh` with no kube context). `ci_gcp` still
  ignores a failed `create-cred-config` or `gcloud auth login` and goes on as no one: it should return on each,
  with gcloud's error, as `ci_kube` now does, with a stub test in `ci/lib_test.sh`.
