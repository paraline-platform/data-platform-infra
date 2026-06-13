{{- define "spark-thrift-server.name" -}}
{{- .Release.Name }}
{{- end }}

{{- define "spark-thrift-server.labels" -}}
app: {{ include "spark-thrift-server.name" . }}
app.kubernetes.io/name: spark-thrift-server
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
