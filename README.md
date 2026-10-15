# Sunshine Platform

A personal AWS lab that builds a production-style platform end to end: networking, DNS, containers (ECS + EKS), data, identity and CI/CD — all Terraform, all shipped by GitHub Actions, designed to run on a $100 free-plan account by **spinning up per session and tearing down nightly**.

## Layout

```
terraform/
  bootstrap/            one-time, run locally with admin creds
                        state bucket, GitHub OIDC roles, budgets, CloudTrail, account guardrails
  modules/
    network/            3-tier VPC, single NAT, S3 endpoint, EKS subnet tags, optional flow logs
    dns/                Route 53 zone, CAA, wildcard ACM cert (DNS-validated)
  envs/lab/
    foundation/         persistent, ~$0.50/month   -> applied on merge to main
    platform/           ephemeral, billed hourly    -> lab-up / lab-down workflows
.github/workflows/
  _terraform.yml        reusable plan / apply / destroy
  ci.yml                PR: fmt, tflint, checkov, plan both stacks
  foundation-apply.yml  push to main (dns changes)
  lab-up.yml            manual: create platform
  lab-down.yml          manual + nightly 20:00 SAST: destroy platform
```

## How access works

| Who | How | Can do |
|---|---|---|
| You (console/CLI) | IAM Identity Center / SSO, MFA | Everything, incl. bootstrap |
| CI plan (PRs, main) | OIDC → `sunshine-gha-plan` | Read-only + state lock files |
| CI apply (env `lab`) | OIDC → `sunshine-gha-apply` | Admin, **minus** explicit denies: can't touch state/trail buckets, CloudTrail, its own roles, the OIDC provider, budgets, or create IAM users/access keys |

No long-lived AWS keys exist anywhere, including GitHub secrets.

## One-time setup

**1. Secure the account (console)**
- MFA on the root user; don't use root again.
- Enable IAM Identity Center, create your user, assign `AdministratorAccess`. If the free plan blocks it, use an IAM admin user with MFA instead.
- `aws configure sso --profile sunshine` then `aws sso login --profile sunshine`.

**2. Create the GitHub repo** `simphiwe07/sunshine-platform` (empty, no README) and push this code.

**3. Bootstrap**
```bash
export AWS_PROFILE=sunshine
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # set github_repository + alert_email
terraform init && terraform apply
terraform output github_variables
```
Confirm the AWS Budgets subscription emails. Then move bootstrap state into S3: uncomment the `backend "s3"` block in `versions.tf` and run
```bash
terraform init -migrate-state -backend-config="bucket=$(terraform output -raw state_bucket)"
```

**4. Configure GitHub** (repo → Settings)
- *Secrets and variables → Actions → Variables*: add the four values from `github_variables` (`AWS_REGION`, `TF_STATE_BUCKET`, `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`).
- *Environments*: create `lab`, restrict deployment branches to `main`.
- *Branches*: protect `main`, require the `ci` checks.

**5. Domain**
Pick one:
- Register a cheap domain in Route 53 (it auto-creates the zone) → set `create_zone = false`.
- Use a domain you own elsewhere → keep `create_zone = true`, delegate a subdomain like `lab.yourdomain.com` with NS records at your registrar.

Set `domain_name` in `terraform/envs/lab/foundation/terraform.tfvars`, open a PR, merge. Get the name servers from the `foundation-apply` run summary, delegate, wait for `dig NS lab.yourdomain.com` to show them, then set `validate_certificate = true` and merge again.

## Daily loop

1. **Actions → lab-up → Run** (≈15 min with RDS + ECS; set `enable_database`/`enable_app = false` in `platform/terraform.tfvars` to skip them).
2. Work. Changes go through PRs; `ci` plans them.
3. **Actions → lab-down → Run** when done. It also runs every night at 20:00 SAST.

Local runs (same backend):
```bash
cd terraform/envs/lab/platform
terraform init -backend-config="bucket=<TF_STATE_BUCKET>"
terraform plan
```

Commit `.terraform.lock.hcl` after your first local init so CI uses the same provider versions:
`terraform providers lock -platform=linux_amd64 -platform=darwin_arm64`

## Shipping the app

1. Change code in `app/`, open a PR: **app** workflow runs tests, hadolint, build, Trivy scan and a container smoke test - with no AWS access.
2. Merge: the same pipeline pushes the scanned image to ECR as `sunshine-app:<git sha>` (immutable tag).
3. **lab-up**: the platform stack deploys the newest image *by digest*; ECS rolls it out (circuit breaker + rollback), and the smoke test fails the run if the live version isn't the one just deployed.
4. Roll back: set `app_image_tag = "<older sha>"` in `platform/terraform.tfvars` and run lab-up.

Debugging a task: set `enable_ecs_exec = true` (this also makes the root filesystem writable - the two are mutually exclusive), run lab-up, then `aws ecs execute-command ...`.

## Cost guardrails

- Budgets measure spend **before credits**: monthly ($25, alerts at 50/80/100% + forecast) and daily ($4) — a forgotten EKS cluster trips the daily one within a day.
- Running cost with everything on is about $0.12/hr: NAT (~$0.05), ALB + 2 public IPs (~$0.035), RDS t4g.micro (~$0.02), 2 small Fargate tasks with one on Spot (~$0.015). Each piece has an `enable_*` toggle.
- Deliberate lab trade-offs (each documented as an inline `#checkov:skip`): single NAT, SSE-S3 instead of KMS CMKs, no DNSSEC/query logging, no S3 replication.

## Roadmap

- [x] 1. Account baseline + CI identity
- [x] 2. Network + DNS
- [x] 3. Data: RDS Postgres (private, Secrets Manager-managed password), S3 app bucket
- [x] 4. ECS Fargate service behind ALB, HTTPS with the wildcard cert (on-demand base + Spot, autoscaling, ECS Exec)
- [x] 4b. Own container image: ECR, test/scan/push pipeline, image pinned by digest, DB secret injected, smoke test
- [ ] 5. EKS: spot node group, AWS LB Controller, ExternalDNS, External Secrets, NLB service
- [ ] 6. Identity: Cognito/Keycloak OIDC login, K8s RBAC mapped to IAM roles
- [ ] 7. Hardening: WAF, image signing/scanning gates, runbooks
