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

The cluster is created for a trial and destroyed after it; nothing here is long-lived.

## Layout

- `fleet.yaml`, `fleet.lock`, `build/proto` — the fleet: what runs, at which commits, and the merged proto tree.
- `cluster/` — create and destroy the small GKE cluster.
- `images/` — Cloud Build pipeline: `images/build.sh tacplus` (the fleet's tacplus and build images at
  `images/pins.yaml`), `images/build.sh all` (every service at its locked commit, into Artifact Registry as
  `schematic/<service>:<fleet commit>` and `:local`). Every image runs under the launcher.
- `deploy/` — `build-operator.sh` (this fleet's operator from the library against build/proto), `init.sh`
  (CA and cluster PKI, once), `secrets.sh`, `signin-secrets.sh` (the sign-in secrets, from the pipeline's
  variables), `diff.sh` (what an apply would change, by name; fails if it touches letsencrypt), `apply.sh`
  (render and apply), `checks.sh` (the post-deploy checks), `bootstrap/` (operator.yaml and services/*.yaml are
  committed; crypto.yaml, ca.pem and configs/ are not).
- `ci/` — the deploy and test pipeline, run from the GitLab project tacplus-dev/fleet-seatrials, which holds the
  secrets: [docs/deploy-pipeline.md](docs/deploy-pipeline.md). `ci/checks.sh` runs the script tests and the secrets
  scan, `ci/secrets.sh` (bash, git, jq, yq, opa, gitleaks).
- `client/` — `seatrials`, the local client: a tacplus client project generated against build/proto. It
  authenticates with a credential pair (keygen → the public half goes into the fleet config), gets a kernel
  token through the gateway, administers tenants with the root pair, and runs the two proofs (`ping`, `ask`).

## The proofs, end to end

Deploys run from the GitLab pipeline, never from a laptop (docs/deploy-pipeline.md): images, generate and
diff, then a manual apply, then the post-deploy checks. The first time, on a new cluster:

```
cluster/create.sh && deploy/init.sh && images/build.sh tacplus   # then crypto.yaml and ca.pem into the GitLab project
# the pipeline: images, generate, diff, apply, test
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
