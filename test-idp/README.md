# The test IdP

A test OIDC IdP that the pipeline owns end to end, so tacplus.dev's sign-in, linking and tenant flows can be
tested with no person (#27). It is one Keycloak at **https://idp.test.tacplus.dev**, whose realms emulate the
claim shapes of Google, Microsoft and Apple, with test users across a few test domains. tacplus.dev is not an
IdP. It connects to this one like any other external provider: oauth's `Test Google`, `Test Microsoft` and
`Test Apple` ([`deploy/bootstrap/services/oauth.yaml`](../deploy/bootstrap/services/oauth.yaml)).

Nothing here reuses a real password or a real provider account. Every password and client secret is a test
value, derived from the pipeline's seeds and never printed.

## Where it runs

- **Cluster:** the `tacplus` GKE cluster (jody1-328023, us-central1-a), namespace `test-idp`. Nothing is shared
  with the fleet's namespaces.
- **Keycloak:** a single-replica StatefulSet, pinned by digest, with its file-backed database on a 1 GiB PVC
  ([`keycloak.yaml`](keycloak.yaml)).
- **Exposure:** a GKE Ingress with its own load balancer, on the reserved global address `test-idp`. TLS is a
  Google-managed certificate for `idp.test.tacplus.dev` only, so the fleet's letsencrypt and its order budget are
  never touched.
- **What the internet reaches:** the Ingress forwards only `/realms/google`, `/realms/microsoft`,
  `/realms/apple` and `/resources`. The master realm and the admin console and API are reached through a
  port-forward, by the pipeline only.
- **DNS:** the A record goes in the Cloud DNS zone `tacplus-dev`.
- **Applied only from GitLab:** the deploy pipeline's `test-idp` job ([`apply.sh`](apply.sh)) runs as
  `test-idp-deploy`, which can reach only this namespace and that record ([`rbac.yaml`](rbac.yaml),
  [docs/deploy-pipeline.md](../docs/deploy-pipeline.md#the-test-idp)).

## Realms and claim shapes

Each realm's issuer is Keycloak's own, `https://idp.test.tacplus.dev/realms/<realm>`, and each has two clients:

- `tacplus-dev`: tacplus.dev's confidential client, with a redirect under `https://seatrials.tacplus.dev/`.
- `claims-check`: a public client with PKCE (S256). The sign-in checks use it to read the ID token the realm
  issues.

Emulation covers the claims and the authorization-code flow, not the real issuers' URLs.

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
| google | `gone@personal.test` | The user **removed at the IdP**: `signin.sh` signs in as gone, removes the user and checks the next sign-in is refused. The next apply puts the user back. |
| microsoft | `ada@alpha.test` | alpha.test's directory, a verified domain (`xms_edov: true`). The same person as `ada@alpha.test` at google. |
| microsoft | `bo@beta.test` | beta.test's directory. **The domain a tenant claims:** `/tenants/beta` claims `email_domain` beta.test from this realm ([`tenants/beta/oauth.yaml`](../deploy/bootstrap/tenants/beta/oauth.yaml)). |
| microsoft | `nomail@beta.test` | An account with **no email**: the token has no `email`. |
| microsoft | `max@personal.test` | A **personal** Microsoft account: the consumers `tid`, no `xms_edov`. |
| apple | `cy@personal.test` | Shares their real address (`is_private_email: false`, `real_user_status: 2`). |
| apple | `rae@personal.test` | A **relay email**: `k7q2xw9mzp@privaterelay.appleid.test`, `is_private_email: true`. |

The domains are `alpha.test`, `beta.test` and `personal.test`, plus `privaterelay.appleid.test` for relay
addresses. `.test` is reserved, so none of them reaches anyone real.

## Secrets

Two seeds are protected, masked and hidden variables of the GitLab project tacplus-dev/fleet-seatrials:

| Variable | Scope | Derives |
| --- | --- | --- |
| `TEST_IDP_SEED` | `test-idp` and `seatrials*` | every user's password (`user/<realm>/<username>`), the Keycloak admin's (`admin`) |
| `TEST_IDP_CLIENT_SEED` | `test-idp` and `seatrials*` | the `tacplus-dev` clients' secrets (`client/<realm>/tacplus-dev`), the pairwise salt (`pairwise-salt/<realm>`) |

A secret is base64url(HMAC-SHA256(seed, `fleet-seatrials/test-idp/<purpose>`)), with no padding.

- **Where they come from:** the `test-idp` job generates each seed the first time and stores it in the project
  itself (`TEST_IDP_GITLAB_TOKEN`, docs/deploy-pipeline.md). No person ever sees it.
- **Who uses them:** the functional suite's sign-in items (`deploy/e2e.yaml`, the `test` job) and
  `deploy/signin-secrets.sh`, in the `seatrials` environment, derive what they need. That environment's jobs
  can therefore derive the Keycloak admin's password too; they run for Maintainers only. A seed stored before
  this needs its `seatrials*` copy added once, by the hub.
- **The hub's manual checks:** the hub, a Maintainer, reads `TEST_IDP_SEED` from the project's settings into its
  environment. Then `test-idp/testidp.py secret user/<realm>/<username>` prints that user's password. This is
  never done in a job, whose log would keep it.
- **Rotating:** delete a seed's variables and run `test-idp`, which generates a new one. Then run
  `signin-secrets`. A new admin password takes effect only with a new PVC: Keycloak reads it on its first start.

## Checks

| What | Where | Checks |
| --- | --- | --- |
| [`testidp_test.sh`](testidp_test.sh) | `ci/checks.sh` (every pipeline) | Secret derivation, the render (secrets in, none in the files), the claim shapes, the login form, RS256, and that this README lists every user. |
| [`local.sh`](local.sh) | by hand, before landing a realm change (needs docker) | Starts the pinned Keycloak locally and runs `signin.sh`'s IdP checks. A second sync must change nothing, and a recreated realm must keep every `sub`. |
| [`signin.sh`](signin.sh) | the `test-idp-signin` job | Every realm's discovery answers. Every user signs in (code + PKCE) with its shape. `ada@alpha.test` (google), `bo@beta.test` (microsoft) and `cy@personal.test` (apple) sign in at tacplus.dev, get a kernel session, and the session names the realm and the user's `sub`. `gone@personal.test` is refused once removed. Before the first `test-idp` apply (no `TEST_IDP_SEED`), the job skips: the test IdP is not set up yet. |

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
4. Run `test-idp/local.sh`, land, then run the pipeline's `test-idp` job; `test-idp-signin` follows in the
   next pipeline.

A change to a realm's settings, clients or mappers recreates that realm on the next apply. Each `sub` stays the
same; the realm's signing keys and sessions are new. A change to users alone keeps the realm. A user removed
from a file is removed at the IdP.
