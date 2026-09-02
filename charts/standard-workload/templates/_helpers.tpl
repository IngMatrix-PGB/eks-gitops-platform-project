{{- define "standard-workload.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "standard-workload.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "standard-workload.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "standard-workload.labels" -}}
app.kubernetes.io/name: {{ include "standard-workload.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/component: workload
app.kubernetes.io/part-of: {{ include "standard-workload.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "standard-workload.selectorLabels" -}}
app.kubernetes.io/name: {{ include "standard-workload.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
