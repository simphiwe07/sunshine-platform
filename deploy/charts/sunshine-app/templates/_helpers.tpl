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
