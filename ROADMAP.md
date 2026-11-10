# Roadmap: fleet-seatrials

Owned by Jody; changed only by an agent at Jody's request. Loopers propose in PROPOSALS.md.

## Now
The deployment of the `seatrials` GKE cluster, live at https://seatrials.tacplus.dev: the proof fleet for tacplus-dev (tacplus-dev/roadmap:decisions/tacplus-dev-stable-gate-2026-10-25.md).
tacplus floor 2.2, services pinned by commit in `fleet.lock`, images built per fleet on Cloud Build; no releases or tags.
Google, Microsoft and Apple sign-in; Google (thescottsweb.com) routes to alpha, Microsoft (jodyseabeam) to beta (#2).

## Next
- Assemble and apply the uni-config in memory; validate it in diff; checks.sh fails on confi (#28) (Jody, 2026-11-01)
- Test IdP: a tiny Keycloak, a pod in its own namespace on cluster `dev` (never a VM; Jody, 2026-11-06), at idp.test.tacplus.dev emulating Google, Microsoft and Apple claim shapes, with test users and domains, managed from GitLab (#27) (Jody, 2026-11-01)
- Chaos monkey: scheduled failure injection against the live fleet from GitLab, self-checking, letsencrypt excluded (#26, after #4) (Jody, 2026-10-31)
- Move tacplus.dev onto the single arm64 cluster `tacplus` (seatrials and cavalier deleted 2026-10-29): arm64 service images (#23), the Let's Encrypt state seeded from the snapshots with no new order (#24), then the move (#4)
- Deploy and test from GitLab: the pipeline in gitlab.com/tacplus-dev/fleet-seatrials, secrets in GitLab, nothing on a laptop (#17)
- Nothing unblocked: every approved issue is blocked (see Later).
- Apply automatically on main after a successful diff; outside production nothing waits for a person (#34). Agent, at Jody's request, 2026-11-02 (`tacplus-dev/roadmap:decisions/deterministic-deployments-2026-11-02.md`).
- The pipeline owns the certificate: check, obtain once by DNS-01 when due, reference the secret version in the uni-config; retire the in-cluster letsencrypt (#35). Agent, at Jody's request, 2026-11-03 (`tacplus-dev/roadmap:decisions/certificates-by-pipeline-2026-11-03.md`).
- Security job in the pipeline: OSV-Scanner, govulncheck on pinned binaries, gitleaks, Trivy on the CI image, an enforced security-exceptions.yaml (#36). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:suggestions/2026-11-04-the-deterministic-security-checks-in-the-pipelines-that-apply-infrastructure.md`).
- Retarget to the new cluster in seabeam.net: project tacplus-dev, cluster dev, deploy accounts, WIF provider, image registry, the gateway's reserved address (#39). Agent, at Jody's request, 2026-11-05 (`tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md`).
- init-secrets writes the fleet CA and crypto file to Secret Manager through WIF; deploy reads them there (#44). Agent, at Jody's request, 2026-11-08 (tacplus-dev/cloud#28, option D).
- Google sign-in client out of jody1 into seabeam.net, created and maintained by the pipeline, its secret in Secret Manager; design first (#46). Agent, at Jody's request, 2026-11-09.
- Drop kmaker from the fleet: retired, the operator no longer renders it (#47). Agent, at Jody's request, 2026-11-10.

## Later
- Move the fleet to tacplus 2.4 (#1): blocked on the 2.4 floor in blobstore#1, coop#1, doppelganger#1, kmaker#1, letsencrypt#1, opa#1, operator#1, pigeon#1, tenantecho#1.
- Adopt per-tenant Stratum, redo and people (#3): blocked on #1, operator#2, people#1, redo#1, kernel#2, letsencrypt#2.
- Move to `tac-seatrials` namespaces, config and migration runbook (#4): blocked on operator#3.
- Pin services by release line, deploy release images (#8): blocked on tacplus#180.
- Operator pin carries 31 reachable vulnerabilities (#11): blocked on #1 and operator#1.
- `dependencies.yaml`: 13 vulnerable exact pins (#13): blocked on #1.
- Microsoft client secret expires ~2027-04-27; the pipeline must rotate it (#6): not approved, belongs to the deployment pipeline; until then rotate by hand before 2027-04-27.
- Deployment moves to a per-deployment pipeline, with Jody's sign-off; the top pipeline is still open (tacplus-dev/roadmap:decisions/deployments-per-cluster-2026-10-26.md).
- Prove the open items of the stable gate on this fleet (tacplus-dev/roadmap:decisions/tacplus-dev-stable-gate-2026-10-25.md).

## Not doing
- Nothing recorded yet.
