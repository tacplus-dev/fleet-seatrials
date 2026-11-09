# The test IdP

A test OIDC IdP that the pipeline owns end to end, so tacplus.dev's sign-in, linking and tenant flows can be
tested with no person (#27). It is one Keycloak at **https://idp.test.tacplus.dev:8443**, whose realms emulate the
claim shapes of Google, Microsoft and Apple, with test users across a few test domains. tacplus.dev is not an
IdP. It connects to this one like any other external provider: oauth's `Test Google`, `Test Microsoft` and
`Test Apple` ([`deploy/bootstrap/services/oauth.yaml`](../deploy/bootstrap/services/oauth.yaml)).

Nothing here reuses a real password or a real provider account. Every password and client secret is a test
value, derived from the pipeline's seeds and never printed.

## Where it runs

- **Cluster:** the `dev` GKE cluster (tacplus-dev/cloud's dev stack: project tacplus-dev, us-central1-a),
  namespace `tac-test-idp`, which tacplus-dev/cluster gives the deployment `test-idp` (its `deployments.yaml`).
  Nothing is shared with the fleet's namespaces. No VM: the only VMs are Kubernetes nodes (Jody, 2026-11-06).
- **Keycloak:** a single-replica Deployment, pinned by digest ([`keycloak.yaml`](keycloak.yaml)). Its file
  database is in the pod. On every start it imports the realms from the Secret `keycloak-realms`, with each
  user's fixed id, so every `sub` stays the same across restarts and applies. The realms' signing keys and
  sessions are new with each pod.
- **Exposure:** port 8443 of the address `gateway`, the platform's one public IP. tacplus-dev/cloud's TCP proxy
  load balancer passes it, TLS unopened, to the NEG `seatrials-test-idp`, which the Service `keycloak` names
  (tacplus-dev/cloud#21, its README, The public entry). The test IdP has a port of its own because a TCP proxy does
  not route by SNI, and 443 is the gateway's.
- **TLS:** ends in the pod, at an haproxy container (3.2 LTS, by digest), with the test IdP's own Let's Encrypt
  certificate for `idp.test.tacplus.dev` only, never the fleet's. The pipeline obtains and renews it with
  [`ci/cert.sh`](../ci/cert.sh), as it does the fleet's, as versions of the secret `tls-test-idp`, with DNS-01 in
  its own challenge zone `_acme-challenge.idp.test.tacplus.dev`.
- **What the internet reaches:** haproxy forwards only `/realms/google`, `/realms/microsoft`, `/realms/apple`
  and `/resources`, and refuses any path with dot segments, empty segments, percent-encoding or `;`. The master
  realm and the admin console and API are not on the internet. In the cluster, the admin Job
  ([`admin-job.yaml`](admin-job.yaml)) reaches them through the Service `keycloak-admin`, with the admin's
  credential. There is no NetworkPolicy: bearer tokens isolate, not reachability (Jody, 2026-11-07).
- **DNS:** `idp.test.tacplus.dev` is an A record to `gateway` in the zone `tacplus-dev`, written by
  tacplus-dev/cloud's pipeline, its only writer.
- **Applied only from GitLab:** the deploy pipeline's `test-idp` job and the start of `test-idp-signin`
  ([`apply.sh`](apply.sh)) run as `test-idp-deploy`, which can reach only this namespace, the test IdP's
  certificate secrets and its challenge zone ([docs/deploy-pipeline.md](../docs/deploy-pipeline.md#the-test-idp)).

## Realms and claim shapes

Each realm's issuer is Keycloak's own, `https://idp.test.tacplus.dev:8443/realms/<realm>`, and each has two clients:

- `tacplus-dev`: tacplus.dev's confidential client, with a redirect under `https://seatrials.tacplus.dev/`.
- `claims-check`: a public client with PKCE (S256). The sign-in checks use it to read the ID token the realm
  issues.

Emulation covers the claims and the authorization-code flow, not the real issuers' URLs (nor their port: the
real ones are on 443).

| Realm | Issuer | ID token claims | Unlike the real one |
| --- | --- | --- | --- |
| Google-like | `/realms/google` | `sub` (the account's decimal id), `email`, `email_verified` (a boolean), `hd` (Workspace accounts only), `name`, `given_name`, `family_name`, `picture` | Keycloak adds `typ`, `azp`, `sid`. |
| Microsoft-like | `/realms/microsoft` | `ver` `"2.0"`, `tid` (the directory's GUID; `9188040d-6c67-4c5b-b112-36a304b66dad` for a personal account), `oid`, `sub` (pairwise: per redirect host, neither `oid` nor the id), `preferred_username` (the UPN), `name`, `email` (absent when the account has none), `xms_edov` (a boolean); no `email_verified` | One issuer for every directory, so no `{tid}` in it. |
| Apple-like | `/realms/apple` | `sub` (`000000.<32 hex>.0000`), `email` (the account's or a relay address), `email_verified` `true`, `is_private_email` (a boolean, true for a relay address), `real_user_status` (an integer: 0, 1, 2); no name | A client secret, not an ES256 JWT from a .p8 key. The response comes back in the query, not as a form post. There is no `user` form field, so no name on the first sign-in either. |

The realm files are [`realms/`](realms/): Keycloak's realm representation, in YAML. Each file's header
describes its shape. [`testidp.py`](testidp.py)'s `check_shape` is the shape each sign-in check holds the realm to.

## Users and domains

Usernames sign in on the realm's login page. Passwords are derived (below), and none is written anywhere.

| Realm | Username | Case |
| --- | --- | --- |
| google | `ada@alpha.test` | A Workspace account of alpha.test (`hd`). The same person is `ada@alpha.test` at microsoft too: **linking**. |
| google | `una@personal.test` | A consumer account whose email is **not verified** (`email_verified: false`). |
| google | `gone@personal.test` | The user **removed at the IdP**: `signin.sh` signs in as gone, removes the user and checks the next sign-in is refused. Then it puts the user back, with the same id. |
| microsoft | `ada@alpha.test` | alpha.test's directory, a verified domain (`xms_edov: true`). The same person as `ada@alpha.test` at google. |
| microsoft | `bo@beta.test` | beta.test's directory. **The domain a tenant claims:** `/tenants/beta` claims `email_domain` beta.test from this realm ([`tenants/beta/oauth.yaml`](../deploy/bootstrap/tenants/beta/oauth.yaml)). |
| microsoft | `nomail@beta.test` | An account with **no email**: the token has no `email`. |
| microsoft | `max@personal.test` | A **personal** Microsoft account: the consumers `tid`, no `xms_edov`. |
| apple | `cy@personal.test` | Shares their real address (`is_private_email: false`, `real_user_status: 2`). |
| apple | `rae@personal.test` | A **relay email**: `k7q2xw9mzp@privaterelay.appleid.test`, `is_private_email: true`. |

The domains are `alpha.test`, `beta.test` and `personal.test`, plus `privaterelay.appleid.test` for relay
addresses. `.test` is reserved, so none of them reaches anyone real.

## Secrets

Two seeds are kept together as the Secret Manager secret `test-idp-seeds` in `tacplus-dev` (tacplus-dev/cloud#32),
each version two lines `NAME=value`:

| Seed | Derives |
| --- | --- |
| `TEST_IDP_SEED` | every user's password (`user/<realm>/<username>`), the Keycloak admin's (`admin`) |
| `TEST_IDP_CLIENT_SEED` | the `tacplus-dev` clients' secrets (`client/<realm>/tacplus-dev`), the pairwise salt (`pairwise-salt/<realm>`) |

A secret is base64url(HMAC-SHA256(seed, `fleet-seatrials/test-idp/<purpose>`)), with no padding.

- **Where they come from:** the `test-idp` job's first run generates both and adds them as the secret's first
  version, as `test-idp-deploy` through WIF. No GitLab token writes them, and no person ever sees them.
- **Who reads them:** every job reads the latest version into its environment (`ci_test_idp_seeds`,
  [`ci/lib.sh`](../ci/lib.sh)): the test IdP's jobs, and, in the `seatrials` environment, the functional suite's
  sign-in items (`deploy/e2e.yaml`, the `test` job) and `deploy/signin-secrets.sh` (the `apply` and
  `signin-secrets` jobs), which derive what they need. seatrials' jobs read it as `seatrials-deploy`, which needs
  `secretAccessor` on the secret (docs/deploy-pipeline.md, the test IdP); without it they go on without the
  seeds, saying so. Those jobs can derive the Keycloak admin's password too; they run for Maintainers only.
- **The hub's manual checks:** the hub reads the secret's latest version into its environment, as an account
  that may read it. Then `test-idp/testidp.py secret user/<realm>/<username>` prints that user's password. This
  is never done in a job, whose log would keep it.
- **Rotating:** not automated yet: the `test-idp` job generates seeds only while the secret has no version
  (PROPOSALS.md, the test IdP's follow-ups). A new version, then `test-idp` and `signin-secrets`, rotates every
  password and client secret; the realms, and the admin's password, change with the pod `test-idp` rolls out.

## Checks

| What | Where | Checks |
| --- | --- | --- |
| [`testidp_test.sh`](testidp_test.sh) | `ci/checks.sh` (every pipeline) | Secret derivation, the render (secrets in, none in the files), the claim shapes, the login form, RS256, and that this README lists every user. |
| [`apply_test.sh`](apply_test.sh) | `ci/checks.sh` (every pipeline) | `apply.sh`'s seeds, with stubs: generated and stored as one version of `test-idp-seeds` the first time, the Secrets derived from them, nothing stored when the job read them, one seed or a refused store failing before anything is written, no seed printed. |
| [`local.sh`](local.sh) | by hand, before landing a realm change (needs docker) | Starts the pinned Keycloak locally, the realms imported as in the cluster, and runs `signin.sh`'s IdP checks. A second Keycloak, as a new pod would be, imports them again: every `sub` must be the same, and the removed user back. haproxy is not part of it. |
| [`signin.sh`](signin.sh) | the `test-idp-signin` job, after `apply.sh` | Every realm's discovery answers, on the public port. Every user signs in (code + PKCE) with its shape. `ada@alpha.test` (google), `bo@beta.test` (microsoft) and `cy@personal.test` (apple) sign in at tacplus.dev, get a kernel session, and the session names the realm and the user's `sub`. `gone@personal.test` is refused once removed (the admin Job removes it, in the cluster), then put back. Before the first `test-idp` apply (no `TEST_IDP_SEED`), the job skips: the test IdP is not set up yet. |

The sign-in is a headless browser in Python's standard library. It follows tacplus.dev's `Authorize` to the
realm, posts the login form, captures the redirect back without loading it, and completes with
`MintCallbackTokens`, as tacplus.dev's web app does. The realms' login pages need no JavaScript.

## Adding a case

1. Add the user to the realm's file in [`realms/`](realms/), with a fixed `id` (its `sub` stays the same
   across applies) and the attributes its shape needs (`hd`, `tid`/`oid`/`upn`/`xms_edov`,
   `apple_sub`/`is_private_email`/`real_user_status`). For a new claim, add a protocol mapper and extend
   `check_shape`. Never add a password: it is derived.
2. Add the user to the table above. `testidp_test.sh` fails until you do.
3. If tacplus.dev should treat the case specially (a tenant claiming its domain, say), change
   `deploy/bootstrap/` too. Add a sign-in at tacplus.dev to `signin.sh`'s `signin_users` if the case is about
   tacplus.dev's handling.
4. Run `test-idp/local.sh`, then land: the next pipeline's `test-idp-signin` applies it and checks it.

Any change to the realms rolls out a new pod, which imports them: each `sub` stays the same, and the realms'
signing keys and sessions are new. A user removed from a file is gone from the IdP with it.
