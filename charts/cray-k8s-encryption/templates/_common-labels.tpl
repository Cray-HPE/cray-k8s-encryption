{{- /*
Copyright 2020 Hewlett Packard Enterprise Development LP
*/ -}}
{{- define "cray-k8s-encryption.common-labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
{{ with .Values.labels -}}
{{ toYaml . -}}
{{- end -}}
{{- end -}}
