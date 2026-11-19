{{- define "postgres-lab.labels" -}}
app.kubernetes.io/name: postgres-lab
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: database
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "postgres-lab.selectorLabels" -}}
app.kubernetes.io/name: postgres-lab
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- /* Phase 6.3d: the dump Job's pods - never matched by the postgres
selector (component differs and name is postgres-lab-dump). */ -}}
{{- define "postgres-lab.dumpSelectorLabels" -}}
app.kubernetes.io/name: postgres-lab-dump
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: dump
{{- end }}
