{{- define "cn5g.name" -}}
cn5g
{{- end }}

{{- define "cn5g.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "cn5g.componentName" -}}
{{- printf "%s-%s" (include "cn5g.fullname" .root) .component | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "cn5g.labels" -}}
app.kubernetes.io/name: {{ include "cn5g.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/part-of: cn5g-core
{{- end }}

{{- define "cn5g.componentLabels" -}}
{{ include "cn5g.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "cn5g.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cn5g.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "cn5g.image" -}}
{{- if .digest -}}
{{- printf "%s:%s@%s" .repository .tag .digest -}}
{{- else -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
{{- end }}

{{- define "cn5g.serviceAccountName" -}}
{{- printf "%s-workload" (include "cn5g.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}
