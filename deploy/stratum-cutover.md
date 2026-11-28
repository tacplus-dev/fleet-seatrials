# The cut-over to per-tenant Stratum and the /system redo (#3)

The deploy plan for #3, for the hub, which deploys (looper does not). The render it applies is the one #3 committed:

- tacplus v2.6.16, kernel 0.2, stratum 0.2.5 and redo 0.2.0, and the operator at 5e8e316 (`images/pins.yaml`).
- Each tenant's Stratum is in memory, `stratum-<tenant>`, in `tac-seatrials-<tid>`, with
  `topology.stratum_members: 1`. That covers alpha `741kqltx`, beta `ewqybj38` and the reserved people tenant
  `00000001`.
- redo, the durability of every tenant's Stratum, is one `/system` instance in `tac-seatrials`. Its volume is
  `data-redo-0`.
- Nothing runs in the restore tenant's namespace `tac-seatrials-00000002`, and there is no platform Stratum.

`deploy/stratum-redo_test.sh` checks this shape on the render.

Stratum 0.2.5 reaches only a `/system` redo, and stratum 0.2.4 reaches only a restore-tenant redo
(tacplus-dev/stratum#54). So redo and stratum move together, in the same render, both forward and back.

## What there is to carry over: nothing

The new Stratum starts empty and fills only from redo. Nothing in an earlier store carries over by itself. Here is
every record type the fleet's contracts store (`(spec.record)` in `build/proto`), with where each is today and how
it gets into the new Stratum:

| Record | Where it is today | How it gets into the new Stratum |
| --- | --- | --- |
| The gateway's certificate | Not a Stratum record since #35. It is the Secret Manager secret `tls-seatrials` in `tacplus-dev`. The `cert` job installs it as `crypto.yaml`'s `pki.edge_tls[0]`, and the gateway serves it in `CERT_CHAIN` mode. The render has no letsencrypt workload and no `LetsEncryptCert` row. | It doesn't need to go in. Keep the secret as it is (next section). |
| `coop.PigeonRun` (each tenant's) | Nowhere. Until #83 the coop ran in `MODE_MOCK`, and since then no Stratum has run on `dev` (`stratum_nodes: 0`; on 2026-11-27 the platform stratum crash-looped on its identity check). The SeaBeam clusters' Stratum (`schematic/stratum:local`) went with those clusters (`seatrials` 2026-10-29, `tacplus` 2026-11-05). | Nothing to carry. The coop writes new runs into its tenant's Stratum, and redo keeps them. |
| `doppelganger.ContextDocument`, `Session`, `PanelRun` (each tenant's) | Nowhere, for the same reasons: no Stratum on `dev`, and the old clusters are deleted. | Nothing to carry. Users push their context again (`context push`). Sessions and panel runs start fresh. |
| `kernel.TenantRegistryEntry` | Not used. `tenant_registry_tid` is unset, so kernel serves the tenants of its disk snapshot and `Config.tenants` (operator.yaml's), and follows no registry. | Nothing to carry. |

Kernel's own state (tenants, identities, keys, `TenantConfig`, and the Stratum seeds kernel writes at every boot)
is on kernel's disk, not in Stratum. The cut-over doesn't touch it.

Before the apply, the hub confirms that nothing has been written since this was checked (2026-11-28):

- `kubectl get statefulset,pvc -n tac-seatrials` shows no Stratum that ever became Ready.
- The restore tenant's `data-redo-restore-0`, if it exists, was never appended to: no Stratum could reach that
  redo.

If either shows data, stop and raise it on #3 before the apply.

## No new certificate order

Don't order a certificate for this cut-over. The duplicate-certificate budget is nearly spent.

- The current certificate and key stay the current version of `tls-seatrials`. The pipeline's `cert` job checks that
  version first (`ci/cert-check.sh`). It orders from Let's Encrypt only when the version is missing, expired,
  for the wrong names or invalid, and renews only by ARI or in the last third of its lifetime.
- Before the apply, check that the `cert` job of the pipeline that applies says `valid` and obtained nothing.
- Don't disable or destroy a version of `tls-seatrials` or of `acme-account-seatrials`.
- Don't set `CERT_SUPPLIED_SECRET` to another secret.
- There is no letsencrypt workload to restart: it left the fleet with #35/#1, and this render adds none.
- The certificate never goes into Stratum. If it ever has to come from somewhere other than the secret, it comes
  from the existing secret's version, never from a re-order.

## The order of the cut-over

The pipeline applies the whole render at once, as one operator release (`deploy/apply.sh`). The order below is the
order in which each part must be Ready, checked step by step. A part that started before the one it depends on is
restarted once that one is Ready. `checks.sh pods` reads only `tac-seatrials`, so the hub checks the tenant
namespaces with its own access (`seatrials-deploy` can't read them: #75).

1. **redo.** `redo-0` is Ready in `tac-seatrials` and its log shows it serving. Its volume `data-redo-0` is bound.
2. **Each tenant's Stratum.** In each of `tac-seatrials-741kqltx`, `tac-seatrials-ewqybj38` and
   `tac-seatrials-00000001`, `stratum-<tenant>-0` is Ready.
   - Its log shows its replay from redo finished. It's empty the first time.
   - It reads its seeds from kernel, so kernel must be Ready too (in `tac-seatrials`, which `checks.sh pods` reads).
   - The log must not show `not a tenant's Stratum identity`, and must show no refused call to redo.
   - A Stratum that came up before redo was Ready and is not Ready: delete its pod. It is in memory and replays
     from redo when it starts.
3. **The services that write records.** The coop, doppelganger-alpha and doppelganger-beta: any that started before
   their tenant's Stratum was Ready are restarted. Kernel needs no restart: it writes each tenant's seed members
   into its own state at every boot (kernel#34), and each Stratum reads them from kernel.
4. **The checks.**
   - The pipeline's `test` stage passes, and the gateway serves the same certificate serial as before the apply.
   - Then one write and read back per tenant: `context push` and `context list` as a person of that tenant, or a
     coop pigeon run.
   - Then delete that tenant's `stratum-<tenant>-0` and check that the row reads back after the replay. This is
     the proof that redo is the durability.
5. **The cleanup**, only once step 4 passes:
   - The upgraded release removes the old `redo-restore` StatefulSet and Service. Their volume stays: delete
     `data-redo-restore-0` in `tac-seatrials-00000002`.
   - Delete any `data-stratum-*` claim left in `tac-seatrials` from the platform Stratum. It never ran past its
     identity check, so it held nothing (tacplus-dev/operator#54).
   - Kernel's stale delegates (`redo` in `/tenants/restore`, the platform `stratum`) are already gone from
     `services/kernel.yaml` in this commit.

## Rollback

Revert #3's commits on main. The next pipeline applies the previous render: operator v0.2.1, kernel 0.1,
`stratum_nodes: 0` (no Stratum) and redo 0.1 as `redo-restore` in `tac-seatrials-00000002`. The revert moves redo
and stratum back together.

- **Keep `data-redo-0`.** What the new Stratum wrote during the new shape is in redo's log on that claim, which a
  StatefulSet keeps by default. The previous render can't read it: it runs no Stratum. A roll-forward replays it.
  Deleting the claim loses those records.
- If the cleanup (step 5) has not run yet, the old `data-redo-restore-0` is still there for the previous render.
  If it has, the previous redo starts on a new, empty claim, which is what it held anyway.
- The certificate doesn't change either way. The rollback must not order one either.
- Rolling forward again is the same order, from step 1.
