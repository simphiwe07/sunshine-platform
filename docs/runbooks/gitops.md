# GitOps across environments: develop → dev, release → staging, main → prod

```
feature/x ──PR──► develop ──push──► deliver: build+scan+push image app-<tree>, tag <sha> ──► env/dev ──► Argo CD (non-prod) ──► sunshine-dev
                     │
                     └─ cut release/1.4 ──push──► deliver: SAME image (same app/ tree), tag <sha> ──► env/staging ──► Argo CD (non-prod) ──► sunshine-staging
                                  │
                                  └─ PR release/1.4 → main ──merge──► deliver: check main == staging, approval ──► env/prod ──► Argo CD (prod cluster) ──► sunshine-prod
```

| Environment | Branch that deploys | Cluster / account | Namespace | URL |
|---|---|---|---|---|
| dev | `develop` | non-prod cluster, this account | `sunshine-dev` | https://dev.simptechit.click |
| staging | `release/*` | non-prod cluster, this account | `sunshine-staging` | https://staging.simptechit.click |
| prod | `main` (release merged) | **prod cluster** `sunshine-prod`, same account, own VPC + database | `sunshine-prod` | https://prod.simptechit.click |

**Rules the pipeline enforces (`.github/workflows/deliver.yml`):**
- **Build once.** An image is keyed by the git tree hash of `app/` (`app-<tree>`). Any commit with the same `app/` reuses it and only gets a new tag (its commit SHA, same digest), so staging and prod run the bytes dev built and Trivy scanned.
- **Deploy = move a pointer.** `env/dev`, `env/staging` and `env/prod` are branches that only CI moves, and only **after** the commit's image exists. Argo CD follows the pointer and deploys `<repo>:<commit>`, via `imageTag = $ARGOCD_APP_REVISION`.
- **Prod only runs what staging runs.** On `main`, `app/` and the chart must have exactly the tree hashes that `env/staging` has, or the deploy fails. Then the GitHub environment `prod` waits for an approval.
- **Verified.** Each deploy waits until `<url>/healthz` reports `"revision": "<commit>"`.

Who owns what: **Terraform** owns the clusters, Argo CD, and the Applications with each environment's settings (host, certificate, sign-in, WAF, database). **Git** owns the code and chart; `env/*` records what runs where. **Argo CD** keeps every namespace equal to its pointer, with sync, self-heal and prune.

## One-time setup (stage 1: dev + staging)

1. **Bootstrap.** Let the ECR push role trust `develop` and `release/*`. Apply locally, as before:
   `cd terraform/bootstrap && terraform apply`
2. **GitHub environments** (Settings → Environments):
   - Create `dev` and `staging`, with no rules.
   - Create `prod` with **Required reviewers** (you) and **Deployment branches: `main`** only.
3. **The develop branch:**
   ```bash
   git checkout main && git pull && git checkout -b develop && git push -u origin develop
   ```
   In repo settings, protect `develop` like `main`: PRs and checks required.
4. **First deploys:** Actions → **deliver** → Run workflow:
   - From `develop`, with environment `dev`. This creates `env/dev`.
   - Then create `release/0.1` from `develop`, push it, and run the workflow on it with environment `staging`. This creates `env/staging`.

   A new branch with no file changes doesn't trigger the push event, hence the manual run the first time.
5. **lab-up.** Argo CD creates `sunshine-app-dev` and `sunshine-app-staging` and syncs them:
   ```bash
   kubectl -n argocd get applications            # both Synced / Healthy
   curl -s https://dev.simptechit.click/healthz; curl -s https://staging.simptechit.click/healthz
   ```

## The prod cluster (same account, separate cluster)

The same Terraform stacks, with `prod.tfvars` and their own state (`prod/platform.tfstate`, `prod/platform-k8s.tfstate`). Every AWS name comes from `environment`, so everything is `sunshine-prod-*`: VPC 10.30.0.0/16, database, cluster, WAF, IAM roles, Argo CD. ExternalDNS uses the cluster name as its TXT owner, so both clusters write to the one Route 53 zone without touching each other's records.

1. **A first release must exist.** Merge a release branch into `main` (or Actions → deliver → Run workflow on `main`, environment `prod`) and approve. This moves `env/prod`. With the prod cluster down, deliver notes "not up - deploys at the next cluster start", which is fine.
2. **Actions → prod-up.** It takes about 25 minutes: VPC, RDS, EKS, controllers and Argo CD, which then deploys `env/prod`. The smoke test checks https://prod.simptechit.click: reachable, sign-in enforced, WAF blocking.
3. **From now on**, merging a release into `main` deploys prod after your approval. If the cluster is up, deliver waits until prod reports the commit.
4. **Actions → prod-down** when you're done. It also runs nightly at 20:15, after lab-down.

Cost: prod doubles the hourly bill while it's up (a second EKS control plane, NAT, nodes, RDS and ALB). Bring it up only for release drills.

kubectl for prod:
```bash
aws eks update-kubeconfig --name sunshine-prod --region eu-west-1 --profile sunshine --alias sunshine-prod --user-alias sunshine-prod
kubectl --context sunshine-prod -n argocd get applications      # sunshine-app-prod
```

## Day to day

**A feature to dev:**
```bash
git checkout develop && git pull && git checkout -b feature/greeting
# edit app/main.py, e.g. "greeting": "hello" in root()
git commit -am "app: greeting" && git push -u origin feature/greeting   # PR into develop (app checks run)
```
Merging into `develop` runs **deliver → dev**: a new `app/` tree, so it builds, scans and pushes. Then `env/dev` moves, and the job waits until dev reports the commit.

**Cut a release to staging:**
```bash
git checkout develop && git pull && git checkout -b release/1.0 && git push -u origin release/1.0
# then Actions > deliver > Run workflow on release/1.0, environment staging (first push of a new branch)
```
The job summary shows "image already built - **reused**": staging runs the bytes dev ran. Fixes go onto the release branch; each push redeploys staging, and building only happens if `app/` changed.

**Release to prod:** open a PR `release/1.0 → main`, then merge. **deliver → prod** checks that main matches staging, waits for your approval, then moves `env/prod` and waits until prod reports the commit. Afterwards merge `main` back into `develop` (GitFlow).

**Roll back** any environment: Actions → **deliver** → Run workflow with the environment and the SHA to go back to. The previous SHA is in the last deploy's summary, and `git log origin/env/<name>` lists them. The image still exists (ECR keeps the newest 15), so it's tagged again, the pointer moves back, and the run waits for the result.

## Drift and self-heal

```bash
kubectl -n sunshine-dev delete service sunshine-app              # gone...
kubectl -n argocd get application sunshine-app-dev -w           # ...back within seconds
kubectl -n sunshine-dev set image deploy/sunshine-app app=public.ecr.aws/nginx/nginx:1.29   # a hand "hotfix"
kubectl -n sunshine-dev get deploy sunshine-app -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # reverted
```
Emergency: pause automation on one Application, fix, commit the fix, then switch it back on:
`kubectl -n argocd patch application sunshine-app-staging --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`

## Open Argo CD

https://argocd.simptechit.click (non-prod) and https://argocd-prod.simptechit.click (prod), behind Cognito sign-in. See [admin-uis.md](admin-uis.md) for roles and break-glass access.

## If something breaks

| Symptom | Look at |
|---|---|
| deliver: "not the image built for this app/ tree" | A commit SHA tag points at other bytes (an old pipeline pushed it). Check in ECR; don't re-tag by hand. |
| deliver prod: "differs from what staging runs" | Something reached `main` without going through a release branch. Release it properly, or roll staging forward first. |
| deliver: "did not report revision ... within 10 min" | The environment is up but didn't roll out: `kubectl -n argocd get applications`, then `describe application` (conditions), then pods in the namespace. If the cluster is down, deliver just notes it; the pointer is deployed at the next start. |
| Application `Unknown` / "unable to resolve env/staging" | The pointer branch doesn't exist yet. Run deliver once for that environment. |
| Pods `ImagePullBackOff` for `<repo>:<sha>` | Someone moved `env/*` by hand without deliver tagging the image. Run deliver for that SHA. |
| A deploy to the wrong environment | `prod` only accepts `main` (environment branch rule) and needs approval; `dev`/`staging` follow their branches. |

## Interview notes

- **Build once, promote the artifact:** the image is keyed by source content (`app/` tree hash), so promotion is a re-tag with an identical digest. Prod runs what staging tested, enforced by tree-hash comparison and not by convention.
- **Pull-based CD:** CI never gets cluster credentials. It moves a Git pointer; Argo CD in each cluster pulls. Even for prod, CI needs no access to the cluster.
- **Environment pointers vs value files:** pointers give a deployment log (`git log env/prod`), a trivial rollback, and no CI commits on protected branches. Value files per environment are the other common pattern; they fit better when environments differ in config, not just version.
- **Isolation:** dev and staging are namespaces on one non-prod cluster (cost), with RBAC, NetworkPolicy and separate hosts. Prod is its own cluster with its own VPC, database, WAF, Argo CD and upgrade cycle, so a bad non-prod change or cluster upgrade can't touch it. Developers can restart pods in dev and staging, but not in prod. **Trade-off I chose:** same AWS account (shared IAM, quotas, billing) to save setup time. The next step up is a separate prod account (Organizations + SCPs, cross-account ECR pull, delegated DNS zone), and the stacks are already parameterised for it.
- **Gates:** PR checks into `develop`/`main`, the tree-hash promotion check, and the approval for prod in a GitHub environment restricted to `main`.
