# Admin UIs: Argo CD and Grafana behind sign-in

| Cluster | Argo CD | Grafana |
|---|---|---|
| non-prod (`sunshine-lab`: dev + staging) | https://argocd.simptechit.click | https://grafana.simptechit.click |
| prod (`sunshine-prod`) | https://argocd-prod.simptechit.click | https://grafana-prod.simptechit.click |

```
browser ─► WAF ─► ALB: Cognito sign-in (same as the app) ─► Argo CD / Grafana
                                                             └─► their own OIDC login with the same
                                                                 Cognito pool - silent, the session exists
```

Two locks: the **ALB** keeps anonymous traffic away from the tools completely, and **each tool** maps your Cognito group to its own role from the ID token (`cognito:groups`):

| Cognito group | Argo CD | Grafana |
|---|---|---|
| `admin` | admin | Admin |
| `developer` | get + sync apps (non-prod); read-only (prod) | Editor |
| `viewer` | read-only | Viewer |
| none | no access | Viewer |

They share the app's ALB (IngressGroup `sunshine`): one load balancer, one certificate, one WAF.

## Rollout order (once)

1. Merge. **foundation-apply** creates the Cognito clients `argocd` and `grafana`, and adds the admin hostnames to the ALB client's callbacks.
2. **lab-up** and **prod-up** (or re-run them while up). Argo CD and Grafana get their Ingresses, OIDC settings and client secrets, and ExternalDNS adds the four records within about a minute.
3. Open the URLs. You sign in once at the ALB; Argo CD needs one click on **"Log in via Cognito"**, and Grafana logs you in automatically.

## Test the roles

Use one private window per user, as in the identity runbook:
- `+admin`: Argo CD can sync, edit and delete apps; Grafana shows Admin (Administration menu visible).
- `+dev`: Argo CD can **Sync** `sunshine-app-dev` and `-staging` on argocd.simptechit.click, but on argocd-prod only view; Grafana is Editor.
- `+viewer`: Argo CD is read-only (Sync greyed out); Grafana is Viewer.

## Break-glass (Cognito or ALB down)

The local admin users still work through port-forward:
```bash
kubectl --context sunshine-admin -n argocd port-forward svc/argocd-server 8080:80        # http://localhost:8080 (HTTP now: TLS ends at the ALB)
kubectl --context sunshine-admin -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl --context sunshine-admin -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000/login?disableAutoLogin  (skips the Cognito redirect), user admin:
kubectl --context sunshine-admin -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```
Use `--context sunshine-prod` for prod. Argo CD's CLI goes through port-forward too (`argocd login localhost:8080 --plaintext`), because the ALB sign-in needs a browser.

## If something breaks

| Symptom | Look at |
|---|---|
| Cognito "redirect_mismatch" | The hostname is missing from the callbacks: `auth_app_hostnames` (ALB client), or `argocd_hostnames` / `grafana_hostnames` (tool clients) in the foundation stack. Did foundation-apply run? |
| platform-k8s apply: `index ... "argocd"` not found | The Cognito clients don't exist yet. Run foundation-apply first. |
| Argo CD "failed to verify ID token" / "invalid issuer" | `oidc.config` issuer must be exactly `https://cognito-idp.eu-west-1.amazonaws.com/<pool id>`: `kubectl -n argocd get cm argocd-cm -o yaml` |
| Argo CD login works but you see no apps | You're in no group, or not the right one (`policy.default` is empty). Check `kubectl -n argocd get cm argocd-rbac-cm -o yaml` and the user's groups in Cognito. |
| Grafana "Login failed" | `kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana \| grep -i oauth`. The client secret comes from Secret `grafana-oidc`. |
| 403 in Grafana or Argo CD from WAF | WAF logs, "Blocked, by rule" query (waf runbook). Override that single rule to count, as was done for `SizeRestrictions_BODY` (large Grafana query bodies). |
| ALB `502` on the admin host | Target health check: Argo CD `/healthz`, Grafana `/api/health`. `kubectl -n argocd get pods`, `kubectl -n monitoring get pods`. |

## Interview notes

- **Defence in depth for admin tools:** WAF, then the ALB's sign-in (anonymous traffic never reaches them), then the tool's own OIDC and RBAC (least privilege per group), with local admins only via port-forward as break-glass.
- **One identity source, roles everywhere:** the same Cognito groups drive the app (`/admin`), Kubernetes (IAM personas → RBAC), Argo CD and Grafana.
- **Environment-aware permissions:** developers can sync non-prod in Argo CD but only look at prod, via the same chart and a different variable per cluster.
- **WAF tuning:** managed rules false-positive on legitimate admin traffic (large JSON bodies). Override the single rule to count, scoped to what's needed, rather than disabling the group.
