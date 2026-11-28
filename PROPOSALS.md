# Proposals: fleet-seatrials

Written by loopers. Each proposal: what, why, links. Jody promotes accepted ones into ROADMAP.md (via an agent);
the looper then marks it `promoted` or `declined` here with the date.

## Open
- **<title>** (<date>, <issue/run link>): <what and why>
- **Dev rolls to each green main release by digest: the roll itself** (2026-11-26, #82; tacplus-dev/looper#252,
  tacplus-dev/roadmap `decisions/agentic-dev-flow-2026-11-25.md` step 8, item 12, D4). Built so far:
  - The `releases` job (`ci/releases.sh plan`) reads and checks every record, forward only by ancestry, and checks
    each release against tacplus's own release (D4).
  - `apply` refuses an older set and records the deployed one in the ConfigMap `seatrials-releases`.

  Left, once tacplus-dev/tacplus#981 (lock at a commit and image) and tacplus-dev/cloud#115 (the release registry's
  read) are done:
  - `releases` writes the lock from the records' commits and images, and every later job renders from that
    artifact, so a record that moves mid-pipeline cannot split `diff` from `apply`.
  - It copies each release image by digest into `seatrials/schematic/<service>` and writes
    `deploy/bootstrap/images.yaml` (`image_digests`), and it checks that the image is arm64.
  - `images/build.sh` builds no image for a rolled service.
  - `ci/fleet_lock_test.sh` moves from "at its tag" to "at its record".
  - `ci/closure_test.sh` runs at the rolled commits against tacplus's release.

  tacplus-dev/looper#262 adds the record's `tacplus` line, this project's read of the packages, and a trigger
  after each main release. Also open:
  - **Rollback.** Forward-only leaves "a revert on main and the next release" as the only rollback; a Jody-only
    override (a protected variable naming `<service>@<commit>`) would add a manual one.
  - **Staleness.** An alarm when the deployed set is older than two nightly releases, since a held fleet only
    fails red.
  - **Compiler.** The fleet's own compiler (`images/pins.yaml`) could follow tacplus's main release instead of
    v2.6.14.
- **Build the fleet's gateway with `tacplus fleet gateway`** (2026-11-24, #73; tacplus-dev/tacplus#195): pin gateway
  `"0.3"` (v0.3.0, released 2026-11-23; it serves `/-/apps/<service>/` and `/-/apps.json`), move to tacplus 2.7 (the
  pins, the CI image, `build.lock`), add `fleet.yaml`'s `launcher:` and re-lock, then build the gateway image from the
  lock (its `gateway:` section committed in `fleet.lock`). That image is the one seatrials deploys, pushed as
  `schematic/gateway` with its digest checked against the lock, and `images/build.sh` stops building gateway.
  `tacplus fleet gateway --check` is the gate. Why: #195's acceptance (gateway-per-fleet, a merged webapp) is checked
  on this fleet, whose tenantecho contributes the webapp `web` (Echo). Blocked on tacplus v2.7.0 (tacplus#954,
  #955): `fleet gateway` is only on tacplus main. Open (design on #73): the step builds for the machine's arch,
  but the fleet runs arm64; gateway's Rust build needs more than 4 GB; whether `--check` can run without Docker
  as a land gate; which launcher commit to use (lock v0.1.0 0e139ca, the build image's c575e14); whether
  gateway 0.3 lands first on 2.6 through `images/build.sh`.
- **The fleet's gateway behind the Gateway on the reserved address `gateway`** (2026-11-06, #39; split out by
  the hub, 2026-11-05, which files the roadmap item once Jody says where TLS ends): the operator renders the
  gateway as a `type: LoadBalancer` Service, a regional passthrough load balancer that the global address
  `gateway` (34.54.57.155, tacplus-dev/cloud#13) cannot back. The recommendation on #39: tacplus-dev/cluster
  owns one `gke-l7-global-external-managed` Gateway naming `gateway`, each namespace (seatrials, the test IdP)
  attaches HTTPRoutes, tacplus-dev/operator renders the gateway's Service as its backend (NEG, `appProtocol`
  HTTP/2) instead of a LoadBalancer, and #35's certificate goes on the Gateway, with `idp.test.tacplus.dev`
  covered too. (tacplus-dev/cloud#21 since chose a TCP proxy, TLS passed through, and gave the test IdP port 8443 of
  the address: #27 follows it, 2026-11-09.) Settled for the gateway itself (hub, 2026-11-07, #1): it is a standalone
  NEG behind the TCP proxy load balancer (tacplus-dev/operator#22, tacplus-dev/cloud#21), the operator refuses
  `external_ip`, and #1 drops it from `operator.yaml`. The shared Gateway for the other namespaces is still open.
- **Room for gateway's Rust build on Cloud Build** (2026-11-10, #23): on the CI image 2.6.4 (2.6.12 since #50, untried), one rustc for gateway's
  generated crate `gateway-model-types` needs more than 4 GB (the looper's container limit killed it, and with one
  job and one codegen unit it thrashed there). The service builds ask for `E2_HIGHCPU_8`, 8 GB, with cargo running
  up to 8 jobs; whether that is enough is unknown until the first pipeline's `images` job builds gateway. If it
  runs out of memory: give the Rust builds `E2_HIGHCPU_32` (32 GB; `--machine-type` for Rust services only in `images/build.sh`,
  rather than for all 13, which costs more) or a `CARGO_BUILD_JOBS` low enough to fit.
- **Clear the security exceptions before they expire, 2026-12-04** (2026-11-04, #36): the security job's first
  run accepted 28 ids in `security-exceptions.yaml`, none with a fix this repository can take. 25 are the
  operator pin's (#11): #1 moved the pin to operator v0.1.0 (a17d507), past operator#9 and #10, and #11
  removed 24 of them (govulncheck finds none in it any more); GO-2026-5932, left for the CI image's gh and buildx, went with #72 (CI tooling, reported, never failing). Trivy's and gitleaks' (6860, 6866, GO-2025-3922) are cleared: #40 builds them from source with the
  fixed dependencies (`ci/tools.sh`, `go_build_fixed`), and so is lego 5.6.0's GO-2026-5932 (x/crypto openpgp):
  #52 built it with x/crypto v0.59.0, which lego v5.7.0 requires itself (#71).
  The 2026-12-04 deadline is gone with it; the deployed images' entries expire from 2026-12-06, when every pipeline
  fails until each is cleared or decided again. Why: an expired entry fails the
  job, by design. A warning a week before expiry, in the job's summary, would make that date visible sooner.
- **Drop ci/tools.sh's otel and gorilla/websocket overrides once releases take them** (2026-11-24, #71): #68
  builds `bin/osv-scanner` (v2.7.0; v2.7.1, the latest, still requires otel v1.45.0) and `bin/trivy` (v0.76.2, the
  latest, otel v1.46.0) with otel v1.47.0 (GO-2026-6974), and `bin/lego` (v5.7.0, the latest, gorilla/websocket
  v1.5.3) with gorilla/websocket at an untagged commit (GO-2026-6278: no release has the fix). When osv-scanner,
  trivy and lego releases require the fixes, move their pins and drop `otel_fixes`, `otel_sdk_fixes` and
  `websocket_fix`. Why: a pseudo-version of a dependency is one more pin to watch, and a release is what upstream tests.
- **Move the CI image to a line image whose gh and docker-buildx have the fixed x/crypto**
  (2026-11-09, #43): the CI image is `build:20261123-ef62327` by digest (#64, tacplus's 2.6 build image rebuilt on current Debian; every `image:` of `ci/*.gitlab-ci.yml`,
  `.github/workflows/security.yml` and `images/tacplus-build.Dockerfile`'s `BUILD_IMAGE`; `ci/workflows_test.sh`
  checks they are one image), and `build.lock` pins that image (#42; `ci/build_lock_test.sh`). Its `gh` and
  `docker-buildx` carry x/crypto v0.58.0 (GO-2026-5932: CI tooling, reported and never failing since #72, so no
  longer a deadline). When a line image moves them, move the four references and `build.lock` to its tag and digest.
  Each build image patch is now a commit here: no tag moves under the jobs.
- **Drop the fixed-dependency overrides when the tools' releases take them** (2026-11-06, #40): `ci/tools.sh`
  builds opa, gitleaks, osv-scanner and Trivy with klauspost/compress v1.20.3, gitleaks also with brotli v1.2.8
  and xz v0.5.17, and lego with x/crypto v0.59.0 (#52), because no release of theirs requires them yet. Each override is checked on every build
  (selected version and module hash); once a tool's release requires the fixed version, bump the tool and drop its
  override (and build it with `go_install` again, if it needs none).
- **Move the test IdP's Keycloak before its exceptions expire, 2026-12-06** (2026-11-07, #41): the security job
  now scans every container of `test-idp/*.yaml` (Jody's decision in #41), and Keycloak 26.8.2-3 (2026-11-19, the
  pin since #59) has four HIGH CVEs no Keycloak release fixes yet: Guava CVE-2026-102554 (fixed in Guava
  33.7.2), sqlite-libs CVE-2026-119373 and CVE-2026-119586 and OpenJDK CVE-2026-91403 (Red Hat 9.8, no fix yet).
  They are accepted until 2026-12-06. When a Keycloak release ships the fixes, move `test-idp/keycloak.yaml` to it
  by tag and digest, run `test-idp/local.sh`, and remove the four entries; otherwise every pipeline fails from
  2026-12-06 until they are decided again. Nightly scan, 2026-11-15: Red Hat's CVE data
  (`access.redhat.com/hydra/rest/securitydata/cve/<id>.json`) marks `java-21-openjdk` **Will not fix** for
  CVE-2026-91403 and `sqlite` still Affected for CVE-2026-119373 and CVE-2026-119586, so no Keycloak rebuild on
  Red Hat 9 will clear the OpenJDK one: on 2026-12-06 it has to be decided again as a longer acceptance, or the
  test IdP moves to a Keycloak image on another base. Keycloak 26.8.2 (26.8.2-0 to -3 on quay.io) is still the
  latest release and ships the same Guava. Nightly scan, 2026-11-20 (#59): 26.8.2-3 is rebuilt on OpenJDK
  1:21.0.13.1.2, which fixes CVE-2026-114938 to 114942 (26.8.1-2's JDK failed the gates on them), not CVE-2026-91403;
  it also has sqlite-libs CVE-2026-119374 and 119379, with no fix, which the policy does not fail on.
- **Scan the fleet's own service images** (2026-11-07, #41): the security job scans the images this repository
  deploys from pinned manifests (`test-idp/*.yaml`), not the service images `images/build.sh` builds and the
  operator renders (`deploy/bootstrap/services/*.yaml` name them by a `:local` tag, not a digest). Scanning them
  would need the digests the `images` job builds as Trivy targets, once they are built on Cloud Build (#23).
  Why: they are what seatrials runs. Whether they belong in this scan was left open in #41.
- **govulncheck on the client, once it generates** (2026-11-17, nightly scan, #14): the build's security report
  says `govulncheck: client: not analyzed (govulncheck: loading packages: )`, and `govulncheck ./...` in `client/`
  fails the same way: `cmd/seatrials/main.go` imports `client/tacplus/...`, which is generated and not committed.
  `ci/security.sh` runs govulncheck only on the pinned binaries, so only OSV-Scanner checks `client/go.mod` (no
  issues on 2026-11-17), by module and not by reachability. Once #14 lets the client generate, the security job
  could run `tacplus build` in `client/`, then `govulncheck ./...` with `security-exceptions.yaml` enforced, as it
  does for the binaries. Why: the client is what a person runs against the fleet, and nothing checks its
  reachable code today.
- **The checks job's secrets scan reads one commit** (2026-11-04, #36): every child job fetches this repository
  at depth 1, so `ci/secrets.sh` in `checks` sees only the deployed commit's history, not the whole history it
  says it scans. The security job fetches the whole history (`FLEET_FETCH_HISTORY=1`) and runs gitleaks on it.
  Either drop `ci/secrets.sh` from `checks` in the pipeline (GitHub's `secrets` workflow still runs it, with the
  full history) or set the same variable there.
- **The gates' security job runs the build's SAST and config checks too** (2026-11-18, nightly scan, #54, #55,
  #56, #57): the build pipeline's report (looper-scan) runs CodeQL and Trivy's config checks and fails the policy on
  four findings at c37ef56, while the gates' `ci/security.sh` (OSV-Scanner, govulncheck, gitleaks, Trivy on images)
  passed on the same commit (build pipeline 3082147135). So a land can't see a policy failure that only the nightly
  report shows. Running `trivy config` on `test-idp/` and `images/`, and CodeQL or semgrep on `test-idp/*.py`, in
  `ci/security.sh` with `security-exceptions.yaml` enforced would close the gap. The cost is CodeQL's run time in
  the gates. Why: a finding should fail the commit that brings it, not a scan the next night.
- **Compare each security run with the last** (2026-11-04, #36): looper-scan publishes each run's findings as
  the next run's baseline and lists the new ones. `ci/security.sh` reports every finding each time. A baseline
  in the GitLab project's package registry, as looper-scan's `report` does, would show what changed overnight.
- **The certificate's follow-ups** (2026-11-05, #35; tacplus-dev/roadmap
  `decisions/certificates-by-pipeline-2026-11-03.md`). The pipeline owns the certificate now (`ci/cert.sh`, the
  `cert` stage, the daily schedule), by the interim route of #35's design: the version is installed as the job's
  `crypto.yaml` `pki.edge_tls[0]`, which the pinned operator (3d0e4b7) serves in `CERT_CHAIN` mode once
  `operator.yaml` has no `tls`. What is left:
  - **Ask for letsencrypt's registry entry's removal.** #1 moved the fleet to gateway 0.2 and operator v0.1.0
    (both past gateway#25 and operator#21) and dropped letsencrypt from `fleet.yaml` and `fleet.lock`.
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
- **A narrower writer for generated secrets** (2026-11-03, #17): `init-secrets` wrote variables with a
  Maintainer token (`FLEET_INIT_TOKEN`), which could read every variable of the project; a writer that can't
  read was the ask. Done (2026-11-10, #44): it adds versions to Secret Manager as `seatrials-init-secrets`
  through WIF, which may add and list versions of its two secrets and read none (tacplus-dev/cloud#28).
- **The fleet's key material in one secret** (2026-11-06, #17; 2026-11-10, #44): the CA and the cluster PKI are
  `fleet-crypto-seatrials` in Secret Manager, about 23,000 bytes for this topology, which fits (Secret Manager
  takes 64 KiB), so GitLab's 10,000-character limit and the split into parts are gone with #44. The lasting
  improvement is still the operator's: keep only the root CA as the stored secret and derive the cluster PKI
  from it in a stable way, so a topology change needs no new secret. That's an operator change, best settled
  by the uni-config design (tacplus-dev/operator#17, #28).
- **Rotating the fleet's CA** (2026-11-10, #44): `init-secrets` generates the pair once and skips it after. A
  rotation (a new version of both, rendered and applied together) has no job yet; today the hub disables both
  secrets' versions and runs `init-secrets`, and every client trusting the old `ca.pem` breaks. A designed
  rotation, with the old and new CA trusted side by side for a while, needs the operator's support.
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
  every build-image change, so the cost needs Jody's call. Since #56, `changed` builds the first service of each
  language in a new build image, so a broken one fails the `images` job. The other services still keep their
  old images until they change.
- **The build image's own build checks it starts as its user** (2026-11-23, #56): 79dcdd9 switched
  `images/tacplus-build.Dockerfile` to `USER build` on the belief that the base image had that user. It had none,
  and `docker build` does not check: only the first service step on Cloud Build would have failed, after
  the build image was pushed. `images/build_test.sh` now checks that the Dockerfile creates the user, but
  it reads text. Proposal: a step in `images/tacplus-build.cloudbuild.yaml`, before the image is tagged
  `fp-`, that runs it (`docker run --rm <image> id -u`, expecting 1000), so a build image that cannot start
  its steps is never published.
- **The client generates against the fleet's locked contracts** (2026-10-28, nightly scan, #14): `client/`'s
  `depends` resolve through the registry at `latest` (each contract's main), not at the commits in `fleet.lock`, so
  the client can call a contract newer than the one deployed, and it broke when those mains raised their floor to
  2.4. Proposal: a fleet's client (`kind: client` inside a fleet repo) resolves `depends` from `fleet.lock`
  (`contract_commit`), or from `build/proto`, as the README already says. That is new tacplus behaviour
  (tacplus `pkg/runner/depends.go`), so it needs design. Pinning by release line (#8, tacplus-dev/tacplus#180)
  narrows the drift but doesn't remove it.
- **The Google secret's old versions disabled by the pipeline** (2026-11-10, #46): after a rotation (Jody adds
  the new secret on the client in the Console and as a new version of `google-signin-seatrials`), the
  pipeline could disable the older versions once `signin-secrets` has checked the new one with Google and
  installed it, as decisions/secrets-by-pipeline-2026-11-05.md asks. That needs `secretVersionManager` on that
  secret for `seatrials-deploy` (tacplus-dev/cloud), and still leaves disabling the old secret on the client
  to the Console: Google has no API for it. Google's secrets don't expire, so nothing forces a rotation.
- **A daily Google client check** (2026-11-10, #46): `signin/google-client` runs after each deploy. Google
  says it deletes OAuth clients that go unused for long, and an unused seatrials (no deploy, no sign-in) would
  not notice. Running `deploy/google-client.sh client` on the daily schedule, even without a deploy, would
  say so first. Whether Google's authorize or token checks count as use is not documented.
- **Publish seatrials' Google app** (2026-11-13, #46): the Google Auth Platform app `seatrials` in `tacplus-dev`
  is *Testing*, so only the test users listed under *Audience* can sign in with Google (anyone else is refused
  by Google). *Publish app* needs a home page and a privacy policy
  URL on an authorized domain (`tacplus.dev`), which seatrials does not serve yet. The scopes (`openid`,
  `email`, `profile`) need no verification. Needs the two pages (where, and who writes the policy: Jody), then
  his *Publish app* in the Console.
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
- **What #8 needs besides the releases** (2026-10-29, #8, tacplus-dev/tacplus#180, #213 there; the relock's part
  settled 2026-11-23 by #1: the fleet is on 2.6 with `images: source`, which reads no package, so only the cluster's
  pull of release images is left, for when the fleet moves to them): `version:` in
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
  `apple` mode with a client secret, would cover both. (2) Done (2026-11-09): the seeds are in Secret Manager
  (`test-idp-seeds`, tacplus-dev/cloud#32), written once by `test-idp-deploy` through WIF, with no GitLab token. (3) Keycloak's signing keys are new with every pod
  (the realms are imported on each start, 2026-11-09). Importing fixed keys derived from the seed would keep them
  across rollouts. (4) Done since #27's rework (2026-11-09): `test-idp-signin` runs in every pipeline, the daily
  schedule's too, and applies first. (5) `test-idp/local.sh` runs Keycloak alone, not haproxy in front of it: the
  path rules were checked by hand on 2026-11-09 (#27). haproxy in the same network namespace, or a second
  container proxying to the first, would put them under the script, as a test the realm checks run through.
  (6) Rotating the seeds (2026-11-09, #27): `test-idp` generates them only while `test-idp-seeds` has no version,
  and `test-idp-deploy` may not disable or destroy one. A manual input (say `TEST_IDP_ROTATE_SEEDS=1`) that has
  `apply.sh` add a new version would rotate every test password and client secret from GitLab.
  (7) The build pipeline's nightly report of 2026-11-17 (at c2f8fe4, with CodeQL and Trivy's config checks new
  in it) fails the policy on three findings here, none of them new code: Trivy KSV-0014 on `keycloak.yaml` and
  `admin-job.yaml` (Keycloak's and kcadm's root file systems are writable; haproxy's is already read-only), and
  CodeQL `py/clear-text-logging-sensitive-data` on `testidp.py`'s `secret` command, which writes a derived
  secret to stdout by design, for `apply.sh` and the hub to capture, never into a job's log. A read-only root
  for Keycloak needs an `--optimized` start (a plain `start` rebuilds into `/opt/keycloak/lib`) and emptyDirs for
  `/tmp` and kcadm's config, checked on a real Keycloak first (`test-idp/local.sh`, which needs docker), since
  the IdP is live on `dev`. The `secret` command (and `new-seed` and `render`) writes to a new file the caller
  names, mode 0600, since #55 (the hub, 2026-11-18: fix, no exception); the next nightly report confirms
  CodeQL's finding gone, and that its file-storage query (`py/clear-text-storage-sensitive-data`) does not take
  its place (if it does, that is the hub's to decide: the 0600 file is the design #55 decided). The
  same report's Trivy DS-0002 (`images/tacplus-build.Dockerfile` runs as root) is the build image's, not the
  test IdP's. Filed as bugs by the nightly scan, 2026-11-18: KSV-0014 #54, the `secret` command #55, DS-0002 #56,
  and the report's ten new findings below HIGH (CPU limits, UID/GID, registries, `RUN cd`, HEALTHCHECK) #57.
  #57 is decided (the hub's triage rules, 2026-11-18): DS-0026 is accepted rule-wide until 2027-05-17, every FROM
  of the build image is pinned by digest, and the rest stay on the nightly report with no exception. Of those,
  DS-0013 (`WORKDIR` for `RUN cd`) and KSV-0011 (CPU limits from the requests) are mechanical fixes, and
  KSV-0020/0021 (UID/GID above 10000) belong with #54's securityContexts: each is open to a later issue.
- **One signing path for the reader token** (2026-11-02, #30): `.github-reader` asks Cloud KMS as the job's
  federated principal, then, on a 401 or 403, as `fleet-seatrials-reader@`. Because the first dry run's error was
  dropped, nobody knew which path KMS accepts, so both are there. Once a dry run's log shows which one signs,
  keep that one: drop the other path from the block, and drop its binding (the key's principalSet binding, or the
  service account and its two bindings). Then every job makes one KMS call and has one binding fewer.
  If it is the service account, tacplus-dev/build and tacplus-dev/looper probably need the same change.
  Since #48 the key is tacplus-ci's, and its signer binding (tacplus-dev/cloud, authoritative) names the account
  and not this project's own principal: the answer is the service account. Every job is refused once as itself
  (a guaranteed 403 and one STS/KMS round trip); drop `kms_sign direct` from both copies of the block, its stub
  tests and the docs' description of both paths, after a pipeline's `fleet-plan` has signed as the account.
  Also: the block always signs with `cryptoKeyVersions/1`, so a re-import of the key (a rotation, version 2)
  would be ignored; it could take the key's primary or newest enabled version instead.
- **Scope each security exception to where it applies (`where`)** (2026-11-21, nightly scan
  `looper-runs/20261121T094329Z-scan`, at a5ca8d8): the build's security report warns, for every one of the 32
  entries of `security-exceptions.yaml`, "exception <id> has no where: it accepts <id> in every file (scope it:
  where)". This repository can't follow that advice today. `ci/security.sh` (lines 168-180) holds each entry to
  exactly id, reason, decided_by and expires, and it fails the security job on any other field. So an entry made
  for one place also accepts the same id anywhere else it turns up later. CVE-2026-119373 is accepted for the
  test IdP's Keycloak, and its reason says it covers the CI image's libsqlite3 too. A new appearance of an id in a deployed image would pass the
  gates silently. Proposal: `ci/security.sh` accepts an optional `where` (a finding's file or image, as
  looper-scan reads it; README: Security checks of tacplus-dev/looper) and matches an entry only there. Then
  split the shared entries by where, with tests in `ci/security_test.sh`. This needs the field list of looper#49
  widened (Jody) before it is built.
- **The nightly scan's govulncheck of `client/`** (2026-11-23, #14): looper-scan runs `govulncheck ./...` in
  `client/` on the tree as committed, where the generated packages (`client/tacplus/`, ignored) are absent, so it
  reports `client: not analyzed (loading packages)` even now the client generates. The gate covers it instead:
  `ci/client_test.sh` generates the client with the pinned compiler and runs govulncheck on it. Either the scan
  generates first (a tacplus-dev/looper change: it would need the pinned tacplus) or accepts this repository's
  gate as the client's check; until then the nightly line for `client/` is expected.
- **The functional suite's RPC items get their runs** (2026-11-23, #14): `deploy/e2e.yaml`'s tenants, rpcs,
  records, streams, redo, kernel-restart and event-trace items are `waits_on: ["#14"]` with no `run`. The client
  generates now, so each needs a run script calling the fleet through `client/` (`seatrials`), and its
  `waits_on` moved to what it still waits on (the first deploy on `dev`, #4; #27, tacplus#258, #265 where
  named). Their runs can only be proved against a deployed fleet, so this is #17's follow-up, not #14's.
- **A person's tenant credential, installed by the pipeline** (2026-11-24, #77): the root credential is the
  pipeline's now, and `client-steps` installs only its own fresh `ci-<tenant>` pairs, so nobody can run the
  doppelganger proof (`context push`, `ask`) as a tenant user from a laptop. Proposal: committed public pairs
  (say `deploy/bootstrap/tenants/<tenant>/cred_pairs.yaml`, made by `seatrials keygen --tenant` where their
  holder is) that `client-steps` installs with `tenant cred`, idempotently, beside its own. Needs Jody's word on
  whether a person's tenant key on a laptop is acceptable under secrets-by-pipeline.
- **`tenant cred` writes the whole tenant config** (2026-11-24, #77): it reads the config, replaces the pairs and
  writes it back (`UpdateTenantConfig`), so a concurrent change to the same tenant's config between the two is
  lost. `client-steps` runs in the `seatrials` resource group, one at a time with `apply`; a kernel RPC that adds
  or removes one pair would close it.
- **Apply the tenant namespaces' objects through the in-cluster operator** (2026-11-24, #75, #76): `diff` now
  names the objects in `tac-seatrials-<tid>` and leaves them out of `kubectl diff`. But `deploy/apply.sh`'s
  `schematic-operator apply` (the CLI, operator a17d507) still helm-installs them as `seatrials-deploy`, and it
  never makes the `TenantNamespace`s (only the in-cluster reconciler does). The first apply is Forbidden there.
  Proposal: `apply` installs the operator's own chart in `tac-seatrials`, and the operator, under its own
  account, applies the release. Open: the operator image (tacplus-dev/operator#6) and what the render digest
  covers then.
- **Read the tenant namespaces' pods in the post-deploy checks** (2026-11-23, #4): `seatrials-deploy` has its
  Role in `tac-seatrials` only, and deploymentproxy binds only the operator's account in `tac-seatrials-<tid>`,
  so `deploy/checks.sh pods` reads the platform namespace alone: a tenant's app service that never comes up
  (tenantecho, doppelganger, coop's pigeons) is not caught there. Proposal: deploymentproxy (or the cluster
  pipeline) also binds the deployment's deploy account read-only (`pods`, `get, list`) in each tenant namespace
  it makes, and `checks.sh pods` reads every namespace `deploy/namespaces.sh` lists.
- **Replace the unmaintained crates `rustls-pemfile` and `chrono` in the Rust pins** (2026-11-23, #13): #13 moved
  every `lang:` pin that has a fixed release (OSV, 2026-11-23). Two Rust pins are left. They have no fix because
  their crates are unmaintained: `rustls-pemfile` 2.2.0 (RUSTSEC-2025-0134; `rustls-pki-types` parses PEM itself,
  `PemObject`) and `chrono` 0.4.43 (RUSTSEC-2026-0543; `jiff` or `time`). A pin here only lists a version for the
  generated workspace. No fleet service takes either crate through it: gateway and oauth declare
  `rustls-pemfile = "2"` themselves. So dropping them means the services' own changes first, then tacplus's
  generated Rust if it still names them, then these pins.
- **tacplus could refuse a pin that is not a string** (2026-11-23, #13): `tacplus fleet build` re-marshals the
  fleet's `dependencies.yaml`, so an unquoted `1.80` came out in `build/proto` as `1.8`, a Maven version that does
  not exist. `ci/pins_test.sh` now catches it here. Every fleet and project would be covered if tacplus read
  `lang:` versions as strings and refused a number. That is new tacplus behaviour, so it needs design first.
- **The image fingerprint should cover `build/proto/dependencies.yaml`** (2026-11-23, #70): `images/build.sh`'s
  `fingerprint` hashes the compiler line, the service's commit, its `inputs_digest` (descriptors only) and the
  platforms. The fleet's `dependencies.yaml` shapes generated code too: `registry.imports.java` is the package the
  Java backend imports kernel's runtime from (#70), and a `lang:` Java pin switches code on (google-cloud-storage).
  A change there leaves every fingerprint alone, so `changed` keeps an image built from the old config. #70 needed
  no rebuild (kernel had no image). Adding the file's hash to the fingerprint fixes it, at the cost of one rebuild
  of every image when it lands.
- **Drop the SeaBeam leftovers in `dependencies.yaml`'s `registry`** (2026-11-23, #70): `gitlab_project_id:
  "79641700"` (a SeaBeam GitLab project, which tacplus writes into generated package.json and pyproject files as
  their registry) and `interfaces.rust: seabeam-controlplane-interfaces` (read by tacplus 2.6.14, never used).
  #70 fixed only `imports.java`, the one that broke a build. Removing these needs a check that no generated
  TypeScript or Python package the fleet builds publishes or resolves through that registry.
- **`diff` renders the tenants kernel records too** (2026-11-24, #76): `apply` now hands the render to the operator
  in cluster and passes once the operator's release `schematic` is the render `diff` showed (its manifest's
  digest). The operator renders `operator.yaml`'s tenants and, once kernel is up, the tenants kernel records
  (`NewServiceConfigProvider`); `schematic-operator apply --dry-run` renders `operator.yaml`'s alone. The first
  tenant approved in kernel and not in `operator.yaml` makes every later `apply` fail on the digest, saying so.
  Fix with the uni-config record (#28, the digest becomes the record's), or the operator reporting the digest of
  the render it applied in a status `diff` can read (a feature of tacplus-dev/operator).
- **The operator's Role in `tac-seatrials` from the cluster pipeline** (2026-11-24, #76): with `deployment` set the
  operator's chart renders no Role, saying the cluster pipeline grants the operator admin in `tac-<deployment>`.
  tacplus-dev/cluster binds it there only to deploymentproxy's TenantNamespaces Role, so `apply` adds the chart's
  own Role (`deploy/operator-role.yaml`, each rule within `fleet-deploy`) to the operator's release. Moving it to
  tacplus-dev/cluster's per-deployment render (an `operatorRole` beside `fleet-deploy`) would keep a deployment's
  RBAC in one place; the fleet's file is the stopgap.
- **The operator's kernel identity in `tac-seatrials`** (2026-11-24, #76): the in-cluster operator reads kernel's
  tenant records with a kernel token for its account, `tac-seatrials/operator` (operator chart,
  `KERNEL_K8S_TOKEN_FILE`). Whether `services/kernel.yaml` has a delegate that admits it is untried until the first
  apply: without one the operator renders `operator.yaml`'s tenants only, which is all seatrials has today. Check
  the operator's log after the first apply (`kernel tenant records`) and add the delegate if it is refused.
- **Let the deploy account read `TenantNamespace`s** (2026-11-24, #76): `apply` waits on the operator's release and
  shows the operator's log when it does not come; the deploy account cannot read the `TenantNamespace`s the
  operator makes (`fleet-deploy` has no `deploymentproxy.tacplus.dev`), so a namespace deploymentproxy never makes
  Ready shows only in that log. get/list/watch on `tenantnamespaces` in `tac-seatrials` (tacplus-dev/cluster)
  would let `apply` name it.

## Promoted / declined
- 2026-11-26 `ci/security.sh` fails only on what ships; CI tooling is reported, never failing: approved on #72 (Jody's ship-only decision of 2026-11-23), built (#72), the tooling-only exception GO-2026-5932 removed
- 2026-11-11 The reader's key and account move to tacplus-ci: on ROADMAP.md at Jody's request, built (#48)
- 2026-10-29 agent decision Service images for arm64, amd64 behind a setting: on ROADMAP.md (Next), at Jody's request (#23)
- **`ci_gcp` fails silently too** (2026-11-02, #31): every job calls `ci/lib.sh`'s helpers in an `&&` list, where
  bash turns errexit off inside the functions, so a failed step inside one is ignored unless the function returns
  on it. #31 made `ci_kube` do so (dry run 2 ran `test-idp/signin.sh` with no kube context). `ci_gcp` still
  ignores a failed `create-cred-config` or `gcloud auth login` and goes on as no one: it should return on each,
  with gcloud's error, as `ci_kube` now does, with a stub test in `ci/lib_test.sh`.
- **Each service back on its published image** (2026-11-23, #1): `fleet.yaml`'s `images: source` builds every
  service from its release tag, for the first deploy (eventbus, stratum, oauth, redo and gateway have no published
  image; kmaker neither). When every release the fleet runs publishes its image (looper#17, the release issues),
  delete the line and relock, so the lock records each image by digest; the deploy then needs the images' pull
  (PROPOSALS: what #8 needs) and `images/build.sh` builds nothing for them.
- **The closure check for the Rust and Java services too** (2026-11-24, #68): `ci/closure_test.sh` generates and
  builds every Go service at its locked commit against `build/proto`, which would have caught doppelganger v0.2.1
  calling the `provider_model` llmproxy v0.1.6 lacks before the deploy did. gateway, oauth, llmproxy and redo
  (Rust) and kernel, eventbus and stratum (Java) are still checked by the `images` job alone: gateway's generated
  crate needs more memory than the gate has (STATE.md). A `cargo check` of each Rust service (no codegen) and a
  `mvn -o compile` of each Java one would close it, if the gate's time and memory allow.
- **`tacplus fleet build --check` in the nightly scan** (2026-11-24, #68): relocking llmproxy to 0.2 moved five
  other services' patches with it (oauth 0.1.4, doppelganger 0.2.2, tenantecho 0.2.3, coop 0.1.6, pigeonhost
  0.1.8), since the fleet build takes every line's newest patch. A scheduled `--check` that files the newer
  patches as a relock issue would move them one small step at a time instead of with an unrelated fix.
