{{- /*
Copyright 2020 Hewlett Packard Enterprise Development LP
*/ -}}
{{- define "cray-k8s-encryption.pod-annotations" -}}
{{ if .Values.podAnnotations -}}
{{ with .Values.podAnnotations -}}
{{ toYaml . -}}
{{- end -}}
{{- end -}}
{{- end -}}
