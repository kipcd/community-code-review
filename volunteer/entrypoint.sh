#!/bin/bash
set -e

COORDINATOR_URL="${COORDINATOR_URL:?COORDINATOR_URL is required}"
VOLUNTEER_ID="${VOLUNTEER_ID:-$(hostname)-$$}"
MODEL_REPO="${MODEL_REPO:-Qwen/Qwen3-30B-A3B-GGUF}"
MODEL_FILE="${MODEL_FILE:-qwen3-30b-a3b-q4_k_m.gguf}"
MODEL_URL="${MODEL_URL:-}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-32768}"
LLAMA_N_PARALLEL="${LLAMA_N_PARALLEL:-1}"
LLAMA_TEMP="${LLAMA_TEMP:-0.7}"
MODEL_PATH="/models/${MODEL_FILE}"

GPU_INFO="CPU (no GPU detected)"
LLAMA_N_GPU_LAYERS="${LLAMA_N_GPU_LAYERS:-99}"

detect_gpu() {
    if command -v nvidia-smi &>/dev/null; then
        local smi_out
        smi_out=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -5)
        if [ -n "${smi_out}" ]; then
            GPU_INFO=$(echo "${smi_out}" | head -1)
            return 0
        fi
    fi
    return 1
}

case "${GPU_DEVICES:-}" in
    "") if detect_gpu; then export CUDA_VISIBLE_DEVICES="0"; else LLAMA_N_GPU_LAYERS=0; fi ;;
    "none") LLAMA_N_GPU_LAYERS=0 ;;
    "all") if detect_gpu; then unset CUDA_VISIBLE_DEVICES; else LLAMA_N_GPU_LAYERS=0; fi ;;
    *) export CUDA_VISIBLE_DEVICES="${GPU_DEVICES}"; if ! detect_gpu; then LLAMA_N_GPU_LAYERS=0; fi ;;
esac
export GPU_INFO

download_model() {
    local url=$1 dest=$2
    curl -# -L "${url}" -o "${dest}.tmp" 2>&1
    if [ $? -ne 0 ]; then rm -f "${dest}.tmp"; exit 1; fi
    mv "${dest}.tmp" "${dest}"
}

if [ ! -f "${MODEL_PATH}" ]; then
    DOWNLOAD_URL="${MODEL_URL:-https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}}"
    download_model "${DOWNLOAD_URL}" "${MODEL_PATH}"
fi

echo "Starting llama-server..."
/app/llama-server -m "${MODEL_PATH}" --host 0.0.0.0 --port "${LLAMA_PORT}" -ngl "${LLAMA_N_GPU_LAYERS}" -c "${LLAMA_CTX_SIZE}" -np "${LLAMA_N_PARALLEL}" --no-ui --no-warmup &
LLAMA_PID=$!

for i in $(seq 1 30); do
    if curl -sf "http://localhost:${LLAMA_PORT}/health" >/dev/null 2>&1; then break; fi
    [ $i -eq 30 ] && exit 1
    sleep 1
done

echo "Starting agent..."
cd /app && python3 agent.py &
AGENT_PID=$!

trap "kill ${LLAMA_PID} ${AGENT_PID} 2>/dev/null; exit 0" SIGTERM SIGINT
echo "Volunteer running"
wait -n 2>/dev/null || wait
