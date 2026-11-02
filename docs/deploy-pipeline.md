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
| tools | `tools` | Builds `bin/`: tacplus at `images/pins.yaml`'s `tacplus_commit`, `schematic-operator` (`deploy/build-operator.sh`), yq, opa and gitleaks ([`ci/tools.sh`](../ci/tools.sh)). `bin/` is the pipeline's only artifact, and it holds no secret. |
| checks | `checks` | Runs the script tests ([`ci/checks.sh`](../ci/checks.sh)), which include the letsencrypt guard's, and the secrets scan ([`ci/secrets.sh`](../ci/secrets.sh)): gitleaks over the history and the tree at HEAD. |
| images | `images` | Runs `WAIT=1 images/build.sh changed` on Cloud Build and waits for every build it submitted. The job fails if any build fails. Each image is built for `images/pins.yaml`'s `platforms` (`[arm64]`). |
| generate | `generate` | Runs `schematic-operator generate` with `deploy/bootstrap/crypto.yaml` and `ca.pem` taken from `FLEET_CRYPTO_YAML` and `FLEET_CA_PEM`, then the routing check: `deploy/checks.sh opa` (`opa eval`) on the rendered `tenants/namespace.rego`. Each tenant's claim matcher must route to that tenant, and a different claim value to none. |
| diff | `diff` | [`deploy/diff.sh`](../deploy/diff.sh): `kubectl diff` of the render (`schematic-operator apply --dry-run`) against seatrials. It prints object **names** only. It **fails if the change touches letsencrypt** (see below). |
| apply | `apply` | Manual, in the protected environment `seatrials`. Runs the guard again, then `deploy/secrets.sh`, `deploy/apply.sh` and `deploy/signin-secrets.sh`. |
| apply | `apply-letsencrypt` | Manual, in the protected environment `seatrials-letsencrypt`, whose only deployer is Jody. The same apply, with the letsencrypt guard lifted. |
| apply | `signin-secrets` | Manual, environment `seatrials`. Re-installs the sign-in secrets from the variables and nothing else. |
| apply | `test-idp` | Manual, in the protected environment `test-idp`: the test IdP on the `tacplus` cluster, its realms and its DNS record ([`test-idp/apply.sh`](../test-idp/apply.sh); [below](#the-test-idp)). |
| test | `test-idp-signin` | [`test-idp/signin.sh`](../test-idp/signin.sh): each realm's discovery and every test user's claim shape. One user per emulated provider signs in at tacplus.dev and gets a kernel session. The removed user is refused. Until the `test-idp` job has set the test IdP up (the environment `test-idp` has no `TEST_IDP_SEED`), it skips, saying so, without asking GCP or the cluster for anything. |
| test | `test` | After `apply`: [`deploy/checks.sh all`](../deploy/checks.sh). Every pod Ready; the gateway serves a publicly trusted certificate for seatrials.tacplus.dev, valid for 14 more days; OIDC discovery names the host and its JWKS has keys; the sign-in smoke test; the routing check. |

Without `apply`, a pipeline is a **dry run**: tools, checks, images, generate and diff, and `test-idp-signin` once the test IdP is set up.

### The letsencrypt guard

The standing rule is that letsencrypt is never restarted without Jody's explicit OK. Its ACME orders are
rate-limited, and it holds the account key and the certificate.

`kubectl diff` writes each object of the render twice, as it is live and as it would be after the apply. It
then calls [`deploy/letsencrypt-guard.sh`](../deploy/letsencrypt-guard.sh) on both. The guard names each
object that differs, never its content. An object **touches letsencrypt** when:

- it is named for letsencrypt (its Deployment, Service, ServiceAccount and so on);
- it is a ConfigMap, Secret or ServiceAccount that letsencrypt's pods mount or read (volumes, projected
  sources, `envFrom`, `env.valueFrom`), as its Deployment is now or will be;
- it is letsencrypt's Deployment and the render no longer holds it: the helm upgrade would remove it.

`diff` and `apply` fail on any such object. Once Jody has said yes, a change to letsencrypt is applied by
`apply-letsencrypt`, which only Jody can start. The guard's tests are
[`deploy/letsencrypt-guard_test.sh`](../deploy/letsencrypt-guard_test.sh), run by `checks`. To prove the
guard on the cluster, push a test commit to a branch that changes something letsencrypt reads, for example
its image tag or its config. Run the pipeline with `FLEET_DEPLOY_COMMIT` set to that commit. `diff` must
fail and name the objects.

## Secrets: GitLab project variables only

Every secret is a **protected variable of the GitLab project**, never of the group: group variables reach
tacplus-dev/looper, where agents run. No key material is committed to this repository: `ci/secrets.sh` fails on any, in
the deploy pipeline's `checks` and on every push to GitHub (`.github/workflows/secrets.yml`, #22). The kernel's
TLS keys are the cluster PKI in `FLEET_CRYPTO_YAML`; `services/kernel.yaml` has no `tls` block (the one
`schematic-operator init` writes is a placeholder the operator never renders). Masked variables are also *hidden*. The jobs place the file variables
under `deploy/bootstrap/` (git-ignored) with mode 600. They remove them when the job ends, and no artifact
includes them.

| Variable | Type | Scope | What |
| --- | --- | --- | --- |
| `TACPLUS_READER_APP_ID` | plain | all | The `tacplus-reader` GitHub App's id. Not a secret ([below](#github-the-tacplus-reader-app-no-stored-token)). |
| `TACPLUS_READER_INSTALLATION_ID` | plain | all | Its installation on tacplus-dev. Not a secret. |
| `GCP_WIF_PROVIDER` | plain | all | `projects/<number>/locations/global/workloadIdentityPools/gitlab-tacplus-dev/providers/gitlab-com`. |
| `FLEET_CRYPTO_YAML` | file | `seatrials*` | `deploy/bootstrap/crypto.yaml`, the fleet's CA and cluster PKI (already stored; its scope widens from `seatrials` to `seatrials*`). |
| `FLEET_CA_PEM` | file | `seatrials*` | `deploy/bootstrap/ca.pem` (already stored; scope as above). |
| `FLEET_GOOGLE_CLIENT_SECRET` | masked | `seatrials*` | Google OAuth client `seatrials-web`. |
| `FLEET_MICROSOFT_CLIENT_SECRET` | masked | `seatrials*` | The Entra client secret **value** of `seatrials-web` (`deploy/signin-secrets.sh` refuses a Secret ID). |
| `FLEET_APPLE_KEY_P8` | file | `seatrials*` | The Sign in with Apple key `AuthKey_D9JNT33239.p8`. |
| `FLEET_DEPLOY_COMMIT` | plain | optional | A full commit hash to deploy instead of main's head. |
| `TEST_IDP_SEED` | masked, hidden | `test-idp` | The test IdP's users' and admin's passwords are derived from it. **Generated** by the `test-idp` job, never typed ([test-idp/README.md](../test-idp/README.md#secrets)). |
| `TEST_IDP_CLIENT_SEED` | masked, hidden | `test-idp`, and again `seatrials*` | The test IdP's client secrets. Generated by the `test-idp` job; `deploy/signin-secrets.sh` derives the `Test *` providers' secrets from it. |
| `TEST_IDP_GITLAB_TOKEN` | masked | `test-idp`, first run only | A project access token (Maintainer, `api`) with which the `test-idp` job stores the two seeds. It can read every variable here, so revoke it once they are stored. |

The `seatrials*` scope reaches both environments, `seatrials` and `seatrials-letsencrypt`.
`deploy/signin-secrets.sh` keeps the cluster's current value of any sign-in secret whose variable is unset.
Until all three are in GitLab, the secrets already on the cluster stay in place.

**Rotating the Microsoft secret** (every 6 months; the current one expires around 2027-04-27, #6):

1. Create a new client secret on `seatrials-web` in Entra.
2. Paste its value into `FLEET_MICROSOFT_CLIENT_SECRET` in the GitLab project.
3. Run `signin-secrets`, then check that a Microsoft sign-in works.
4. Remove the old secret in Entra.

Doing all of this inside the pipeline is the next step (PROPOSALS.md).

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
2. Cloud KMS signs the app's JWT with the key `tacplus-reader` (key ring `looper`, `us`), which never leaves
   KMS. The job asks as itself first. If KMS refuses that principal (HTTP 401 or 403), the job asks again as
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
- The key's binding for this project's protected main. The pool `gitlab-tacplus-dev` already admits only
  tacplus-dev/fleet-seatrials on protected `main` (its condition, below):

  ```sh
  project=jody1-328023
  number=$(gcloud projects describe $project --format='value(projectNumber)')
  gcloud kms keys add-iam-policy-binding tacplus-reader --keyring=looper --location=us --project=$project \
    --role=roles/cloudkms.signer \
    --member="principalSet://iam.googleapis.com/projects/$number/locations/global/workloadIdentityPools/gitlab-tacplus-dev/attribute.project_path/tacplus-dev/fleet-seatrials"
  ```

- If the dry run's log shows the direct principal refused (the first dry run, pipeline 3015778552, failed
  there; #30): the service account the job falls back to. It has no role but signing with this one key, and
  only this project's protected main may impersonate it. **The hub** creates it and lets the pool's
  principalSet impersonate it (an IAM change, with Jody's OK, as for `seatrials-deploy` below). It is not
  `seatrials-deploy`, which also holds Cloud Build and the cluster:

  ```sh
  project=jody1-328023
  number=$(gcloud projects describe $project --format='value(projectNumber)')
  sa=fleet-seatrials-reader@$project.iam.gserviceaccount.com
  gcloud services enable iamcredentials.googleapis.com --project=$project   # if it is not already
  gcloud iam service-accounts create fleet-seatrials-reader --project=$project \
    --display-name="fleet-seatrials: signs as the tacplus-reader app"
  gcloud iam service-accounts add-iam-policy-binding $sa --project=$project --role=roles/iam.workloadIdentityUser \
    --member="principalSet://iam.googleapis.com/projects/$number/locations/global/workloadIdentityPools/gitlab-tacplus-dev/attribute.project_path/tacplus-dev/fleet-seatrials"
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

The jobs reach GCP as the service account `seatrials-deploy@jody1-328023.iam.gserviceaccount.com`. Each job
exchanges its GitLab ID token (`id_tokens: GCP_ID_TOKEN`, audience
`https://iam.googleapis.com/$GCP_WIF_PROVIDER`) for a short-lived Google token (`ci_gcp` in
[`ci/lib.sh`](../ci/lib.sh)). No key file exists. This is an IAM change: **the hub makes it, with Jody's
OK**.

```sh
project=jody1-328023
number=$(gcloud projects describe $project --format='value(projectNumber)')
pool=gitlab-tacplus-dev provider=gitlab-com sa=seatrials-deploy@$project.iam.gserviceaccount.com
gcloud iam workload-identity-pools create $pool --project $project --location global \
  --display-name "GitLab tacplus-dev"
# Only this project's protected main, and only from gitlab.com.
gcloud iam workload-identity-pools providers create-oidc $provider --project $project --location global \
  --workload-identity-pool $pool --issuer-uri https://gitlab.com \
  --allowed-audiences "https://iam.googleapis.com/projects/$number/locations/global/workloadIdentityPools/$pool/providers/$provider" \
  --attribute-mapping 'google.subject=assertion.sub,attribute.project_path=assertion.project_path,attribute.ref=assertion.ref,attribute.ref_protected=assertion.ref_protected' \
  --attribute-condition 'assertion.project_path == "tacplus-dev/fleet-seatrials" && assertion.ref_type == "branch" && assertion.ref == "main" && assertion.ref_protected == "true"'
gcloud iam service-accounts create seatrials-deploy --project $project --display-name "seatrials deploy pipeline"
gcloud iam service-accounts add-iam-policy-binding $sa --project $project --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/$number/locations/global/workloadIdentityPools/$pool/attribute.project_path/tacplus-dev/fleet-seatrials"
```

What the account may do, and nothing more:

- **Cloud Build** (images): `roles/cloudbuild.builds.editor` and `roles/serviceusage.serviceUsageConsumer` on
  the project. `roles/storage.admin` on the bucket `gs://jody1-328023_cloudbuild` only, where
  `gcloud builds submit` uploads the source. `roles/iam.serviceAccountUser` on the service account the builds
  run as, which already pushes to Artifact Registry. `roles/artifactregistry.reader` on the repository
  `seabeam`, so `images/build.sh` can read the `fp-` tags.
- **The seatrials cluster:** `roles/container.clusterViewer` with the IAM condition
  `resource.name == "projects/jody1-328023/locations/us-central1-a/clusters/seatrials"`, enough for
  `get-credentials`. Then, in the cluster, a ClusterRoleBinding of `cluster-admin` to the user `$sa`: the helm
  release creates cluster-scoped objects. No other cluster, and no other project.

## The runner

Deploy jobs never share a VM with agent jobs. Every job here, `fleet-plan` included, is tagged `deploy`:

- A **project runner** registered to tacplus-dev/fleet-seatrials only, not the group. It is locked to the
  project, takes no untagged jobs and has the tag `deploy`. Use the docker-autoscaler executor with
  `max_use_count = 1`, so each job gets a fresh VM, and an image that is multi-arch or built for the VM's
  architecture (`ghcr.io/tacplus-dev/tacplus/build:2.3` is both).
- The VMs' own service account has no roles. GCP is reached through federation only.
- Turn off group runners on this project (Settings → CI/CD → Runners). The tag alone already keeps the
  group's agent runner away, since its tags are `arm64` and `autoscale`.

## One-time setup (the hub, #18)

1. Make the GCP side above (Jody's OK). Set `GCP_WIF_PROVIDER` in the project. Then the GitHub side: the
   `tacplus-reader` key's binding and the app's installation ([above](#github-the-tacplus-reader-app-no-stored-token)).
2. Register the deploy runner and turn off group runners on the project.
3. Create the protected environments: `seatrials`, deployable by Maintainers, and `seatrials-letsencrypt`,
   deployable by Jody only. Keep `main` protected.
4. Store the variables in the table above, once tacplus-dev/looper#25 is fixed. There is no GitHub token
   to store. Jody pastes the sign-in
   secrets into the GitLab UI directly: not through a chat, a terminal or a file.
5. Commit `ci/gitlab-project.gitlab-ci.yml` to the project as `.gitlab-ci.yml`.
6. **Dry run:** Build → Pipelines → Run pipeline on `main`. tools, checks, images, generate and diff must be
   green; `apply` waits. Optionally add a nightly schedule: its dry run shows drift.
7. Prove the guard on the cluster (above).
8. The first real `apply` is the hub's, with Jody.

## The test IdP

The test IdP (#27, [test-idp/README.md](../test-idp/README.md)) is a Keycloak in the namespace `test-idp` of
the `tacplus` cluster (us-central1-a), at https://idp.test.tacplus.dev. Its realms emulate Google's,
Microsoft's and Apple's claim shapes, so sign-in is tested with no person.

**Its jobs:**

- `test-idp` applies it: the seeds (generated the first time), the admin Secret, `test-idp/keycloak.yaml`,
  the realms through a port-forward, and the A record. It is manual, and it changes nothing of the fleet.
- `test-idp-signin` checks it, and tacplus.dev's sign-in through it.

Both run as their own service account, `test-idp-deploy@jody1-328023.iam.gserviceaccount.com`, never as
`seatrials-deploy`. They are in their own protected environment, `test-idp`.

**One-time setup (the hub, with Jody's OK for the IAM).** After the WIF pool and the runner above:

```sh
project=jody1-328023
number=$(gcloud projects describe $project --format='value(projectNumber)')
pool=gitlab-tacplus-dev provider=gitlab-com sa=test-idp-deploy@$project.iam.gserviceaccount.com
# The provider maps the job's environment too, so a binding can name it.
gcloud iam workload-identity-pools providers update-oidc $provider --project $project --location global \
  --workload-identity-pool $pool \
  --attribute-mapping 'google.subject=assertion.sub,attribute.project_path=assertion.project_path,attribute.ref=assertion.ref,attribute.ref_protected=assertion.ref_protected,attribute.environment=assertion.environment'
gcloud iam service-accounts create test-idp-deploy --project $project --display-name "test IdP pipeline (#27)"
gcloud iam service-accounts add-iam-policy-binding $sa --project $project --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/$number/locations/global/workloadIdentityPools/$pool/attribute.environment/test-idp"
# get-credentials on tacplus only; the record in tacplus-dev only.
gcloud projects add-iam-policy-binding $project --role roles/container.clusterViewer --member "serviceAccount:$sa" \
  --condition 'title=tacplus only,expression=resource.name == "projects/jody1-328023/locations/us-central1-a/clusters/tacplus"'
gcloud dns managed-zones add-iam-policy-binding tacplus-dev --project $project --role roles/dns.admin \
  --member "serviceAccount:$sa"
# The Ingress's address.
gcloud compute addresses create test-idp --global --project $project
# The namespace and the account's rights in it, as cluster-admin.
kubectl --context gke_jody1-328023_us-central1-a_tacplus apply -f test-idp/rbac.yaml
```

Then, in the GitLab project:

1. Create the protected environment `test-idp`, deployable by Maintainers.
2. Set `TEST_IDP_GITLAB_TOKEN` (scope `test-idp`).
3. Run `test-idp`. It stores the two seeds.
4. Revoke the token and delete the variable.
5. Run `signin-secrets`, so that oauth's `Test *` providers get their secrets.

**DNS:** `idp.test.tacplus.dev` answers only once tacplus.dev's nameservers are Cloud DNS's
(`ns-cloud-a1..a4.googledomains.com`, the zone `tacplus-dev`). Jody changes them at GoDaddy, once. The
Google-managed certificate is issued after that, which can take up to an hour.

**tacplus.dev's side:** oauth lists `Test Google`, `Test Microsoft` and `Test Apple`
(`deploy/bootstrap/services/oauth.yaml`). `deploy/signin-secrets.sh` enables each only once it has its secret
and its realm answers, since oauth refuses its whole config over one provider it cannot use. A test IdP that
is down therefore never takes the real providers with it. `deploy/checks.sh signin` reports a provider that is
off as skipped, not failed.

## Running it

- **Dry run or deploy:** run the pipeline on `main` (web or API). It deploys main's head, or
  `FLEET_DEPLOY_COMMIT`. Read the `diff` job's list, then start `apply`; `test` follows.
- **A change touching letsencrypt:** `diff` fails and names the objects. With Jody's OK, Jody starts
  `apply-letsencrypt`. `test` follows `apply` only, so after `apply-letsencrypt` the checks run with the next
  pipeline's `apply`.
- **A failed test:** the job names the failing check. `deploy/checks.sh <check>` runs one check alone,
  in a job with the same setup.
