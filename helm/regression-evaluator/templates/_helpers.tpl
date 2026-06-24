{{- define "regression-evaluator.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "regression-evaluator.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "regression-evaluator.secretName" -}}
{{- if .Values.db.existingSecret -}}
{{ .Values.db.existingSecret }}
{{- else -}}
{{ include "regression-evaluator.fullname" . }}-db
{{- end -}}
{{- end -}}
