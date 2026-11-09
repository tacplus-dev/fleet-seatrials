# fleet-seatrials

Sea trials: the proof fleet. A ship goes to sea trials before it is commissioned; this fleet
exists to prove the new design end to end on a small, disposable cluster, with doppelganger as
the ship under test.

What it proves:

1. **doppelganger runs as an ordinary tacplus service** on a fleet composed from the registry:
   client-facing through the gateway, answering through llmproxy, holding no model credential.
2. **A tenant-owned service in two tenant namespaces** is reached correctly: the gateway routes
   each tenant's call to that tenant's instance. (The example service is not written yet.)

`fleet.yaml` names the registries this fleet trusts, the tacplus floor, and every service the
fleet runs with the repo implementing it — the smallest set the fleet build's dependency closure
allows. `dependencies.yaml` holds the language and tool pins. `tacplus fleet build` resolves it
all, stamps fleet-owned caller lists (llmproxy admits exactly the services here that declare a
client of it), writes `fleet.lock`, and leaves `build/proto` as the merged tree the fleet-side
services are generated from.

## Where it runs

seatrials deploys to tacplus-dev/cloud's `dev` stack in seabeam.net (#39): the project **`tacplus-dev`**, its
GKE cluster **`dev`** (us-central1-a), as `seatrials-deploy@tacplus-dev.iam.gserviceaccount.com` through the
federation provider `tacplus-dev-fleet-seatrials` (this project's protected `main` only), with its images in
the registry `us-central1-docker.pkg.dev/tacplus-dev/seatrials`. The test IdP's jobs run there as
`test-idp-deploy@tacplus-dev.iam.gserviceaccount.com`. The cluster is tacplus-dev/cloud's, and the namespaces
and rights the fleet has in it are tacplus-dev/cluster's: nothing here creates or deletes a cluster.

**These stay in jody1-328023 until they move** (tacplus-dev/cloud#15): the `tacplus-reader` app's KMS key
(`TACPLUS_READER_KMS_KEY`) and the reader's service account (`TACPLUS_READER_SA`), the reader path every job
fetches this repository through, and the drift path; and the Google OAuth client `seatrials-web`
(`deploy/bootstrap/services/oauth.yaml`). `ci/target_test.sh` checks that nothing else names that project.
The cutover's order and the grants still to come are in
[docs/deploy-pipeline.md](docs/deploy-pipeline.md#gcp-workload-identity-federation-no-key-files).

## Layout

- `fleet.yaml`, `fleet.lock`, `build/proto` — the fleet: what runs, at which commits, and the merged proto tree.
- `images/` — Cloud Build pipeline: `images/build.sh tacplus` (the fleet's tacplus and build images at
  `images/pins.yaml`), `images/build.sh all` (every service at its locked commit, into Artifact Registry as
  `schematic/<service>:<fleet commit>` and `:local`). Every image runs under the launcher. Images are built for
  `images/pins.yaml`'s `platforms`: `[arm64]`, what the fleet runs on; `[arm64, amd64]` builds both. Each
  platform's image is `fp-<fingerprint>-<arch>`, and the tags above name one multi-arch index over them. The
  fingerprint covers the platforms, so changing them rebuilds every service. The build image the services build
  in is `ci/tacplus-build:fp-<fingerprint>` over its pinned commits, Dockerfile and Cloud Build config; every
  service build first builds it when that tag is missing.
- `deploy/` — `build-operator.sh` (this fleet's operator from the library against build/proto), `init.sh`
  (CA and cluster PKI, once), `secrets.sh`, `signin-secrets.sh` (the sign-in secrets, from the pipeline's
  variables), `diff.sh` (what an apply would change, by name), `apply.sh`
  (render and apply), `checks.sh` (the post-deploy checks), `bootstrap/` (operator.yaml and services/*.yaml are
  committed; crypto.yaml, ca.pem and configs/ are not).
- `ci/` — the deploy and test pipeline, run from the GitLab project tacplus-dev/fleet-seatrials, which holds the
  secrets: [docs/deploy-pipeline.md](docs/deploy-pipeline.md). `ci/checks.sh` runs the script tests and the secrets
  scan, `ci/secrets.sh` (bash, git, jq, yq, opa, gitleaks). `ci/security.sh` is the security job: OSV-Scanner,
  govulncheck on the pinned binaries, gitleaks and Trivy on the CI image and the test IdP's Keycloak and haproxy, with
  `security-exceptions.yaml` enforced ([docs/deploy-pipeline.md](docs/deploy-pipeline.md#the-security-job)). `ci/cert.sh` is the cert job: the
  pipeline owns the public certificate, checks it (`ci/cert-check.sh`) and has `lego` obtain or renew it by
  DNS-01 into Secret Manager, and every job that renders installs that version as the gateway's
  ([docs/deploy-pipeline.md](docs/deploy-pipeline.md#the-certificate)).
- `test-idp/` — the test IdP at idp.test.tacplus.dev:8443: a Keycloak whose realms emulate Google's, Microsoft's
  and Apple's claim shapes, with test users and domains, applied and checked by the pipeline, so sign-in is tested
  with no person: [test-idp/README.md](test-idp/README.md).
- `client/` — `seatrials`, the local client: a tacplus client project generated against build/proto. It
  authenticates with a credential pair (keygen → the public half goes into the fleet config), gets a kernel
  token through the gateway, administers tenants with the root pair, and runs the two proofs (`ping`, `ask`).

## The proofs, end to end

Deploys run from the GitLab pipeline, never from a laptop (docs/deploy-pipeline.md): images, generate and
diff, then apply, then the post-deploy checks.

**Apply is automatic on main.** seatrials isn't production, so `apply` starts by itself once `diff` succeeds,
and it applies the render `diff` showed, by its digest (Jody, 2026-11-02; tacplus-dev/roadmap
`decisions/deterministic-deployments-2026-11-02.md`, addendum; #34). A production fleet keeps a manual apply
that only Jody plays ([`PRODUCTION.md`](https://github.com/tacplus-dev/roadmap/blob/main/PRODUCTION.md)). Two
jobs stay manual, because neither approves the fleet:

- `signin-secrets`: re-installs the sign-in secrets after one is rotated in the GitLab variables. `apply`
  installs them anyway.
- `test-idp`: the test IdP's one-time setup, which generates and stores its seeds.

`ci/pipeline_test.sh` checks this on the rendered pipeline.

**The pipeline owns the certificate** (#35; tacplus-dev/roadmap `decisions/certificates-by-pipeline-2026-11-03.md`).
The fleet runs no letsencrypt workload: the `cert` job obtains `tacplus.dev` and `*.tacplus.dev` from Let's Encrypt by
DNS-01 when it is missing, expired or due (ARI, or the last third of its lifetime), keeps it as a version of the
secret `tls-seatrials`, and the gateway serves that version (`CERT_CHAIN`) and hot-swaps a renewed one with no
restart. A daily schedule runs the pipeline, so a renewal deploys by itself. The old rule that letsencrypt is
never restarted no longer applies: there is nothing left to restart. (letsencrypt stays in `fleet.yaml` only
as a contract the pinned gateway imports, until the gateway pin moves past its retirement: PROPOSALS.md.) The first time, on a new cluster:

```
deploy/init.sh && images/build.sh tacplus   # then crypto.yaml and ca.pem into the GitLab project
# the pipeline: images, generate, diff, apply (by itself), test
cd client && tacplus build && go build -o seatrials ./cmd/seatrials   # generate, then build; public TLS: no SEATRIALS_CA needed
./seatrials keygen root            # paste cred_pair into deploy/bootstrap/operator.yaml root_cred_pairs; apply again
./seatrials keygen --tenant /tenants/alpha alpha; ./seatrials keygen --tenant /tenants/beta beta
./seatrials login --as root
./seatrials tenant create /tenants/alpha; ./seatrials tenant cred /tenants/alpha alpha   # same for beta
./seatrials login --as alpha; ./seatrials ping --as alpha hello      # served_by names tenants/alpha
./seatrials login --as beta;  ./seatrials ping --as beta hello       # served_by names tenants/beta
./seatrials context push --as alpha --tenant ~/workspace/jody        # the tenant's shared doppelganger context
./seatrials context push --as alpha ~/my-notes                       # the caller's own context
./seatrials ask --as alpha "what matters?"                           # alpha's doppelganger, through llmproxy
```
