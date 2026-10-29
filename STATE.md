# State: fleet-seatrials

Overwritten to stay current (loopers and agents). Last updated: 2026-10-29 by the looper (#22).

- **Version / line:** no releases or tags; services pinned by commit in `fleet.lock`; tacplus floor 2.2
- **Works:** seatrials is live at https://seatrials.tacplus.dev. Google, Microsoft and Apple sign-in work (Google routes to alpha, Microsoft to beta). The deploy and test pipeline is defined here (`ci/`, docs/deploy-pipeline.md): tools, checks, images, generate, diff (with the letsencrypt guard), manual apply, post-deploy checks. Its script tests and the secrets scan pass (`ci/checks.sh`; `ci/secrets.sh`, gitleaks over the history and the tree at HEAD, also on every push to GitHub). No key material is in the tree. The post-deploy checks that need no cluster access (cert, JWKS, sign-in) pass against the live fleet.
- **Released / deployed:** the GKE cluster `seatrials` (jody1-328023, us-central1-a), namespace `schematic`; deployed by the hub. Nothing deploys from a laptop.
- **Known gaps:** the pipeline has not run on GitLab yet: it needs the hub's setup (#18). The client does not generate on main (#14). Trust domain `local.dev` (#16). Vulnerable pins (#11, #13). The Microsoft client secret expires around 2027-04-27 (#6): rotate it through the pipeline's `signin-secrets` job.
- **Blocked on:** #18 (pipeline setup: WIF, deploy runner, environments, variables), tacplus-dev/looper#25 (the agents' GitLab token reaches this project's secrets), #1 (tacplus 2.4).
