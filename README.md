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
