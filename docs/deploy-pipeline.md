# The seatrials deploy pipeline

Deployments of seatrials, and their tests, run from GitLab, and GitLab holds the secrets. Nothing is
deployed from a laptop or held on one (Jody, 2026-10-29; #17; tacplus-dev/roadmap
`decisions/ci-on-gitlab-2026-10-27.md`, addendum 2026-10-29).

- **Where it runs:** the private GitLab project
  [tacplus-dev/fleet-seatrials](https://gitlab.com/tacplus-dev/fleet-seatrials), on a runner used only for
  deploys.
- **What it runs:** this repository. The project's `.gitlab-ci.yml` is
  [`ci/gitlab-project.gitlab-ci.yml`](../ci/gitlab-project.gitlab-ci.yml), copied in as is. Its `fleet-plan`
  job resolves the commit to deploy and fetches [`ci/deploy.gitlab-ci.yml`](../ci/deploy.gitlab-ci.yml) at
  that commit. `fleet-deploy` then runs that file as a child pipeline, and every job of it checks this
  repository out at the same commit.

## Stages

| Stage | Job | What it does |
| --- | --- | --- |
| tools | `tools` | Builds `bin/`: tacplus at `images/pins.yaml`'s `tacplus_commit`, `schematic-operator` (`deploy/build-operator.sh`), yq, opa, gitleaks, the security job's scanners and `lego` ([`ci/tools.sh`](../ci/tools.sh)). `bin/` is the pipeline's only artifact, and it holds no secret. |
| checks | `checks` | Runs the script tests ([`ci/checks.sh`](../ci/checks.sh)) and the secrets scan ([`ci/secrets.sh`](../ci/secrets.sh)): gitleaks over the history and the tree at HEAD. |
| checks | `security` | [`ci/security.sh`](../ci/security.sh): OSV-Scanner, govulncheck on the pinned binaries, gitleaks on the history and the tree, Trivy on the CI image ([below](#the-security-job)). `images` and `generate` wait for it, so nothing is built or applied until it passes. Its JSON report, `security/report.json`, is its artifact, failed or not. |
| cert | `cert` | [`ci/cert.sh`](../ci/cert.sh): the pipeline owns the certificate ([below](#the-certificate)). It checks the current version of the secret `tls-seatrials` and has `lego` obtain or renew it by ACME DNS-01 when it is missing, expired or due, as a new version. It hands the secret and version to every job that renders. |
| images | `images` | Runs `WAIT=1 images/build.sh changed` on Cloud Build and waits for every build it submitted. The job fails if any build fails. Each image is built for `images/pins.yaml`'s `platforms` (`[arm64]`). |
| generate | `generate` | Runs `schematic-operator generate` with `deploy/bootstrap/crypto.yaml` and `ca.pem` taken from `FLEET_CRYPTO_YAML` and `FLEET_CA_PEM`, and the certificate version `cert` passed on installed as the gateway's, then the routing check: `deploy/checks.sh opa` (`opa eval`) on the rendered `tenants/namespace.rego`. Each tenant's claim matcher must route to that tenant, and a different claim value to none. |
| diff | `diff` | [`deploy/diff.sh`](../deploy/diff.sh): `kubectl diff` of the render (`schematic-operator apply --dry-run`) against seatrials. It prints object **names** only, and the render's digest, which it hands to `apply` ([below](#the-render-diff-showed-is-the-one-applied)). |
| apply | `apply` | **Automatic** once `diff` succeeds, in the protected environment `seatrials` ([below](#apply-is-automatic-seatrials-isnt-production)). Checks the render's digest, with the same certificate version, then `deploy/secrets.sh`, `deploy/apply.sh` and `deploy/signin-secrets.sh`. |
| apply | `signin-secrets` | Manual, environment `seatrials`. Re-installs the sign-in secrets from the variables and Secret Manager and nothing else, after a secret is rotated. |
| generate | `init-secrets` | Manual, in the protected environment `init-secrets`. A deployment's first run: generates `FLEET_CRYPTO_YAML` and `FLEET_CA_PEM` and stores them in the project ([below](#generated-secrets-the-init-secrets-job)). |
| apply | `test-idp` | Manual, in the protected environment `test-idp`: the test IdP's seeds (the first time), its certificate, and Keycloak with its realms on the `dev` cluster ([`test-idp/apply.sh`](../test-idp/apply.sh); [below](#the-test-idp)). |
| test | `test-idp-signin` | The same apply first (main's realms; the certificate renewed when due), then [`test-idp/signin.sh`](../test-idp/signin.sh): each realm's discovery and every test user's claim shape. One user per emulated provider signs in at tacplus.dev and gets a kernel session. The removed user is refused. Until the `test-idp` job has set the test IdP up (the environment `test-idp` has no `TEST_IDP_SEED`), it skips, saying so, without asking GCP or the cluster for anything. |
| test | `test` | After `apply`: the functional end-to-end suite, [`deploy/e2e.sh`](../deploy/e2e.sh) on [`deploy/e2e.yaml`](../deploy/e2e.yaml) ([below](#the-functional-suite)). Each item is a named test that passes, fails, or waits on the open issues it names. The report is the job's JUnit test report. |

Every pipeline deploys: tools, checks, cert, images, generate, diff, then `apply` and `test`, and `test-idp-signin` once the test IdP is set up. A `diff` that fails stops it before `apply`. A daily schedule runs the same pipeline ([below](#the-daily-schedule)).

### The security job

This pipeline applies with seatrials' deploy secrets, and tacplus-dev/build's checks never reach it, so it
runs tacplus-dev/looper#49's floor itself (#36; tacplus-dev/roadmap
`suggestions/2026-11-04-the-deterministic-security-checks-in-the-pipelines-that-apply-infrastructure.md`):

- **OSV-Scanner** on the tree's dependency manifests and lock files (`client/go.mod`), at the deployed commit;
- **`govulncheck -mode=binary`** on every pinned tool binary in `bin/`: tacplus, schematic-operator, yq, opa,
  gitleaks, lego, and the scanners themselves;
- **gitleaks** on the whole history and on the tree (the job fetches the history: `FLEET_FETCH_HISTORY=1`);
- **Trivy** on the CI image the jobs run in, every `image:` of `ci/*.gitlab-ci.yml`, for the runner's platform, and
  on the images this repository deploys itself (#41): every container of `test-idp/*.yaml`, today the test IdP's
  Keycloak and haproxy, for the architecture its pod's `nodeSelector` picks (arm64), so a vulnerable pin fails the pipeline before
  `test-idp` applies it.

The tools are pinned in [`ci/tools.sh`](../ci/tools.sh), each by module version and module hash, and all built
with one pinned Go toolchain, not the CI image's go: the standard library is in every binary, and a fixed
vulnerability in it fails the job (#49: GO-2026-6859, fixed in go1.27.4). Each binary is refused unless it reports
that toolchain. lego is built from source as its release builds it, because its release binary's standard library
had that vulnerability. opa, gitleaks, osv-scanner and Trivy are built
from source, each in a module of its own that raises a dependency with a fixed vulnerability its release doesn't
take yet (klauspost/compress, andybalholm/brotli, ulikunitz/xz; #40), each pinned by version and module hash too. **It fails** on any secret, and on any HIGH or
CRITICAL finding with a fixed version, unless an unexpired entry of
[`security-exceptions.yaml`](../security-exceptions.yaml) accepts it, by its id or an alias. It also fails on a
tool that cannot run, and on an entry that has expired or has any field other than `id`, `reason`,
`decided_by` and `expires` (YYYY-MM-DD), the form looper-scan reads. Its tests are
[`ci/security_test.sh`](../ci/security_test.sh), run by `checks`: a planted secret fails, an expired exception
fails, a clean tree passes, and a finding in a deployed image fails like one in the CI image.

It runs on every pipeline here, a scheduled one included. Pushes and pull requests happen on GitHub, so the
same job runs there too, on every push to main, every pull request and nightly
([`.github/workflows/security.yml`](../.github/workflows/security.yml)).
The CI image alone fills most of a GitHub runner's free disk, so that job runs on the runner's host: it
deletes the runner's preinstalled toolsets, then runs `ci/tools.sh` and `ci/security.sh` with `docker run` in
the image, and `ci/tools.sh` empties Go's build and module caches after each tool it builds (#37,
[`ci/workflows_test.sh`](../ci/workflows_test.sh)).

**A new finding** fails every pipeline until it is fixed or accepted. Fix it if this repository can: bump the
pin or the dependency (for a tool, a fixed dependency version in `ci/tools.sh`'s `go_build_fixed`). Otherwise add an entry with the reason it is acceptable here, who decided, and an expiry
30 days out. Run it locally after `ci/tools.sh`: `PATH=$PWD/bin:$PATH ci/security.sh` (needs the network).

### Apply is automatic: seatrials isn't production

`apply` starts by itself on `main` once `diff` succeeds, with nobody's approval. Only production waits for Jody,
and seatrials isn't production (Jody, 2026-11-02; tacplus-dev/roadmap
`decisions/deterministic-deployments-2026-11-02.md`, addendum; #34). A production fleet keeps a manual apply
that only Jody plays: [tacplus-dev/roadmap `PRODUCTION.md`](https://github.com/tacplus-dev/roadmap/blob/main/PRODUCTION.md).

Two jobs stay manual, because neither approves the fleet:

- `signin-secrets`: run after a sign-in secret is rotated in the variables or Secret Manager. `apply` installs them anyway.
- `test-idp`: the test IdP's one-time setup. It generates and stores its seeds, so it runs on purpose.

[`ci/pipeline_test.sh`](../ci/pipeline_test.sh), run by `checks`, renders the pipeline as GitLab does (anchors
expanded, `default` and `extends` merged). It checks that `apply` isn't manual on `main` and fails the
pipeline when it fails, and that these two are the only manual jobs.

### The render diff showed is the one applied

`diff` prints the SHA-256 digest of the render it compared, `render sha256:…`. It hands the digest to `apply` as
`RENDER_DIGEST`, through a dotenv artifact. A digest of the manifest says nothing of its content. `apply`
renders again twice, in `deploy/diff.sh`, and in `deploy/apply.sh` just before the apply. It
refuses, applying nothing, if either render's digest isn't the one `diff` showed: the commit, the variables
or the images changed in between. Run the pipeline again. Every job renders the certificate version `cert`
passed on, never the secret's latest, so the digest covers the certificate, and a renewal by another pipeline
in between can't split `diff` from `apply`. Once the uni-config lands (#28), the digest becomes the uni-config
record's.

### The certificate

The pipeline owns the fleet's public certificate (Jody, 2026-11-03; #35; tacplus-dev/roadmap
`decisions/certificates-by-pipeline-2026-11-03.md`, with its amendments). Nothing in the cluster orders,
holds or renews it: the in-cluster letsencrypt, its guard, `apply-letsencrypt` and the
`seatrials-letsencrypt` environment are retired, and so is the rule that letsencrypt is never restarted.

- **Where it is kept:** Secret Manager in `tacplus-dev` (tacplus-dev/cloud#6). The secret `tls-seatrials`
  holds one version per certificate: the leaf, its chain and its key, in PEM. The secret
  `acme-account-seatrials` holds lego's ACME account (its key and registration, a tar of lego's `accounts/`).
  The deploy account may read them and add versions, and nothing else may.
- **The check**, [`ci/cert-check.sh`](../ci/cert-check.sh) (`openssl`): `valid`; `due`, inside the last third
  of its lifetime; `expired`; `wrong-hostname`, when `tacplus.dev`, `*.tacplus.dev` or the fleet's fqdn isn't
  covered (a wildcard covers one label); `invalid`, when the chain doesn't verify, the key isn't the leaf's,
  or it isn't valid yet. It prints the subject, issuer, serial and dates, never the key.
- **The `cert` job**, [`ci/cert.sh`](../ci/cert.sh), with [`lego`](https://go-acme.github.io/lego/) (pinned by
  version and module hash in `ci/tools.sh`, built from source):
  - `missing`, `expired`, `wrong-hostname` or `invalid`: lego obtains a new certificate for `tacplus.dev` and
    `*.tacplus.dev` by ACME DNS-01. It writes the challenge in the Cloud DNS zone `acme-challenge-tacplus-dev`,
    which serves `_acme-challenge.tacplus.dev` by delegation (tacplus-dev/cloud#13). The deploy account may
    write records there and in no other zone.
  - `valid` or `due`: lego is given the current certificate and renews it when Let's Encrypt's renewal
    information (ARI) says so, or else in the last third of its lifetime. Usually it writes nothing.
  - A certificate lego wrote is checked, and only a `valid` one is added as a new version.
  - It passes `CERT_SECRET` and `CERT_VERSION` on, as its dotenv. `generate`, `diff`, `apply` and `test`
    install that version (`ci_cert` in [`ci/lib.sh`](../ci/lib.sh), then
    [`ci/cert-install.sh`](../ci/cert-install.sh)) as the job's `crypto.yaml` `pki.edge_tls[0]`. The operator
    serves it as the gateway's certificate in `CERT_CHAIN` mode, and the gateway hot-swaps it when its config
    changes, with no restart. It reaches the cluster only in the deployment's own delivery.
  - lego's working directory is rebuilt from the two secrets in a private temporary directory each run and
    removed on exit. No artifact holds more than the secret's name and the version number.
- **A certificate somebody else signed:** add it (leaf, chain, key) as a version of a secret of its own and
  set the project variable `CERT_SUPPLIED_SECRET` to that secret's name (the deploy account needs
  `secretAccessor` on it). `cert` checks it the same way and never runs lego. `due` is a warning in the job's
  log, and `expired`, `wrong-hostname` or `invalid` fails the pipeline, naming the secret to update.
- **A test run against Let's Encrypt's staging:** set `ACME_SERVER=letsencrypt-staging` and
  `CERT_CHECK_CAFILE` (a file variable) to staging's roots. The fleet then serves an untrusted certificate
  until the next production run, so do it only in a window, and force the production renewal right after
  (both runs order; stay well inside Let's Encrypt's limits).
- **The first run** registers the ACME account (no `ACME_EMAIL`, so no contact address unless one is set)
  and keeps it in `acme-account-seatrials`. Losing that version costs only a new registration.

Its tests, run by `checks`: [`ci/cert-check_test.sh`](../ci/cert-check_test.sh) (certificates made with
`openssl`), [`ci/cert_test.sh`](../ci/cert_test.sh) (stub `gcloud` and `lego`: lego obtains only on
missing, expired, wrong-hostname or invalid; never for a supplied certificate; a new version only for a
certificate that passes the check; nothing secret on its output),
[`ci/cert-install_test.sh`](../ci/cert-install_test.sh), [`ci/lib_test.sh`](../ci/lib_test.sh) (`ci_cert`) and
[`ci/pipeline_test.sh`](../ci/pipeline_test.sh) (`cert` before `generate` and `diff`, its version taken by
every job that renders, no rule that skips it on a schedule).

### The daily schedule

A pipeline schedule of the GitLab project runs the whole pipeline on `main` every day: `cert`, then images,
generate, diff, apply and test. When nothing is due, the version doesn't change and the apply changes
nothing. When `cert` renewed, the new version is rendered, diffed and applied by itself (seatrials isn't
production), and every gateway serves it with no restart. The schedule lives in the GitLab project, not in
this repository: set it up once (Build, Pipeline schedules, New schedule), target branch `main`, daily, for
example `17 5 * * *` UTC, with no variables. The parent pipeline's `workflow` already admits `schedule`, and
`ci/pipeline_test.sh` checks that nothing skips `cert` or the apply on one.

## Secrets: GitLab project variables only

Every secret is a **protected variable of the GitLab project**, never of the group: group variables reach
tacplus-dev/looper, where agents run. No key material is committed to this repository: `ci/secrets.sh` fails on any, in
the deploy pipeline's `checks` and on every push to GitHub (`.github/workflows/secrets.yml`, #22). The kernel's
TLS keys are the cluster PKI in `FLEET_CRYPTO_YAML`; `services/kernel.yaml` has no `tls` block (the one
`schematic-operator init` writes is a placeholder the operator never renders). Masked variables are also *hidden*. The jobs place the file variables
under `deploy/bootstrap/` (git-ignored) with mode 600. They remove them when the job ends, and no artifact
includes them: the artifacts are `bin/`, the render's digest, the certificate's secret name and version
number, the suite's report and the security report (gitleaks' findings redacted). The fleet's certificate and
its key aren't variables: they are versions in Secret Manager ([the certificate](#the-certificate)).

| Variable | Type | Scope | What |
| --- | --- | --- | --- |
| `TACPLUS_READER_APP_ID` | plain | all | The `tacplus-reader` GitHub App's id. Not a secret ([below](#github-the-tacplus-reader-app-no-stored-token)). |
| `TACPLUS_READER_INSTALLATION_ID` | plain | all | Its installation on tacplus-dev. Not a secret. |
| `GCP_WIF_PROVIDER` | plain, protected | all | `projects/1038314073791/locations/global/workloadIdentityPools/gitlab-com/providers/tacplus-dev-fleet-seatrials`, tacplus-dev/cloud's provider for this project's protected `main` ([below](#gcp-workload-identity-federation-no-key-files)). |
| `FLEET_CRYPTO_YAML` | file | `seatrials*` | `deploy/bootstrap/crypto.yaml`, the fleet's CA and cluster PKI (already stored; its scope widens from `seatrials` to `seatrials*`). A new deployment's is **generated** by `init-secrets`, gzipped, base64-encoded and masked, in parts of at most 10,000 characters. |
| `FLEET_CRYPTO_YAML_2`, `_3`, ... | file, masked, hidden | `seatrials*` | The further parts of a generated `FLEET_CRYPTO_YAML`, which `ci_crypto` joins ([below](#generated-secrets-the-init-secrets-job)). |
| `FLEET_CA_PEM` | file | `seatrials*` | `deploy/bootstrap/ca.pem` (already stored; scope as above). Generated with `FLEET_CRYPTO_YAML`. |
| `FLEET_INIT_TOKEN` | masked, hidden | `init-secrets` | The deployment's bot user's personal access token (`api`). The bot is a Maintainer of this project only. `init-secrets` writes the generated variables with it ([below](#generated-secrets-the-init-secrets-job)). |
| `FLEET_MICROSOFT_CLIENT_SECRET` | masked | `seatrials*` | The Entra client secret **value** of `seatrials-web` (`deploy/signin-secrets.sh` refuses a Secret ID). |
| `FLEET_APPLE_KEY_P8` | file | `seatrials*` | The Sign in with Apple key `AuthKey_D9JNT33239.p8`. |
| `FLEET_DEPLOY_COMMIT` | plain | optional | A full commit hash to deploy instead of main's head. |

The `seatrials*` scope reaches the environment `seatrials`. The test IdP's seeds are not variables: they are
the Secret Manager secret `test-idp-seeds` ([the test IdP](#the-test-idp)). Nor is Google's client secret: it is
the Secret Manager secret `google-signin-seatrials` ([the Google sign-in client](#the-google-sign-in-client)).
`FLEET_GOOGLE_CLIENT_SECRET` is no longer read (`signin-secrets.sh` says so while it exists): delete it.
`deploy/signin-secrets.sh` keeps the cluster's current value of any sign-in secret whose variable is unset.
Until all three are in GitLab, the secrets already on the cluster stay in place.

### Generated secrets: the init-secrets job

A deployment's own key material is generated in the pipeline, never on a laptop (Jody, 2026-11-01). On a
deployment's first run, the manual job `init-secrets` ([`deploy/init-secrets.sh`](../deploy/init-secrets.sh))
runs `schematic-operator init ca` and then `init cluster` for `operator.yaml`'s fqdn, as `deploy/init.sh` did.
It works in a copy of `deploy/bootstrap` and stores the results as protected file variables of scope
`seatrials*`: `FLEET_CRYPTO_YAML` (the root CA and the cluster PKI) and `FLEET_CA_PEM`. No job prints them:
`ci_crypto` places them in files.

crypto.yaml is some 23,000 bytes for this topology, and GitLab caps a variable's value at 10,000 characters.
The job stores it gzipped and base64-encoded on one line, which GitLab can mask and hide. Encoded, it comes to
about 10,000 characters, sometimes just over, so it is split into parts of at most 10,000: `FLEET_CRYPTO_YAML`,
then `FLEET_CRYPTO_YAML_2` and on, each masked and hidden. `ci_crypto` joins them in order, up to the first that
isn't set, and decodes them. It still takes a plain crypto.yaml in `FLEET_CRYPTO_YAML`, as seatrials' is stored.
`FLEET_CA_PEM`, a certificate, holds no secret; a PEM's lines can't be masked. The job:

- skips both if both exist, and generates nothing (seatrials' are already stored);
- refuses if only one exists, because a CA and its crypto.yaml are a pair. Restore the other, or delete the one
  that's there to generate both;
- refuses, storing nothing, if crypto.yaml would take more than nine parts, or if a part such as
  `FLEET_CRYPTO_YAML_2` is left from an earlier run (`ci_crypto` would join it to the new one): delete it;
- stores `FLEET_CRYPTO_YAML` first, so a run that stops part-way is refused the next time, never stored twice:
  delete `FLEET_CRYPTO_YAML` and its parts and run it again;
- reads only the status of the API's answer when it checks a variable, because that answer holds the value.

Writing variables needs a Maintainer token. gitlab.com Free has no project access tokens, so the hub creates a
**bot user per deployment**, a Maintainer of this one project only, and stores its personal access token as
`FLEET_INIT_TOKEN`: protected, masked and hidden, in the scope `init-secrets`. Only the protected environment
`init-secrets` (deployable by Maintainers) has that scope, and only this job uses it. The token can read every
variable of the project, as any Maintainer can, so it never reaches another job.

On a new deployment's first pipeline, `generate` fails because there's nothing to generate from. Run
`init-secrets` (it needs only `tools`), then run the pipeline again.

**Third-party secrets** are entered once per deployment, keyless where the provider allows. Apple's `.p8` is
entered once (`FLEET_APPLE_KEY_P8`), and oauth mints the client-secret JWT from it for each request, so no Apple
secret expires. Google's client secret is added once, in Secret Manager ([below](#the-google-sign-in-client)). Microsoft without a secret (Entra federated credentials)
needs oauth to authenticate to Entra with a client assertion, which it can't do yet (PROPOSALS.md). Until then,
the secret is rotated by hand, as below.

**Rotating the Microsoft secret** (every 6 months; the current one expires around 2027-04-27, #6):

1. Create a new client secret on `seatrials-web` in Entra.
2. Paste its value into `FLEET_MICROSOFT_CLIENT_SECRET` in the GitLab project.
3. Run `signin-secrets`, then check that a Microsoft sign-in works.
4. Remove the old secret in Entra.

Doing all of this inside the pipeline is the next step (PROPOSALS.md).

### The Google sign-in client

seatrials' Google sign-in is the OAuth web client `seatrials-web` in the project `tacplus-dev` (seabeam.net),
beside the deployment's other resources (#46). Google has no public API that writes a consent screen, a web
client, its redirect URIs or its secrets: the only one, IAP's OAuth Admin API, was shut down on 2026-03-19, and
the Console shows a secret only once, when it is made. So **one step is Jody's, in the Console, once**; the
pipeline does the rest, and checks with Google itself what it can't write.

| | Who | How |
| --- | --- | --- |
| Consent screen (Google Auth Platform: branding, audience) | Jody, once | Console |
| The client and its redirect URIs | Jody, once; the pipeline checks them | Console; `deploy/google-client.sh client`, the test stage's `signin/google-client` |
| The secret | Jody adds it; the pipeline reads, checks and installs it | Secret Manager `google-signin-seatrials`; `ci_google_signin`, `deploy/signin-secrets.sh` |
| Rotation | Jody, when wanted (Google's secrets don't expire) | Console, then a new version, as below |

**Jody's one step**, in the Console of `tacplus-dev`, once tacplus-dev/cloud has made the secret
`google-signin-seatrials` (no version; `seatrials-deploy` its reader; tacplus-dev/cloud#37):

1. Google Auth Platform, *Branding*: app name `seatrials`, the support email, authorized domain `tacplus.dev`.
   *Audience*: External, then *Publish app*. The scopes are `openid`, `email` and `profile` only, which Google
   does not ask to verify.
2. *Clients*, *Create client*: Web application, name `seatrials-web`, authorized redirect URI
   `https://seatrials.tacplus.dev/` (each of the Google provider's `allowed_redirect_uri_prefixes` in
   `deploy/bootstrap/services/oauth.yaml`: oauth sends Google the caller's callback as is). Then *Download JSON*
   in the dialog that shows the secret.
3. Secret Manager, `google-signin-seatrials`, *New version*, *Upload file*: that JSON. Delete the local file.

Nothing is typed or pasted, and no agent sees the secret. Then the switch, by a commit: the next `apply` (or
`signin-secrets`) refuses the JSON, naming its `client_id`, until that id is Google's `client_id` in `oauth.yaml`.
Once that is committed and a Google sign-in works on the new client, the old client (in the project the
thescottsweb.com org is closing) is deleted, and the GitLab variable `FLEET_GOOGLE_CLIENT_SECRET` with it.

**What the pipeline does.** `apply` and `signin-secrets` read the latest version of `google-signin-seatrials`
through WIF as `seatrials-deploy` (`ci_google_signin` in [`ci/lib.sh`](../ci/lib.sh)); with no version yet, or
refused, they say so and oauth keeps the Google secret the cluster holds. A version is the client JSON the
Console downloads, whose `client_id` must be `oauth.yaml`'s, or a bare secret. Before installing it,
`deploy/signin-secrets.sh` asks Google whether it takes the secret (`deploy/google-client.sh secret`: the token
endpoint answers a bogus code with `invalid_grant` for a good secret, `invalid_client` for a bad one), and refuses,
installing nothing, a secret Google refuses, since it would take Google sign-in down. If Google does not answer,
the secret is installed unchecked, saying so. After every deploy, `signin/google-client` asks Google's authorize
endpoint whether it knows the client and each redirect URI (`deploy/google-client.sh client`: an unknown client
or an unregistered URI is sent to `/signin/oauth/error`, `invalid_client` or `redirect_uri_mismatch`). Neither
check needs a person or a user's account.

**Rotating the Google secret** (no date forces it): on the client in the Console, *Add secret*; add the new secret
as a new version of `google-signin-seatrials` (a bare secret, or a JSON `{"web": {"client_id": ..., "client_secret":
...}}`); run `signin-secrets`, which checks it with Google and installs it; then *disable* the old secret on the
client, and disable the old version. Google says it deletes OAuth clients that go unused for months, so a client
seatrials stops using for long must be checked before it is relied on.

**Who can read the variables:** the project's Maintainers and Owners, and the group's Owners, through the UI
and the API. Before any secret is stored there, no token an agent holds may have Maintainer or higher on
this project. Today the loopers' `GITLAB_TOKEN` is a group Owner token with `api` scope, so it can read these
variables and start the protected jobs (tacplus-dev/looper#25).

There is **no GitHub token** among them ([below](#github-the-tacplus-reader-app-no-stored-token)). A job
that holds a variable shaped like one (`ghp_`, `github_pat_`, `gho_`, `ghu_`, `ghs_`, `ghr_`) refuses to run,
so the read-only GitHub token stored before #29 must be deleted from the project.

## GitHub: the tacplus-reader app, no stored token

This repository is private, so the jobs need a credential to fetch it, and none is stored (#29). Every job
that fetches it, `fleet-plan` and each job of the child pipeline, mints its own token of the keyless
`tacplus-reader` GitHub App first, as tacplus-dev/build does (tacplus-dev/looper README, Credentials). The
code is the `.github-reader` block, the same in both pipeline files:

1. The job's GitLab ID token (`GCP_ID_TOKEN`) is exchanged through Workload Identity Federation, in the pool
   below, as the job itself (no service account).
2. Cloud KMS signs the app's JWT with the key `tacplus-reader` (key ring `looper`, `us`, in jody1-328023 until
   it moves, tacplus-dev/cloud#15), which never leaves KMS. The job asks as itself first. If KMS refuses that principal (HTTP 401 or 403), the job asks again as
   the service account `fleet-seatrials-reader@jody1-328023.iam.gserviceaccount.com` (`TACPLUS_READER_SA`),
   which it may impersonate (#30). Each refusal is logged with KMS's HTTP status and error, for example
   `Cloud KMS refused to sign with … as the job itself: HTTP 403 PERMISSION_DENIED: Permission
   'cloudkms.cryptoKeyVersions.useToSign' denied …`. A token, the JWT and the request are never logged. Any
   other refusal (a missing or disabled key version, say) is not retried: the service account would get it too.
3. GitHub answers with a one-hour installation token, `contents: read` on tacplus-dev/fleet-seatrials alone.
   Only the fetch's `git` holds it, through a credential helper. It is in no file, no command line and
   no job script's environment.

Everything else the jobs fetch from GitHub (tacplus, operator, launcher and every service repository in
`fleet.lock`) is public, and `ci_github` gives git no credential for it. `ci/github_reader_test.sh` checks
that no pipeline file references a static GitHub token, and runs the block against a stub WIF, KMS and
GitHub.

**What the hub sets up** (once; the key and the app already exist for tacplus-dev/build):

- The `tacplus-reader` app installed on tacplus-dev/fleet-seatrials, if its installation selects repositories.
- The key's binding for this project's protected main. The job federates through `GCP_WIF_PROVIDER`, tacplus-dev's
  pool `gitlab-com`, whose provider admits only tacplus-dev/fleet-seatrials on protected `main`. The KMS key is
  still in jody1-328023 (KMS keys stay until they move), so its binding names the principal of that other
  project's pool (**Jody**: the key's IAM is his).
  It is a step of the cutover ([below](#the-cutover-to-dev)): with only the old pool's binding, every job fails
  to fetch this repository once `GCP_WIF_PROVIDER` is the new provider:

  ```sh
  kms_project=jody1-328023   # the KMS key's project, until it moves
  principal=principalSet://iam.googleapis.com/projects/1038314073791/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/fleet-seatrials
  gcloud kms keys add-iam-policy-binding tacplus-reader --keyring=looper --location=us --project=$kms_project \
    --role=roles/cloudkms.signer --member="$principal"
  ```

- If the dry run's log shows the direct principal refused (the first dry run, pipeline 3015778552, failed
  there; #30): the service account the job falls back to. It has no role but signing with this one key, and
  only this project's protected main may impersonate it. **The hub** creates it and lets the pool's
  principalSet impersonate it (an IAM change, with Jody's OK, as for `seatrials-deploy` below). It is not
  `seatrials-deploy`, which also holds Cloud Build and the cluster:

  ```sh
  reader_project=jody1-328023   # the reader's project, until it moves
  sa=fleet-seatrials-reader@$reader_project.iam.gserviceaccount.com
  principal=principalSet://iam.googleapis.com/projects/1038314073791/locations/global/workloadIdentityPools/gitlab-com/attribute.project_path/tacplus-dev/fleet-seatrials
  gcloud services enable iamcredentials.googleapis.com --project=$reader_project   # if it is not already
  gcloud iam service-accounts create fleet-seatrials-reader --project=$reader_project \
    --display-name="fleet-seatrials: signs as the tacplus-reader app"   # if it does not exist yet
  gcloud iam service-accounts add-iam-policy-binding $sa --project=$reader_project --role=roles/iam.workloadIdentityUser \
    --member="$principal"
  ```

  **Jody** binds it to the key (the key's IAM is his):

  ```sh
  gcloud kms keys add-iam-policy-binding tacplus-reader --keyring=looper --location=us --project=jody1-328023 \
    --role=roles/cloudkms.signer --member=serviceAccount:fleet-seatrials-reader@jody1-328023.iam.gserviceaccount.com
  ```

  Once the job signs through one path, the other path's binding can be removed (PROPOSALS.md).
- `TACPLUS_READER_APP_ID` and `TACPLUS_READER_INSTALLATION_ID` in the project (the table above): the same
  values tacplus-dev/build holds.

## GCP: Workload Identity Federation, no key files

seatrials deploys to tacplus-dev/cloud's `dev` stack in seabeam.net: the project `tacplus-dev` and its GKE
cluster `dev` (us-central1-a), in the namespaces tacplus-dev/cluster gives it (#39; tacplus-dev/roadmap
`decisions/only-vms-are-k8s-nodes-2026-11-04.md`, addendum "a new cluster in seabeam.net"). The jobs reach GCP
as the service account `seatrials-deploy@tacplus-dev.iam.gserviceaccount.com`. Each job exchanges its GitLab
ID token (`id_tokens: GCP_ID_TOKEN`, audience `https://iam.googleapis.com/$GCP_WIF_PROVIDER`) for a
short-lived Google token (`ci_gcp` in [`ci/lib.sh`](../ci/lib.sh)), through the provider
`projects/1038314073791/locations/global/workloadIdentityPools/gitlab-com/providers/tacplus-dev-fleet-seatrials`,
which admits only this project's protected `main`. No key file exists. Nothing here is made by hand: the
account, its provider and its roles are tacplus-dev/cloud's (the `dev` stack's deployment `seatrials`), and
its rights in the cluster are tacplus-dev/cluster's (`deployments.yaml`). The pipeline file names the target
(`GCP_PROJECT`, `CLUSTER`, `ZONE`, `GCP_DEPLOY_SA`, `REGISTRY`); `ci/target_test.sh` checks it, the scripts'
defaults, and that nothing else names jody1-328023 but the reader and its KMS key.

`GCP_DEPLOY_SA` is the pipeline file's. If the project sets it as a variable too, scope it to `seatrials*`: an
unscoped project variable overrides every job's own, the test IdP's jobs' `test-idp-deploy` included.

What the account may do, and nothing more:

- **Its certificate** (#35): it adds and reads the versions of its secrets `tls-seatrials` and
  `acme-account-seatrials`, and administers the zone `_acme-challenge.tacplus.dev`. The `dev` stack makes these.
- **Cloud Build** (images), in tacplus-dev: `roles/cloudbuild.builds.editor` and
  `roles/serviceusage.serviceUsageConsumer` on the project. `roles/storage.admin` on the bucket
  `gs://tacplus-dev-seatrials-build` only (us-central1, uniform access, public access prevented, objects deleted
  after 7 days), where `images/build.sh` has `gcloud builds submit` stage the source
  (`--gcs-source-staging-dir .../source`) and write the build logs (`--gcs-log-dir .../logs`); the account the
  builds run as has `roles/storage.objectAdmin` on it. Not the project's default bucket: staging there, gcloud
  first checks that the bucket belongs to the project by listing the project's buckets, which needs
  `storage.buckets.list` on the whole project, and the synchronous submits stream their logs from the default
  logs bucket, which needs project Viewer. `roles/iam.serviceAccountUser` on the service account the builds run
  as, `seatrials-build@tacplus-dev.iam.gserviceaccount.com`, and on no other: every submit names it
  (`--service-account`), since the default Cloud Build account has no rights here. It pushes to the registry and
  has `roles/storage.objectAdmin` on the bucket.
- **The registry** `us-central1-docker.pkg.dev/tacplus-dev/seatrials` (`REGISTRY`): Docker, us-central1, the
  fleet's images (`schematic/<service>`, `ci/tacplus-build`). `roles/artifactregistry.reader` on it, so
  `images/build.sh` can read the `fp-` tags; the builds' account writes it, and the `dev` nodes' account
  (`gke-nodes`) reads it. It is a deploy registry, not tacplus-ci's `build-cache`: that one is BuildKit's
  cache, written and read only by tacplus-dev/build's identity and emptied of what is 30 days old, so the
  nodes could not pull from it and a running fleet's images would go.
- **The cluster `dev`:** `roles/container.clusterViewer` with the IAM condition
  `resource.name == "projects/tacplus-dev/locations/us-central1-a/clusters/dev"`, enough for `get-credentials`.
  In the cluster, what tacplus-dev/cluster's `deployments.yaml` gives `seatrials-deploy`: its Role in
  `tac-seatrials`. The fleet still renders into the namespace `schematic`, with cluster-scoped objects, so it
  applies on `dev` only once it moves to `tac-seatrials` (#4).

The `dev` stack makes the Cloud Build, registry and cluster grants, with the test IdP's account
([below](#the-test-idp)) (tacplus-dev/cloud#20, applied 2026-11-08).

### The cutover to `dev`

In order (#39):

1. **The hub** sets the project's protected `GCP_WIF_PROVIDER` to the provider above (and `GCP_DEPLOY_SA`, if
   the project carries it, to `seatrials-deploy@tacplus-dev.iam.gserviceaccount.com`, scoped to `seatrials*`).
   **Jody** binds the new pool's principal on the `tacplus-reader` key, and the hub on `fleet-seatrials-reader`
   if the jobs sign as it ([above](#github-the-tacplus-reader-app-no-stored-token)), the same day: from then
   on, the jobs federate through tacplus-dev's pool, and the reader is asked as that principal.
2. This repository's retarget lands (#39).
3. **The hub** re-pins the project's `.gitlab-ci.yml`.

The first deploy on `dev` waits for the certificate (#35), Jody's DNS cutover (tacplus-dev/cloud#13), the
grants above and the move to `tac-seatrials` (#4).

## The runner

Deploy jobs never share a VM with agent jobs. Every job here, `fleet-plan` included, is tagged `deploy`:

- A **project runner** registered to tacplus-dev/fleet-seatrials only, not the group. It is locked to the
  project, takes no untagged jobs and has the tag `deploy`. Use the docker-autoscaler executor with
  `max_use_count = 1`, so each job gets a fresh VM, and an image that is multi-arch or built for the VM's
  architecture (`ghcr.io/tacplus-dev/tacplus/build:2.6.4`, pinned by digest, is both).
- The VMs' own service account has no roles. GCP is reached through federation only.
- Turn off group runners on this project (Settings → CI/CD → Runners). The tag alone already keeps the
  group's agent runner away, since its tags are `arm64` and `autoscale`.

## One-time setup (the hub, #18)

1. Make the GCP side above (Jody's OK). Set `GCP_WIF_PROVIDER` in the project. Then the GitHub side: the
   `tacplus-reader` key's binding and the app's installation ([above](#github-the-tacplus-reader-app-no-stored-token)).
2. Register the deploy runner and turn off group runners on the project.
3. Create the protected environments `seatrials` and `init-secrets`, both deployable by Maintainers
   (`seatrials-letsencrypt` is retired with letsencrypt, #35: delete it). For a new deployment, create its bot
   user and store `FLEET_INIT_TOKEN` ([above](#generated-secrets-the-init-secrets-job)). Keep `main` protected. `apply` runs by itself as whoever started the pipeline (or owns its
   schedule), so that user must be able to deploy to `seatrials`.
4. Store the variables in the table above, once tacplus-dev/looper#25 is fixed. There is no GitHub token
   to store. Jody pastes the sign-in
   secrets into the GitLab UI directly: not through a chat, a terminal or a file.
5. Commit `ci/gitlab-project.gitlab-ci.yml` to the project as `.gitlab-ci.yml`.
6. **First run:** Build → Pipelines → Run pipeline on `main`. tools, checks, images, generate and diff must be
   green, and `apply` then deploys by itself.
7. Add [the daily schedule](#the-daily-schedule): it renews the certificate when due, and its `apply` puts
   main back on any drift.

## The test IdP

The test IdP (#27, [test-idp/README.md](../test-idp/README.md)) is a Keycloak in the namespace `tac-test-idp` of
the `dev` cluster (tacplus-dev, us-central1-a), at https://idp.test.tacplus.dev:8443. Its realms emulate Google's,
Microsoft's and Apple's claim shapes, so sign-in is tested with no person. It is a pod, never a VM (Jody,
2026-11-06).

**Its jobs:**

- `test-idp` applies it ([`test-idp/apply.sh`](../test-idp/apply.sh)): the seeds (generated the first time and
  stored in the secret `test-idp-seeds`), the
  certificate ([`ci/cert.sh`](../ci/cert.sh) with the test IdP's own secrets and zone), the Secrets
  `keycloak-tls`, `keycloak-admin` and `keycloak-realms`, and `test-idp/keycloak.yaml`, rolled out when the
  realms or the certificate changed. It is manual, and it changes nothing of the fleet.
- `test-idp-signin` runs the same apply, then checks it, and tacplus.dev's sign-in through it. So every
  pipeline, the daily schedule's too, keeps the test IdP as main has it and renews its certificate when due.

Both run as their own service account, `test-idp-deploy@tacplus-dev.iam.gserviceaccount.com`, never as
`seatrials-deploy`. They are in their own protected environment, `test-idp`.

**Its exposure** (tacplus-dev/cloud#21): port 8443 of the address `gateway`, through cloud's TCP proxy load
balancer, its listener `test-idp`, to the NEG `seatrials-test-idp` that the Service `keycloak` names (endpoints on
8443). TLS ends in the pod, at haproxy, which forwards only the three test realms and `/resources`; the master
realm and the admin API are reached in the cluster only, by the admin Job ([`test-idp/admin-job.yaml`](../test-idp/admin-job.yaml)),
since the cluster refuses port-forward to a deploy account. The A record `idp.test.tacplus.dev` to `gateway` is
cloud's.

**What the platform provides.** Nothing is made by hand on `dev`. Made (tacplus-dev/cloud#20): the account,
which only this project's jobs in the environment `test-idp`, on protected `main`, may become (the provider maps
the job's environment, and the binding names this project and that environment together, since the pool
`gitlab-com` is shared by tacplus-dev's projects), with `roles/container.clusterViewer` conditioned on the cluster
`dev`; the record `idp.test.tacplus.dev`; the listener `test-idp`, `ready = false` (no backend). Filed by the hub
(2026-11-09):

- **tacplus-dev/cloud#32, the dev stack:**
  - the secrets `tls-test-idp` and `acme-account-test-idp` in `tacplus-dev`, `test-idp-deploy` their only
    `secretVersionAdder` and `secretAccessor`, as `seatrials-deploy` is for its own;
  - the zone `acme-challenge-idp-test-tacplus-dev` for `_acme-challenge.idp.test.tacplus.dev.`, delegated from
    the zone `tacplus-dev` by NS records, `test-idp-deploy` its only `dns.admin`: the fleet's challenge zone,
    `_acme-challenge.tacplus.dev`, is `seatrials-deploy`'s alone, and the certificate is the test IdP's own;
  - the secret `test-idp-seeds`, `test-idp-deploy` its version adder and accessor: the seeds, generated by the
    `test-idp` job's first run, with no GitLab token (gitlab.com Free has no project access tokens; the hub,
    2026-11-09, as tacplus-dev/cloud#28's option D does for the fleet's secrets);
  - once the first apply has made the NEG `seatrials-test-idp` (`apply.sh` prints its status), `ready = true`
    for the listener `test-idp`.
- **tacplus-dev/cluster#17:** the deployment `test-idp` in `deployments.yaml` (`deployAccount`
  `test-idp-deploy@tacplus-dev.iam.gserviceaccount.com`, `gitlabProject` tacplus-dev/fleet-seatrials, `quota: {}`),
  which gives the namespace `tac-test-idp` and the account's `fleet-deploy` Role in it. It has no operator, so
  `operator` becomes optional in `render.sh` and `ci/policy.sh` (no deploymentproxy Role and no operator binding
  without one). `fleet-deploy` already covers every object here: the Deployment, Services, Secrets, ConfigMap,
  the admin Job and pod logs. No storage class: the database is in the pod. No NetworkPolicy: the admin API
  authenticates and is not exposed (Jody, 2026-11-07: bearer tokens isolate, not reachability).

Not filed yet: **`secretAccessor` for `seatrials-deploy` on `test-idp-seeds`** (read only). seatrials' own jobs
need the seeds too: `apply` and `signin-secrets` derive the `Test *` providers' client secrets from
`TEST_IDP_CLIENT_SEED`, and the `test` job signs the test users in with `TEST_IDP_SEED`. They read the secret
with `ci_test_idp_seeds optional` ([`ci/lib.sh`](../ci/lib.sh)): refused, they say so and go on without it, the
`Test *` providers off and the suite's test-IdP sign-ins waiting.

Then, in the GitLab project:

1. The protected environment `test-idp`, deployable by Maintainers (made by hand since #18).
2. Run `test-idp`. It generates the two seeds and adds them as the first version of `test-idp-seeds`.
3. Run `signin-secrets`, so that oauth's `Test *` providers get their secrets.

**tacplus.dev's side:** oauth lists `Test Google`, `Test Microsoft` and `Test Apple`
(`deploy/bootstrap/services/oauth.yaml`), with the issuers `https://idp.test.tacplus.dev:8443/realms/<realm>`.
`deploy/signin-secrets.sh` enables each only once it has its secret and its realm answers, since oauth refuses its
whole config over one provider it cannot use. A test IdP that is down therefore never takes the real providers
with it. `deploy/checks.sh signin` reports a provider that is off as skipped, not failed.

## The functional suite

The `test` job runs every platform capability SeaBeam relies on against the deployed fleet, after every deploy.
SeaBeam starts once the suite is green on the cluster seatrials deploys to, now `dev` (Jody, 2026-10-31, of the
`tacplus` cluster it replaced: "I just mean everything
works"). Each item of [`deploy/e2e.yaml`](../deploy/e2e.yaml) is a named test (`capability/test`) that says
what it proves. It has either a `run` that passes or fails, or the open issues it `waits_on`. An item that
can't run yet is reported as **WAITING**, with those issues and why, and is never left out. In GitLab's test
report it shows as *skipped*. The suite fails if any item that ran failed. `deploy/e2e.sh --list` lists the
items, and `deploy/e2e_test.sh` tests the runner.

| Capability | Items | Today |
| --- | --- | --- |
| The fleet up | `platform/pods-ready`, `gateway-cert`, `kernel-jwks`, `routing-policy` | Run (`deploy/checks.sh`) |
| Sign-in, session and token issuance | `signin/providers-listed`; `google-session`, `microsoft-session`, `oidc-session` through the test IdP | `providers-listed` runs. The sessions run once the job has the test IdP's seeds; until then they wait on #27 |
| Tenants: creation, routing by route field, cross-tenant calls refused (users, services) | `tenants/*` | Wait on #14 (the fleet's client), #27, tacplus-dev/tacplus#258 |
| Each service's public RPCs, through the gateway and S2S | `rpcs/through-gateway`, `rpcs/s2s` | Wait on #14 |
| Records: Get, InsertIfAbsent, ReplaceIfUnchanged, Apply across maps, Watch resume | `records/*` | Wait on #14 |
| The member port with two tenants' members; streams ended at token expiry | `members/two-tenants`, `streams/end-at-token-expiry` | Wait on #3 (per-tenant Stratum) and #14 |
| Redo durability levels; a kernel restart without losing data | `redo/durability-levels`, `kernel/restart-keeps-data` | Wait on #3 and #14 |
| The two-terminal event trace | `trace/two-terminal` | Waits on tacplus-dev/tacplus#265, #14, #27 |

The sign-in items use the test IdP only: there is no Entra test tenant or Google Cloud Identity account (Jody,
2026-11-01). They need both of its seeds in the `test` job, which reads them from the secret `test-idp-seeds`
([the test IdP](#the-test-idp)). A test user's password is derived from it, and the job never prints one.

When an issue an item waits on closes, the item gets its `run`. The login-continuity check around every deploy
(Jody, 2026-11-01) comes later, and is not needed for the SeaBeam gate: it's in PROPOSALS.md.

## Running it

- **Deploy:** run the pipeline on `main` (web or API). It deploys main's head, or `FLEET_DEPLOY_COMMIT`.
  `diff` lists what changes, `apply` follows by itself, then `test`.
- **The certificate:** `cert`'s log says the version and its state, and whether lego renewed. To replace it
  now (a key compromise, a hostname change), disable the secret's enabled versions in Secret Manager and run
  the pipeline: `cert` finds none and obtains a new one.
- **A failed test:** the job's report names the failing item and its output. `deploy/checks.sh <check>` runs one check alone,
  in a job with the same setup.
