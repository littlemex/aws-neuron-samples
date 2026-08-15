{{/* Workload name: explicit .Values.name, else the model's last path segment. */}}
{{- define "svc.name" -}}
{{- if .Values.name }}{{ .Values.name }}{{- else -}}
{{- required "set .Values.name or .Values.model" .Values.model | base | lower | replace "." "-" | replace "_" "-" -}}
{{- end -}}
{{- end -}}

{{- define "svc.cachePvc" -}}
{{- if .Values.cache.pvcName }}{{ .Values.cache.pvcName }}{{ else }}{{ include "svc.name" . }}-cache{{ end -}}
{{- end -}}

{{/* Tolerations shared by every Neuron serving pod. */}}
{{- define "svc.tolerations" -}}
- { key: aws.amazon.com/neuron, operator: Exists, effect: NoSchedule }
- { key: vpc.amazonaws.com/efa, operator: Exists, effect: NoSchedule }
- { key: capacity-reservation, operator: Exists, effect: NoSchedule }
{{- end -}}

{{/* resources block (neuron always; efa only when efaCount>0). */}}
{{- define "svc.resources" -}}
requests:
  aws.amazon.com/neuron: {{ .Values.neuronDevices | quote }}
  {{- if gt (int .Values.efaCount) 0 }}
  vpc.amazonaws.com/efa: {{ .Values.efaCount | quote }}
  {{- end }}
  cpu: {{ .Values.cpu | quote }}
  memory: {{ .Values.memory | quote }}
limits:
  aws.amazon.com/neuron: {{ .Values.neuronDevices | quote }}
  {{- if gt (int .Values.efaCount) 0 }}
  vpc.amazonaws.com/efa: {{ .Values.efaCount | quote }}
  {{- end }}
  memory: {{ .Values.memory | quote }}
{{- end -}}

{{/* Common env for the vLLM Neuron server. */}}
{{- define "svc.env" -}}
- { name: VLLM_NEURON_FRAMEWORK, value: neuronx-distributed-inference }
- { name: NEURON_COMPILED_ARTIFACTS, value: {{ .Values.cache.mountPath | quote }} }
{{- if .Values.skipEfaAffinity }}
- { name: NEURON_SKIP_EFA_AFFINITY, value: "1" }
- { name: FI_PROVIDER, value: efa }
- { name: FI_EFA_IFACE, value: all }
{{- end }}
{{- if .Values.serialTraceWorkers }}
- { name: VLLM_NEURON_PARALLEL_TRACE_WORKERS, value: "1" }
{{- end }}
{{- if .Values.hfTokenSecret }}
- name: HF_TOKEN
  valueFrom:
    secretKeyRef: { name: {{ .Values.hfTokenSecret | quote }}, key: token, optional: true }
{{- end }}
{{- range $k, $v := .Values.env }}
- { name: {{ $k | quote }}, value: {{ $v | quote }} }
{{- end }}
{{- end -}}

{{/* vLLM OpenAI server args as one shell line (for `exec python ... <args>` in svc.startCmd). */}}
{{- define "svc.vllmArgsLine" -}}
--model={{ required "set .Values.model" .Values.model }}
{{- if .Values.servedModelName }} --served-model-name={{ .Values.servedModelName }}{{ end }}
{{- " " }}--tensor-parallel-size={{ .Values.tpSize }} --max-model-len={{ .Values.maxModelLen }} --max-num-seqs={{ .Values.maxNumSeqs }} --dtype={{ .Values.dtype }} --port={{ .Values.port }}
{{- if .Values.trustRemoteCode }} --trust-remote-code{{ end }}
{{- range .Values.extraArgs }} {{ . }}{{ end }}
{{- end -}}

{{/* Container startup script: optionally install a PR-branch model into the plugin, then exec vLLM. */}}
{{- define "svc.startCmd" -}}
set -euo pipefail
{{- if .Values.plugin.install }}
echo "[plugin-install] {{ .Values.plugin.repo }}@{{ .Values.plugin.ref }} -> model/{{ .Values.plugin.modelDir }}"
PLUGIN=$(python -c 'import importlib.util,os;print(os.path.dirname(importlib.util.find_spec("vllm_neuron").origin))')
TMP=$(mktemp -d)
curl -fsSL "https://codeload.github.com/{{ .Values.plugin.repo }}/tar.gz/refs/heads/{{ .Values.plugin.ref }}" | tar xz -C "$TMP" --strip-components=1
rm -rf "$PLUGIN/model/{{ .Values.plugin.modelDir }}"
cp -r "$TMP/vllm_neuron/model/{{ .Values.plugin.modelDir }}" "$PLUGIN/model/{{ .Values.plugin.modelDir }}"
VN_REG="$PLUGIN/model/registry.py" VN_MOD="{{ .Values.plugin.modelDir }}" VN_CLS="{{ .Values.plugin.registerClass }}" python - <<'PYEOF'
import os, re
reg = os.environ["VN_REG"]; mod = os.environ["VN_MOD"]; cls = os.environ["VN_CLS"]
s = open(reg).read(); orig = s
# idempotent: strip any prior entry, then add import + registry tuple
s = re.sub(r'\nfrom \.%s import [^\n]*\n' % mod, '\n', s)
s = re.sub(r'\s*\("%s",\s*%s\),' % (cls, cls), '', s)
if 'from .%s import %s' % (mod, cls) not in s:
    m = re.search(r'\nfrom \.\w+ import \w+', s); assert m, "no anchor import"
    s = s[:m.start()] + '\nfrom .%s import %s' % (mod, cls) + s[m.start():]
if '"%s"' % cls not in s.split('def get_models')[1]:
    anchor = '("Qwen3VLForConditionalGeneration", Qwen3VLForConditionalGeneration),'
    assert anchor in s, "Qwen3VL registry anchor not found"
    s = s.replace(anchor, anchor + '\n        ("%s", %s),' % (cls, cls))
open(reg, "w").write(s)
print("[plugin-install] registry patched (changed=%s)" % (s != orig))
PYEOF
{{- end }}
exec python -m vllm.entrypoints.openai.api_server {{ include "svc.vllmArgsLine" . }}
{{- end -}}

{{/* vLLM OpenAI server args, shared by single- and multi-node. */}}
{{- define "svc.vllmArgs" -}}
- --model={{ required "set .Values.model" .Values.model }}
{{- if .Values.servedModelName }}
- --served-model-name={{ .Values.servedModelName }}
{{- end }}
- --tensor-parallel-size={{ .Values.tpSize }}
- --max-model-len={{ .Values.maxModelLen }}
- --max-num-seqs={{ .Values.maxNumSeqs }}
# The Neuron device is selected automatically by the activated vllm_neuron platform plugin;
# this vLLM build's api_server has no --device flag.
- --dtype={{ .Values.dtype }}
- --port={{ .Values.port }}
{{- if .Values.trustRemoteCode }}
- --trust-remote-code
{{- end }}
{{- range .Values.extraArgs }}
- {{ . }}
{{- end }}
{{- end -}}
