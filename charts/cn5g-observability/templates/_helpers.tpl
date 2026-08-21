{{- define "cn5g-observability.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "cn5g-observability.labels" -}}
app.kubernetes.io/name: cn5g-observability
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/part-of: cn5g-platform
cn5g.io/domain: observability
{{- end }}

{{- define "cn5g-observability.componentLabels" -}}
{{ include "cn5g-observability.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
The data volumeClaimTemplates were created by chart 0.1.0. Kubernetes makes
the entire StatefulSet claim-template specification immutable, including its
metadata labels, so this lineage label must remain at the originally accepted
value even when the owning chart advances. Labels on the StatefulSet, Pod, and
bound PVC resources continue to use the current chart version.
*/}}
{{- define "cn5g-observability.retainedClaimTemplateLabels" -}}
app.kubernetes.io/name: cn5g-observability
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: cn5g-observability-0.1.0
app.kubernetes.io/part-of: cn5g-platform
cn5g.io/domain: observability
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "cn5g-observability.selectorLabels" -}}
app.kubernetes.io/name: cn5g-observability
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "cn5g-observability.componentName" -}}
{{- printf "%s-%s" (include "cn5g-observability.fullname" .root) .component | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "cn5g-observability.image" -}}
{{- printf "%s:%s@%s" .repository .tag .digest -}}
{{- end }}

{{- define "cn5g-observability.localImage" -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end }}
