{{- /*
Copyright 2020 Hewlett Packard Enterprise Development LP
*/ -}}
{{- define "cray-k8s-encryption.common-annotations" -}}
cray.io/service: {{ include "cray-k8s-encryption.name" . }}
{{ with .Values.annotations -}}
{{ toYaml . -}}
{{- end -}}
{{- end -}}
