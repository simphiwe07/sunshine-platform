{{- define "app.labels" -}}
app.kubernetes.io/name: sunshine-app
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "app.selector" -}}
app.kubernetes.io/name: sunshine-app
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- /*
ALB settings shared by every Ingress in the group. IngressGroup members are
merged into ONE ALB, so listener/load-balancer settings must be identical;
target-group settings too, since both Ingresses route to the same Service.
*/}}
{{- define "app.albAnnotations" -}}
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/group.name: {{ .Values.ingress.groupName }}
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
alb.ingress.kubernetes.io/ssl-redirect: "443"
alb.ingress.kubernetes.io/certificate-arn: {{ .Values.ingress.certificateArn }}
alb.ingress.kubernetes.io/ssl-policy: {{ .Values.ingress.sslPolicy }}
alb.ingress.kubernetes.io/healthcheck-path: /healthz
alb.ingress.kubernetes.io/load-balancer-attributes: routing.http.drop_invalid_header_fields.enabled=true
alb.ingress.kubernetes.io/target-group-attributes: deregistration_delay.timeout_seconds=30
{{- end }}
