# History: fleet-seatrials

Append-only: add entries at the end, never edit or remove one (CI enforces it). One line each:
`- <YYYY-MM-DD> <who: looper|agent|jody> <kind: issue|decision|release|deploy> <one line> (<links>)`

- 2026-10-29 looper issue ci/tools.sh: pipeline yq v4.47.1 carries GO-2026-5970 (x/text); v4.54.1 is clean (#19, 8832a13)
- 2026-10-29 looper issue ci/tools.sh: pipeline opa v1.13.1 has 26 reachable vulnerabilities; v1.21.4 is clean (#20, 48e1b53)
- 2026-10-29 looper issue A real TLS private key is committed in deploy/bootstrap/services/kernel.yaml: move it to deploy secrets and rotate (#22, 7da2555)
- 2026-11-02 looper issue fleet-plan reads the private fleet-seatrials repo through the keyless tacplus-reader GitHub App, not a stored FLEET_GITHUB_READ_TOKEN (#29, c2ccdc9)
- 2026-11-02 looper issue First dry run: Cloud KMS refused to sign with tacplus-reader; the job hides the error. Surface it, and fall back to SA impersonation if direct federation isn't accepted (#30, ab67a8c)
- 2026-11-02 looper issue test-idp-signin runs (and fails the dry run) before the test IdP exists: skip it when the test-idp environment isn't set up (#31, 9489656)
- 2026-11-02 looper issue images: gcloud builds submit fails the default-bucket ownership check; stage in a dedicated bucket (#32, 3537124)
- 2026-11-02 looper issue images: the build image is keyed by tacplus commit only, so a stale 10-26 image without the launcher is reused; every service build fails (#33, 2f1d309)
