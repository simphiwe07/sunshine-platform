# GitOps with Argo CD: deploy, roll back, drift

```
code change ──PR──► main ──app workflow──► image in ECR (sha + digest)
                                               │
       scripts/promote.sh <sha>  ◄─────────────┘   (writes the digest)
                 │
   deploy PR: deploy/charts/sunshine-app/values-lab.yaml ──merge──► main
                                                                     │
   Argo CD (in the cluster) polls Git every ~1 min ──sees a change───┘
        └─► helm template (chart + values-lab.yaml + Terraform's environment values)
        └─► kubectl apply ──► rolling update (readiness gates, PDB, maxUnavailable 0)
```

**Who owns what.** Terraform owns the platform and Argo CD, plus the Application with the environment settings. **Git** owns the app's version and chart. Argo CD keeps the cluster equal to Git. Nobody runs `helm upgrade` or `kubectl apply` for the app any more.

## Open Argo CD

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080 - accept the self-signed certificate; user: admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```
Or without the UI:
```bash
kubectl -n argocd get applications            # SYNC STATUS: Synced, HEALTH: Healthy
kubectl -n argocd get application sunshine-app -o jsonpath='{.status.sync.revision}{"\n"}'   # Git commit deployed
```

## Drill 1: deploy a new version

1. **Change the app.** For example, in `app/main.py` add `"greeting": "hello from v2"` to the `root()` response. PR, CI, merge.
2. **Wait for the app workflow.** It tests, scans and pushes `sunshine-app:<sha>`. Note the sha.
3. **Promote it.** Create the deploy PR:
   ```bash
   git checkout main && git pull
   scripts/promote.sh            # newest image (or: scripts/promote.sh <sha>)
   git checkout -b deploy/<short-sha> && git commit -am "deploy: sunshine-app <short-sha>"
   git push -u origin deploy/<short-sha>      # open the PR - the diff is ONE line: the digest
   ```
4. **Merge, then watch Argo CD roll it out** (no pipeline touches the cluster):
   ```bash
   kubectl -n argocd get application sunshine-app -w          # OutOfSync -> Syncing -> Synced/Healthy
   kubectl -n sunshine get pods -w                            # new pods Ready one by one, old ones terminate
   while true; do curl -s https://eks.simptechit.click/healthz; echo; sleep 2; done   # version flips, no errors
   ```

Record the time from merge to sync start (about 1 minute of polling) and from sync to all pods new.

## Drill 2: roll back

```bash
git revert <merge commit of the deploy PR>     # or: scripts/promote.sh <previous sha>
# PR -> merge -> Argo CD rolls back to the old digest
```
Rollback is the same path as a deploy: reviewed, recorded, repeatable. `git log deploy/charts/sunshine-app/values-lab.yaml` is the deployment history.

## Drill 3: drift and self-heal

```bash
kubectl -n sunshine delete service sunshine-app                        # someone deletes a resource
kubectl -n argocd get application sunshine-app -w                      # OutOfSync -> Synced within seconds
kubectl -n sunshine get svc sunshine-app                               # back

kubectl -n sunshine set image deploy/sunshine-app app=public.ecr.aws/nginx/nginx:1.29   # a hand-made "hotfix"
kubectl -n sunshine get deploy sunshine-app -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'  # back to the Git digest
```
Lesson: with self-heal, the cluster can't silently drift from Git. Hand-made fixes are reverted, so fixes must go through Git. Emergency option: pause automation on the Application (`kubectl -n argocd patch application sunshine-app --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`), fix, then commit the fix and switch it back on.

## How the switch from Terraform happened

Terraform used to install the app (`helm_release.app`). A `removed { lifecycle { destroy = false } }` block makes Terraform forget that release without uninstalling it. Argo CD's Application uses the same release name, so it renders identical objects and **adopts** them: no downtime, same ALB. The old Helm bookkeeping Secret stays behind; delete it once Argo CD shows Synced:
```bash
kubectl -n sunshine get secret -l owner=helm,name=sunshine-app
kubectl -n sunshine delete secret -l owner=helm,name=sunshine-app
```
Don't run `helm uninstall sunshine-app`: that deletes the objects Argo CD now manages.

## If something breaks

| Symptom | Look at |
|---|---|
| Application `OutOfSync` and not syncing | `kubectl -n argocd describe application sunshine-app` (conditions). Repo unreachable? Wrong path? Project not allowing the repo or namespace? |
| `Synced` but `Degraded` / `Progressing` forever | The rollout is failing: `kubectl -n sunshine get pods`, `describe pod` (image pull? readiness?). Fix it in Git, or revert the deploy PR. |
| Smoke test "live version is not <sha> after 10 min" | The deploy PR isn't merged, or the sync failed. `kubectl -n argocd get application sunshine-app` |
| lab-down hangs on the Application | Its finalizer waits for Argo CD to delete the app's objects. Check the Ingress (the ALB deletion) and the LB controller logs. |
| Change in Terraform's environment values not applied | Run lab-up (Terraform updates the Application); Argo CD then syncs it. |

## Interview notes

- **Push vs pull:** CI used to push deploys into the cluster with cluster-admin credentials. Now the cluster pulls from Git, so CI no longer needs cluster credentials, and the desired state is always visible in Git.
- **Separate code and deploy changes:** app PRs build images, and deploy PRs change one digest line. Promotion and rollback are reviewed, recorded commits.
- **Self-heal and prune** guarantee no drift and no leftovers; the trade-off is that emergency hand fixes need the pause switch.
- **The AppProject is a fence:** this app may only come from our repo, only into `sunshine`, with no cluster-scoped objects (CRDs, ClusterRoles).
- **Environment config vs version:** Terraform knows the infrastructure facts (ARNs, endpoints) and writes them into the Application. Git holds what changes per release. Precedence (`valuesObject` over `valueFiles`) is designed so Terraform never changes the version.
- **Next steps in production:** a webhook instead of polling; SSO for the UI (Cognito OIDC, Dex); CI opening the deploy PR automatically, or Argo CD Image Updater writing back to Git; an ApplicationSet for several environments; sync waves for ordered rollouts.
