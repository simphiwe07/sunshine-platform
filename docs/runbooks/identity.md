# Identity: sign-in for people, RBAC for operators

Two separate questions, one role model (viewer / developer / admin):

| Layer | Who | Proves identity with | Decides permissions with |
|---|---|---|---|
| App users | browser | Cognito hosted UI (password + TOTP MFA) → ALB session cookie | Cognito group in the access token (`/admin` needs `admin`) |
| Cluster operators | kubectl | IAM role (SSO session → assume persona role) | EKS access entry → Kubernetes group → RBAC |

```
browser ──► ALB ──(no cookie)──► 302 Cognito hosted UI ──► /oauth2/idpresponse ──► ALB swaps code for tokens
                 └─(cookie ok)──► pod + x-amzn-oidc-data (ALB-signed claims) + x-amzn-oidc-accesstoken (Cognito, groups)

kubectl ──► aws eks get-token (persona role) ──► EKS access entry ──► groups sunshine:viewers / sunshine:developers ──► RBAC
```

## Order of rollout (once)

1. Merge the PR. **foundation-apply** creates the user pool, its groups, the hosted-UI domain and the ALB client. If it fails with `OperationNotPermitted` (account restriction, like the NLB), set `enable_cognito = false` in foundation and `enable_auth = false` in platform-k8s.
2. Wait for the **app** workflow to push the new image (adds `/me`, `/admin`, `/logout`; `/healthz` now reports the version).
3. **lab-up** (or re-run it if the lab is already up: applies are idempotent). The EKS smoke test now also checks that `/` redirects to Cognito and that `/metrics` returns 404 from the ALB.

## Create users (one per persona)

Users live in the foundation stack, so this is once, not per lab session. Invite-only: no self sign-up.

```bash
export AWS_PROFILE=sunshine AWS_REGION=eu-west-1
POOL=$(aws cognito-idp list-user-pools --max-results 10 \
  --query "UserPools[?Name=='sunshine-lab'].Id | [0]" --output text)

add_user() { # add_user <email> <group>
  aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$1" \
    --user-attributes Name=email,Value="$1" Name=email_verified,Value=true \
    --desired-delivery-mediums EMAIL > /dev/null
  aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" --username "$1" --group-name "$2"
}
add_user 'you+viewer@example.com' viewer   # plus-addressing: three users, one inbox
add_user 'you+dev@example.com'    developer
add_user 'you+admin@example.com'  admin

aws cognito-idp list-users-in-group --user-pool-id "$POOL" --group-name admin --query 'Users[].Username'
```

Cognito emails a temporary password (valid 3 days). First sign-in: new password (14+ chars), then scan the TOTP QR code with an authenticator app.

## Test app sign-in

```bash
curl -sI https://eks.simptechit.click/ | grep -i '^location'   # -> https://simptechit-lab.auth.eu-west-1.amazoncognito.com/oauth2/authorize?...
curl -s  https://eks.simptechit.click/healthz                   # public: {"status":"ok","version":"<sha>"}
curl -s -o /dev/null -w '%{http_code}\n' https://eks.simptechit.click/metrics   # 404 (blocked at the ALB)
```

In a browser (private window per user):

| URL | viewer | developer | admin |
|---|---|---|---|
| `/` | 200 | 200 | 200 |
| `/me` | email + `["viewer"]` | `["developer"]` | `["admin"]` |
| `/admin` | **403** | **403** | 200 |
| `/logout` | back to the sign-in page | | |

Optional, to prove the app does not trust the headers blindly - from inside the cluster (NetworkPolicy blocks other pods, so port-forward as admin):

```bash
kubectl -n sunshine port-forward deploy/sunshine-app 8080:8080 &
curl -s localhost:8080/me -H 'x-amzn-oidc-data: e30.e30.e30' -H 'x-amzn-oidc-accesstoken: x'   # 401
```

## Test Kubernetes personas

`~/.aws/config` (the persona roles trust the admin SSO role; ARNs: `terraform output eks_persona_role_arns` in platform):

```ini
[profile sunshine-viewer]
role_arn          = arn:aws:iam::033147048268:role/sunshine-lab-eks-viewer
source_profile    = sunshine
role_session_name = simphiwe
region            = eu-west-1

[profile sunshine-developer]
role_arn          = arn:aws:iam::033147048268:role/sunshine-lab-eks-developer
source_profile    = sunshine
role_session_name = simphiwe
region            = eu-west-1
```

```bash
for p in viewer developer; do
  aws eks update-kubeconfig --name sunshine-lab --region eu-west-1 --profile sunshine-$p --alias sunshine-$p
done
kubectl config use-context sunshine-admin 2>/dev/null || aws eks update-kubeconfig --name sunshine-lab --region eu-west-1 --profile sunshine --alias sunshine-admin

kubectl --context sunshine-developer auth whoami     # Username developer:simphiwe, Groups sunshine:viewers, sunshine:developers
```

Expected (`kubectl --context sunshine-<persona> auth can-i ...`):

| Check | viewer | developer |
|---|---|---|
| `list pods -A` | yes | yes |
| `get secrets -n sunshine` | **no** | **no** |
| `patch deployment/sunshine-app -n sunshine` | no | yes |
| `delete pods -n sunshine` | no | yes |
| `create pods/exec -n sunshine` | no | **no** |
| `delete pods -n kube-system` | no | no |
| `create clusterrolebindings` | no | no |

Then for real:

```bash
kubectl --context sunshine-viewer    -n sunshine rollout restart deploy/sunshine-app   # Forbidden
kubectl --context sunshine-developer -n sunshine rollout restart deploy/sunshine-app   # restarted
kubectl --context sunshine-developer -n sunshine get secret sunshine-db                # Forbidden
```

Audit trail: CloudWatch Logs `/aws/eks/sunshine-lab/cluster`, Logs Insights:

```
fields @timestamp, user.username, verb, objectRef.resource, objectRef.name, responseStatus.code
| filter user.username like /developer:/ | sort @timestamp desc | limit 20
```

## If something fails

| Symptom | Cause |
|---|---|
| Cognito page says `redirect_mismatch` | Callback URL not in the client (`auth_app_hostnames` in foundation). |
| ALB returns **500** right after sign-in | ALB can't reach Cognito's token endpoint, or the client has no secret. |
| `/me` 401 "signed by an unknown load balancer" | ALB name doesn't start with `k8s-sunshine-` (IngressGroup renamed) - fix `signerPrefix` in platform-k8s `auth.tf`. |
| `/me` 401 "bad ALB token (InvalidSignatureError)" | Base64 padding not stripped, or the key came from another region. |
| `aws eks update-kubeconfig --profile sunshine-developer` AccessDenied on AssumeRole | Your SSO session is not `AccountFullAccessRole`, or the platform stack hasn't been applied. |

## Interview notes

- **Why at the ALB?** No auth code in every service; unauthenticated traffic never reaches a pod; the client secret stays in AWS (the ALB fetches it from Cognito).
- **Why verify again in the app?** Headers are just text. Defence in depth: NetworkPolicy (only the ALB subnets reach the pod) + ALB signature (`signer` = our ALB, `client` = our app client) + Cognito signature on the access token, same `sub` in both.
- **Gotchas found:** ALB tokens keep base64 padding, so PyJWT reports a bad signature until you strip it. ALB has no logout, so expire the `AWSELBAuthSessionCookie-*` shards and redirect to Cognito `/logout`.
- **Access policies vs RBAC:** EKS access policies are AWS-managed and coarse (admin, admin-view, view). Kubernetes groups + RBAC give exact rules, e.g. "restart the app, but no Secrets and no exec". Exec and port-forward are excluded on purpose because they bypass the ALB sign-in and NetworkPolicy.
- **Production next step:** an Identity Center permission set per persona instead of role chaining, or EKS OIDC identity provider config (Cognito/Keycloak groups → Kubernetes groups) with kubelogin.
