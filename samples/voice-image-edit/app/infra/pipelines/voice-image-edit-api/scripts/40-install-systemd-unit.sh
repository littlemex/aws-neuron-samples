#!/usr/bin/env bash
# Render the voice-image-edit-api.service systemd unit and install it under
# /etc/systemd/system. This task only writes the file - 50-enable-start
# does the daemon-reload + start sequence so the unit is read fresh.
#
# All Bedrock / Trainium / Polly wiring flows through env vars: the unit
# listens on 0.0.0.0:$API_PORT and the FastAPI app reads each setting via
# env_required() in engines/_common/env.py.
set -euo pipefail

unit_file=/etc/systemd/system/voice-image-edit-api.service

cat > "$unit_file" <<EOF
[Unit]
Description=voice-image-edit API backend (FastAPI/uvicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${API_USER}
WorkingDirectory=${API_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=LOG_LEVEL=INFO
Environment=AWS_REGION=${AWS_REGION}
Environment=AWS_DEFAULT_REGION=${AWS_REGION}
Environment=BEDROCK_REGION=${BEDROCK_REGION}
Environment=GENERATE_BEDROCK_REGION=${GENERATE_BEDROCK_REGION}
Environment=EDIT_BEDROCK_REGION=${EDIT_BEDROCK_REGION}
Environment=POLLY_REGION=${POLLY_REGION}
Environment=EDIT_RESULT_BUCKET=${EDIT_RESULT_BUCKET}
Environment=EDIT_RESULT_REGION=${EDIT_RESULT_REGION}
Environment=EDIT_RESULT_TTL_SECONDS=${EDIT_RESULT_TTL_SECONDS}
Environment=EDIT_RESULT_PREFIX=${EDIT_RESULT_PREFIX}
Environment=ASR_ENGINE_DEFAULT=${ASR_ENGINE_DEFAULT}
Environment=VLM_ENGINE_DEFAULT=${VLM_ENGINE_DEFAULT}
Environment=EDIT_ENGINE_DEFAULT=${EDIT_ENGINE_DEFAULT}
Environment=BEDROCK_ASR_BACKEND=${BEDROCK_ASR_BACKEND}
Environment=BEDROCK_CLAUDE_OPUS_MODEL_ID=${BEDROCK_CLAUDE_OPUS_MODEL_ID}
Environment=BEDROCK_NOVA_PRO_MODEL_ID=${BEDROCK_NOVA_PRO_MODEL_ID}
Environment=BEDROCK_NOVA_LITE_MODEL_ID=${BEDROCK_NOVA_LITE_MODEL_ID}
Environment=BEDROCK_NOVA_CANVAS_MODEL_ID=${BEDROCK_NOVA_CANVAS_MODEL_ID}
Environment=BEDROCK_VLM_MODEL_ID=${BEDROCK_VLM_MODEL_ID}
Environment=TRAINIUM_ASR_URL=${TRAINIUM_ASR_URL}
Environment=TRAINIUM_VLM_URL=${TRAINIUM_VLM_URL}
Environment=TRAINIUM_EDIT_URL=${TRAINIUM_EDIT_URL}
Environment=TRAINIUM_TTS_URL=${TRAINIUM_TTS_URL}
Environment=TRAINIUM_EDIT_MODEL_ID=${TRAINIUM_EDIT_MODEL_ID}
ExecStart=${API_DIR}/venv/bin/uvicorn app:app --host 0.0.0.0 --port ${API_PORT} --proxy-headers --no-server-header --timeout-keep-alive 75
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "[OK] unit installed at $unit_file"
