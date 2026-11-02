# Drill: demand growth -> pod autoscaling -> node autoscaling

Goal: watch the whole chain react to rising demand and settle back afterwards:

```
traffic up -> pod CPU > 60% of request -> HPA adds pods -> pods Pending (nodes full)
          -> Cluster Autoscaler adds Spot nodes -> pods scheduled -> latency recovers
traffic down -> HPA removes pods (after 2 min) -> nodes underused -> CA drains & removes them (after 3 min)
```

## Prepare (after lab-up)

```bash
brew install k6
aws eks update-kubeconfig --name sunshine-lab --region eu-west-1 --profile sunshine

# Grafana (not public): leave this running in its own terminal
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```
Open http://localhost:3000 (user `admin`) -> Dashboards -> **Sunshine - demand, pods and nodes**.
Also useful: *Kubernetes / Compute Resources / Namespace (Pods)* and *Node Exporter / Nodes*.

## Watch (one terminal each)

```bash
kubectl -n sunshine get hpa -w                                   # TARGETS cpu: x%/60%, REPLICAS
kubectl get nodes -L eks.amazonaws.com/capacityType -w           # nodes joining / leaving
kubectl -n sunshine get pods -o wide -w | grep -E 'Pending|Running'
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-cluster-autoscaler -f --tail=20 \
  | grep -iE 'scale-up|scale_up|scaled up|unneeded|scale-down|removing'
```

## Run

The WAF rate limit (300 requests per IP per minute) would block k6 within seconds - it is one IP
sending ~40 req/s. Raise it for the drill, then put it back (local apply of platform-k8s):

```bash
cd terraform/envs/lab/platform-k8s && export TF_VAR_state_bucket=sunshine-tfstate-033147048268
terraform init -backend-config="bucket=$TF_VAR_state_bucket" && terraform apply -var waf_rate_limit=100000
cd -   # ... after the drill: terraform apply (default limit again)
```

```bash
# /burn is behind Cognito sign-in: sign in as any user in a browser, copy the
# Cookie request header from DevTools (Network tab), then:
export COOKIE='AWSELBAuthSessionCookie-0=...; AWSELBAuthSessionCookie-1=...'
k6 run -e COOKIE="$COOKIE" loadtest/scale-out.js   # ~17 min; add -e PEAK_RPS=20 -e HOLD=3m for a shorter run
```

## Expected timeline (record actual times)

| t | What happens | Where to see it |
|---|---|---|
| 0-3 min | warm-up; CPU per pod rises past 0.15 cores (60% of 250m); HPA 2 -> ~6 pods | panel 3, 4; `get hpa` |
| ~3-5 min | surge; HPA wants up to 16; pods **Pending** (2 nodes full) | panel 4 (desired > current), 5 |
| +~1 min | CA logs a scale-up; node group desired 2 -> 3/4/5 | CA logs; `aws eks describe-nodegroup` |
| +~2-3 min | new Spot nodes Ready; Pending pods scheduled; p95 latency falls | panel 2, 5, 6 |
| hold | steady state at N nodes / M pods | all panels flat |
| ramp-down | load ends; HPA scales in after 2 min stabilisation | panel 4 |
| +3 min | CA marks nodes unneeded, drains them (PDB respected), removes them | CA logs; node count back to 2 |

## Questions to be able to answer afterwards

1. How long from first Pending pod to the new node being Ready? (pod-to-node latency is the real
   cost of reactive autoscaling - mitigations: over-provisioning "pause" pods, Karpenter, bigger nodes.)
2. Did the HPA hit maxReplicas (16)? If so, the bottleneck moved from nodes to the HPA ceiling.
3. p95 latency and k6 `http_req_failed` during the surge - what did users feel?
4. Why does the CA add nodes based on **requests**, not actual CPU? (It simulates scheduling: a
   pod that doesn't fit by requests is Pending, whatever the real usage.)

## Notes

- Cluster Autoscaler runs `v1.36.1` on a 1.37 cluster (1.37.0 image not yet published at build
  time). Bump `cluster_autoscaler_image_tag` in `platform-k8s` once it is.
- ALB-generated 502/504s never reach the app, so they are not in the app's metrics; k6 sees them.
- Spot: if a Spot pool has no capacity the node group tries the other instance types; persistent
  `InsufficientInstanceCapacity` shows up in CA logs and `aws eks describe-nodegroup ... health`.
