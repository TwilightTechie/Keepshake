#!/usr/bin/env bash
# Runs the local vLLM-SR Decision Classifier Service on Mac Mini and ensures the SSH reverse tunnel to VPS is active.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="/Users/anup_mini/code/vllm_inference/.venv/bin/python"
VPS_HOST="root@168.144.190.24"
SSH_KEY="/Users/anup_mini/.ssh/id_ed25519"

# 1. Start Decision Service if not already running on port 11435
if ! curl -s http://127.0.0.1:11435/health > /dev/null 2>&1; then
    echo "[Decision Stack] Starting vLLM-SR Decision Service on port 11435..."
    nohup "$PYTHON_BIN" "$SCRIPT_DIR/decision_service.py" > /tmp/decision_service.log 2>&1 &
    sleep 3
fi

# 2. Start reverse tunnel for port 11435 if not already active
if ! ps aux | grep -v grep | grep -q "11435:127.0.0.1:11435"; then
    echo "[Decision Stack] Starting SSH reverse tunnel for port 11435 to VPS..."
    nohup /usr/bin/ssh -N -T -R 11435:127.0.0.1:11435 \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o StrictHostKeyChecking=no \
        -i "$SSH_KEY" "$VPS_HOST" > /tmp/decision_tunnel.log 2>&1 &
    sleep 2
fi

echo "[Decision Stack] Status:"
curl -s http://127.0.0.1:11435/health | jq . || curl -s http://127.0.0.1:11435/health
