{{- define "cartforge.labels" -}}
app.kubernetes.io/part-of: cartforge
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}