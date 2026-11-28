# fleet-seatrials

Sea trials: the proof fleet. A ship goes to sea trials before it is commissioned; this fleet
exists to prove the new design end to end on a small, disposable cluster, with doppelganger as
the ship under test.

What it proves:

1. **doppelganger runs as an ordinary tacplus service** on a fleet composed from the registry:
   client-facing through the gateway, answering through llmproxy, holding no model credential.
2. **A tenant-owned service in two tenant namespaces** is reached correctly: the gateway routes
   each tenant's call to that tenant's instance. (The example service is not written yet.)

`fleet.yaml` names the registries this fleet trusts, the tacplus floor (2.6), and every service the
fleet runs with the repo implementing it and its release line (`version: MAJOR.MINOR`, its newest
patch tag) — the smallest set the fleet build's dependency closure allows. `dependencies.yaml` holds
the language and tool pins. They are the versions in the manifests tacplus writes for code generated from
`build/proto`, in the operator build and in each service image. At v2.6.16 these are: every Rust pin, in the
generated Cargo workspace; zap and grpc, in a generated Go server module; and the TypeScript and Python
pins, in a generated package.json or pyproject. tacplus writes no Java versions: a Java pin only switches
generated code on, as google-cloud-storage switches on stratum's GcsArchiveSink. A service's own
manifest and lock stay its own, and cargo and Go resolve upward from these pins. The client keeps a copy in
`client/proto`. The pins are kept free of fixable advisories (#13). A version YAML would read as a number
is quoted (`ci/pins_test.sh`).
`tacplus fleet build` resolves it all, stamps fleet-owned caller lists
(llmproxy admits exactly the services here that declare a client of it), writes `fleet.lock`, and
leaves `build/proto` as the merged tree the fleet-side services are generated from.

The fleet builds its own images from source (`images: source` in `fleet.yaml`, tacplus#950): the
lock records each release's tag commit and no image, and `images/build.sh` builds every service at
that commit. For the first deploy this is how eventbus, stratum, oauth, redo and gateway run at all:
their releases have no published image yet (#1; Jody, 2026-11-22, tacplus-dev/roadmap
`decisions/ci-on-gitlab-2026-10-27.md`). Each service moves to its own published image when its
release workflow lands (tacplus#180's direction is unchanged), and deleting `images: source` returns
the whole fleet to them. To relock (a new patch, a new line), run `tacplus fleet build` with the
compiler `images/pins.yaml` pins, then rebuild the operator (`deploy/build-operator.sh`) and run
`generate` against `deploy/bootstrap`, and commit `fleet.lock`, `build/proto` and any rewritten
`deploy/bootstrap/services/*.yaml`. `generate` adds the kernel delegates a new render needs but removes none: when a
service leaves a namespace (redo the restore tenant's, stratum the platform's, #3), delete its old delegate from
`services/kernel.yaml` by hand (`deploy/stratum-redo_test.sh` checks the committed file is what `generate` writes).

## Where it runs

seatrials deploys to tacplus-dev/cloud's `dev` stack in seabeam.net (#39): the project **`tacplus-dev`**, its
GKE cluster **`dev`** (us-central1-a), as `seatrials-deploy@tacplus-dev.iam.gserviceaccount.com` through the
federation provider `tacplus-dev-fleet-seatrials` (this project's protected `main` only), with its images in
the registry `us-central1-docker.pkg.dev/tacplus-dev/seatrials`. The test IdP's jobs run there as
`test-idp-deploy@tacplus-dev.iam.gserviceaccount.com`. The cluster is tacplus-dev/cloud's, and the namespaces
and rights the fleet has in it are tacplus-dev/cluster's: nothing here creates or deletes a cluster.

The `tacplus-reader` app's KMS key (`TACPLUS_READER_KMS_KEY`) and the reader's service account
(`TACPLUS_READER_SA`), the reader path every job fetches this repository through, and the drift path, are
tacplus-ci's, made by tacplus-dev/cloud's `stacks/ci` (#48, tacplus-dev/cloud#30).
The Google OAuth client `seatrials-web` that `deploy/bootstrap/services/oauth.yaml` names is `tacplus-dev`'s too,
its secret the Secret Manager secret `google-signin-seatrials` (#46; [docs/deploy-pipeline.md](docs/deploy-pipeline.md#the-google-sign-in-client)).
`ci/target_test.sh` checks that nothing names the old GCP project.
The cutover's order and the grants still to come are in
[docs/deploy-pipeline.md](docs/deploy-pipeline.md#gcp-workload-identity-federation-no-key-files).

## Layout

- `fleet.yaml`, `fleet.lock`, `build/proto` — the fleet: what runs, at which commits, and the merged proto tree.
- `images/` — Cloud Build pipeline: `images/build.sh build-image` (the build image, with the fleet's tacplus
  and launcher built from `images/pins.yaml`'s commits), `images/build.sh all` (every service at its locked commit, into Artifact Registry as
  `schematic/<service>:<fleet commit>` and `:local`). Every image runs under the launcher. Images are built for
  `images/pins.yaml`'s `platforms`: `[arm64]`, what the fleet runs on; `[arm64, amd64]` builds both. Each
  platform's image is `fp-<fingerprint>-<arch>`, and the tags above name one multi-arch index over them. The
  fingerprint covers the platforms, so changing them rebuilds every service. The build image the services build
  in is `ci/tacplus-build:fp-<fingerprint>` over its pinned commits, Dockerfile and Cloud Build config; every
  service build first builds it when that tag is missing, and `images/build.sh changed` then builds one service
  of each language in it too. Its steps run as the unprivileged `build`, not root. Its one FROM, `BUILD_IMAGE` (tacplus's
  build image of the fleet's line), is pinned by digest (#57). There is no `ci/tacplus` image: tacplus has
  published none since 2.4 (tacplus-dev/tacplus#193), so the build image builds tacplus from source at the
  pinned commit, stamped as `ci/tools.sh` stamps `bin/tacplus` (#65).
- `deploy/` — `build-operator.sh` (this fleet's operator from the library against build/proto), `init.sh`
  (CA and cluster PKI, once, by hand), `init-secrets.sh` (the pipeline's: the CA and cluster PKI, and the root
  credential, generated once into Secret Manager), `client-steps.sh` (the tenants, as that root credential), `secrets.sh`, `signin-secrets.sh` (the sign-in secrets, from the pipeline's
  variables and Secret Manager), `google-client.sh` (Google's client, checked with Google), `diff.sh` (what an apply would change, by name), `apply.sh`
  (render and apply), `checks.sh` (the post-deploy checks), `stratum-cutover.md` (the deploy plan for each tenant's Stratum and the `/system` redo, #3), `bootstrap/` (operator.yaml and services/*.yaml are
  committed; crypto.yaml, ca.pem and configs/ are not).
- `ci/` — the deploy and test pipeline, run from the GitLab project tacplus-dev/fleet-seatrials, which holds the
  secrets: [docs/deploy-pipeline.md](docs/deploy-pipeline.md). `ci/checks.sh` runs the script tests and the secrets
  scan, `ci/secrets.sh` (bash, git, jq, yq, opa, gitleaks). `ci/security.sh` is the security job: OSV-Scanner,
  govulncheck on the pinned binaries, gitleaks and Trivy on the CI image and the test IdP's Keycloak and haproxy, with
  `security-exceptions.yaml` enforced; it fails only on what ships, and reports CI tooling's findings (#72) ([docs/deploy-pipeline.md](docs/deploy-pipeline.md#the-security-job)). `ci/cert.sh` is the cert job: the
  pipeline owns the public certificate, checks it (`ci/cert-check.sh`) and has `lego` obtain or renew it by
  DNS-01 into Secret Manager, and every job that renders installs that version as the gateway's
  ([docs/deploy-pipeline.md](docs/deploy-pipeline.md#the-certificate)).
- `build.lock`, `gates.yaml` — the build pin (#42): the CI image by digest, in which tacplus-dev/build runs
  `gates.yaml`'s `full` gates without Docker. To move it, change the digest with the CI image's tag
  (`ci/build_lock_test.sh` checks they agree); it is a change like any other, landed on the full gates.
- `test-idp/` — the test IdP at idp.test.tacplus.dev:8443: a Keycloak whose realms emulate Google's, Microsoft's
  and Apple's claim shapes, with test users and domains, applied and checked by the pipeline, so sign-in is tested
  with no person: [test-idp/README.md](test-idp/README.md).
- `client/` — `seatrials`, the local client: a tacplus client project. It is not generated from build/proto:
  `tacplus build` fetches the contracts it calls (kernel, tenantecho, doppelganger) and theirs from the registry,
  each at the release line `fleet.yaml` runs (`kernel@0.1`, ...: the line's newest patch tag, which `fleet.lock`
  also locks until a newer patch is relocked), never at a contract's main (#14). `ci/client_test.sh` holds those
  lines to `fleet.yaml`'s, and generates, builds and govulnchecks the client with the pinned compiler. It
  authenticates with a credential pair (keygen → the public half goes into the fleet config), gets a kernel
  token through the gateway, administers tenants with the root pair, and runs the two proofs (`ping`, `ask`).

## The proofs, end to end

Deploys run from the GitLab pipeline, never from a laptop (docs/deploy-pipeline.md): images, generate and
diff, then apply, then the post-deploy checks.

**Apply is automatic on main.** seatrials isn't production, so `apply` starts by itself once `diff` succeeds,
and it applies the render `diff` showed, by its digest (Jody, 2026-11-02; tacplus-dev/roadmap
`decisions/deterministic-deployments-2026-11-02.md`, addendum; #34). A production fleet keeps a manual apply
that only Jody plays ([`PRODUCTION.md`](https://github.com/tacplus-dev/roadmap/blob/main/PRODUCTION.md)). Three
jobs stay manual, because none approves the fleet:

- `signin-secrets`: re-installs the sign-in secrets after one is rotated in the GitLab variables or Secret
  Manager. `apply` installs them anyway.
- `test-idp`: the test IdP's one-time setup, which generates and stores its seeds.
- `init-secrets`: a deployment's first run, which generates the fleet's CA and crypto file, and its root
  credential, into Secret Manager.
- `client-steps`: after an apply, the first-time client steps, as that root credential: the tenants and a
  ping of each (#77).

**Where each secret lives** ([docs/deploy-pipeline.md](docs/deploy-pipeline.md#secrets)):

| Secret | Where | Written by | Read by |
| --- | --- | --- | --- |
| The fleet's CA and cluster PKI (`crypto.yaml`) | Secret Manager `fleet-crypto-seatrials` (tacplus-dev) | `init-secrets`, as `seatrials-init-secrets` through WIF | `generate`, `diff`, `apply`, `test`, as `seatrials-deploy` |
| The root CA's certificate (`ca.pem`) | Secret Manager `fleet-ca-seatrials` (tacplus-dev) | the same | the same |
| The fleet's root credential (`root.cred.json`: its private key and public pair) | Secret Manager `fleet-root-cred-seatrials` (tacplus-dev) | `init-secrets`, the same | `client-steps`, as `seatrials-deploy` |
| The public certificate and the ACME account | Secret Manager `tls-seatrials`, `acme-account-seatrials` | `cert` | every job that renders |
| The test IdP's seeds | Secret Manager `test-idp-seeds` | `test-idp` | the test IdP's jobs, seatrials' (optional) |
| Google's client secret | Secret Manager `google-signin-seatrials` | Jody, in the Console | `apply`, `signin-secrets`, as `seatrials-deploy` |
| Microsoft's and Apple's sign-in secrets | the GitLab project's protected variables | Jody, in the GitLab UI | `apply`, `signin-secrets` |

No GitLab variable holds the CA or the crypto file (#44), and no GitLab or GitHub token is stored.

`ci/pipeline_test.sh` checks this on the rendered pipeline.

**The pipeline owns the certificate** (#35; tacplus-dev/roadmap `decisions/certificates-by-pipeline-2026-11-03.md`).
The fleet runs no letsencrypt workload: the `cert` job obtains `tacplus.dev` and `*.tacplus.dev` from Let's Encrypt by
DNS-01 when it is missing, expired or due (ARI, or the last third of its lifetime), keeps it as a version of the
secret `tls-seatrials`, and the gateway serves that version (`CERT_CHAIN`) and hot-swaps a renewed one with no
restart. A daily schedule runs the pipeline, so a renewal deploys by itself. The old rule that letsencrypt is
never restarted no longer applies: there is nothing left to restart. The first time, on a new cluster:

1. `images/build.sh build-image`, then the manual `init-secrets` job: the CA and crypto file, and the root
   credential, into Secret Manager. Nobody holds the root key: the job adds it to `fleet-root-cred-seatrials`
   and prints only its public pair, the `root_cred_pairs` entry (`root_cred_pairs:` and one `- {...}` line).
2. A commit puts that entry in `deploy/bootstrap/operator.yaml` in place of the one in `root_cred_pairs`.
3. The pipeline: images, generate, diff, apply (by itself, registering the root pair), test.
4. The manual `client-steps` job (`deploy/client-steps.sh`), as the root credential: for each of
   `operator.yaml`'s tenants, `tenant create --if-missing /tenants/<t>`, a fresh pair `ci-<t>` made and
   installed in place of its earlier one (`tenant cred --replace`), then `login` and `ping` with it, which the
   tenant's own instance must serve (`served_by` names `tenants/<t>`). It is idempotent: run it again at will.

Nothing here runs on a laptop. `client/` builds as `ci/tools.sh` builds it, into `bin/seatrials`
(`cd client && tacplus build && go build -o seatrials ./cmd/seatrials`; public TLS, so no `SEATRIALS_CA`), and
`SEATRIALS_HOME` is where it keeps keys and tokens (`~/.seatrials` otherwise). The doppelganger proof
(`context push`, `ask`) needs a tenant credential of its caller's, which only the root credential installs: it
is the functional suite's, with its RPC items (PROPOSALS.md).
