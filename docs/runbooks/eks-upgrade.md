# Runbook: EKS minor-version upgrade

Upgrade **one minor version at a time** (control planes can't skip or downgrade).
Order: **pre-checks → control plane + add-ons → nodes → verify.**

## 1. Pre-checks (before the PR)

- [ ] Target version is supported by EKS and the current one isn't in extended support (6x price).
- [ ] No removed APIs in use:
      `kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis` and
      EKS console → cluster → **Upgrade insights** (all checks "Passing").
- [ ] Helm charts (LB Controller, ExternalDNS, External Secrets) support the target version - bump them first if not.
- [ ] Every Deployment can be drained: ≥ 2 replicas and a PDB that allows ≥ 1 disruption
      (`kubectl get pdb -A` → `ALLOWED DISRUPTIONS` ≥ 1). A 0 here = a stuck node rollout later.
- [ ] Start a load test against the app to measure impact (`hey`/`oha`/`curl` loop on `/`).

## 2. Control plane + add-ons (PR 1)

`platform/terraform.tfvars`:
```hcl
eks_version      = "1.37" # target
eks_node_version = "1.36" # keep nodes on the old version for now
```
Plan shows: cluster version 1.36 → 1.37 (in-place), add-on versions bumped (resolved for 1.37).
Merge → **lab-up**. Control plane ~10-20 min; workloads keep running (nodes are untouched).

Verify: `kubectl version` (server 1.37), `kubectl get pods -A` all Running,
`aws eks list-addons` / `describe-addon` all ACTIVE.

## 3. Nodes (PR 2)

Remove `eks_node_version` (nodes follow the control plane). Merge → **lab-up**.
EKS rolls the managed node group: new node up → old node cordoned → drained
(PDBs respected) → terminated, `max_unavailable = 1` at a time.

Watch: `kubectl get nodes -w` (VERSION column), `kubectl get events -A --sort-by=.lastTimestamp`,
`aws eks describe-update --name sunshine-lab --nodegroup-name sunshine-lab-spot --update-id <id>`.

## 4. Verify

- [ ] All nodes on the new version, Ready.
- [ ] Smoke test green; load test shows no (or explained) errors.
- [ ] Record: start/end times per phase, errors seen, fixes - this is the change record.

## Known failure: node rollout stuck (PodEvictionFailure)

Symptom: node group update `Failed`/slow, events show `Cannot evict pod as it would violate the pod's disruption budget`.
Cause: PDB with 0 allowed disruptions (e.g. 1 replica + `minAvailable: 1`).
Fix: scale to ≥ 2 replicas or relax the PDB (`maxUnavailable: 1`), then retry the update.
Never "fix" it by force-upgrading - that evicts without respecting availability.
