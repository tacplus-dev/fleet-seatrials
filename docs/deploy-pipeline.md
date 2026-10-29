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
| tools | `tools` | Builds `bin/`: tacplus at `images/pins.yaml`'s `tacplus_commit`, `schematic-operator` (`deploy/build-operator.sh`), yq and opa ([`ci/tools.sh`](../ci/tools.sh)). `bin/` is the pipeline's only artifact, and it holds no secret. |
| checks | `checks` | Runs the script tests ([`ci/checks.sh`](../ci/checks.sh)), which include the letsencrypt guard's. |
| images | `images` | Runs `WAIT=1 images/build.sh changed` on Cloud Build and waits for every build it submitted. The job fails if any build fails. |
| generate | `generate` | Runs `schematic-operator generate` with `deploy/bootstrap/crypto.yaml` and `ca.pem` taken from `FLEET_CRYPTO_YAML` and `FLEET_CA_PEM`, then the routing check: `deploy/checks.sh opa` (`opa eval`) on the rendered `tenants/namespace.rego`. Each tenant's claim matcher must route to that tenant, and a different claim value to none. |
| diff | `diff` | [`deploy/diff.sh`](../deploy/diff.sh): `kubectl diff` of the render (`schematic-operator apply --dry-run`) against seatrials. It prints object **names** only. It **fails if the change touches letsencrypt** (see below). |
| apply | `apply` | Manual, in the protected environment `seatrials`. Runs the guard again, then `deploy/secrets.sh`, `deploy/apply.sh` and `deploy/signin-secrets.sh`. |
| apply | `apply-letsencrypt` | Manual, in the protected environment `seatrials-letsencrypt`, whose only deployer is Jody. The same apply, with the letsencrypt guard lifted. |
| apply | `signin-secrets` | Manual, environment `seatrials`. Re-installs the sign-in secrets from the variables and nothing else. |
| test | `test` | After `apply`: [`deploy/checks.sh all`](../deploy/checks.sh). Every pod Ready; the gateway serves a publicly trusted certificate for seatrials.tacplus.dev, valid for 14 more days; OIDC discovery names the host and its JWKS has keys; the sign-in smoke test; the routing check. |

Without `apply`, a pipeline is a **dry run**: tools, checks, images, generate and diff.

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
tacplus-dev/looper, where agents run. Masked variables are also *hidden*. The jobs place the file variables
under `deploy/bootstrap/` (git-ignored) with mode 600. They remove them when the job ends, and no artifact
includes them.

| Variable | Type | Scope | What |
| --- | --- | --- | --- |
| `FLEET_GITHUB_READ_TOKEN` | masked | all | A fine-grained GitHub token with read-only Contents on tacplus-dev/fleet-seatrials, tacplus-dev/operator and every service repository in `fleet.lock`. Fetches the source. |
| `GCP_WIF_PROVIDER` | plain | all | `projects/<number>/locations/global/workloadIdentityPools/gitlab-tacplus-dev/providers/gitlab-com`. |
| `FLEET_CRYPTO_YAML` | file | `seatrials*` | `deploy/bootstrap/crypto.yaml`, the fleet's CA and cluster PKI (already stored; its scope widens from `seatrials` to `seatrials*`). |
| `FLEET_CA_PEM` | file | `seatrials*` | `deploy/bootstrap/ca.pem` (already stored; scope as above). |
| `FLEET_GOOGLE_CLIENT_SECRET` | masked | `seatrials*` | Google OAuth client `seatrials-web`. |
| `FLEET_MICROSOFT_CLIENT_SECRET` | masked | `seatrials*` | The Entra client secret **value** of `seatrials-web` (`deploy/signin-secrets.sh` refuses a Secret ID). |
| `FLEET_APPLE_KEY_P8` | file | `seatrials*` | The Sign in with Apple key `AuthKey_D9JNT33239.p8`. |
| `FLEET_DEPLOY_COMMIT` | plain | optional | A full commit hash to deploy instead of main's head. |

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

1. Make the GCP side above (Jody's OK). Set `GCP_WIF_PROVIDER` in the project.
2. Register the deploy runner and turn off group runners on the project.
3. Create the protected environments: `seatrials`, deployable by Maintainers, and `seatrials-letsencrypt`,
   deployable by Jody only. Keep `main` protected.
4. Store the variables in the table above, once tacplus-dev/looper#25 is fixed. Jody pastes the sign-in
   secrets into the GitLab UI directly: not through a chat, a terminal or a file.
5. Commit `ci/gitlab-project.gitlab-ci.yml` to the project as `.gitlab-ci.yml`.
6. **Dry run:** Build → Pipelines → Run pipeline on `main`. tools, checks, images, generate and diff must be
   green; `apply` waits. Optionally add a nightly schedule: its dry run shows drift.
7. Prove the guard on the cluster (above).
8. The first real `apply` is the hub's, with Jody.

## Running it

- **Dry run or deploy:** run the pipeline on `main` (web or API). It deploys main's head, or
  `FLEET_DEPLOY_COMMIT`. Read the `diff` job's list, then start `apply`; `test` follows.
- **A change touching letsencrypt:** `diff` fails and names the objects. With Jody's OK, Jody starts
  `apply-letsencrypt`. `test` follows `apply` only, so after `apply-letsencrypt` the checks run with the next
  pipeline's `apply`.
- **A failed test:** the job names the failing check. `deploy/checks.sh <check>` runs one check alone,
  in a job with the same setup.
