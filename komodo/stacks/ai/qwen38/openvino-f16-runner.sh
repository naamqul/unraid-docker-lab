#!/bin/sh
set -eu

: "${QWEN_ALIAS:?QWEN_ALIAS is required}"
: "${QWEN_CONTEXT:?QWEN_CONTEXT is required}"
: "${QWEN_CACHE_TYPE:?QWEN_CACHE_TYPE is required}"
: "${QWEN_KV_OFFLOAD:?QWEN_KV_OFFLOAD is required}"
: "${QWEN_MTP:?QWEN_MTP is required}"
: "${QWEN_VISION:?QWEN_VISION is required}"

set -- /app/llama-server \
  --model /models/Qwen3.8-27B-ABLITERATED-Q6_K.gguf \
  --alias "$QWEN_ALIAS" \
  --host 0.0.0.0 --port 8080 \
  --ctx-size "$QWEN_CONTEXT" --parallel 1 \
  --threads 16 --threads-batch 16 \
  --cache-type-k "$QWEN_CACHE_TYPE" --cache-type-v "$QWEN_CACHE_TYPE" \
  --flash-attn on --batch-size 2048 --ubatch-size 512 \
  --cache-ram 0 --ctx-checkpoints 0 --no-cache-idle-slots \
  --fit off --no-context-shift --no-warmup --mmap \
  --jinja --metrics --slots --perf --timeout 3600

if [ "$QWEN_KV_OFFLOAD" = "0" ]; then
  set -- "$@" --no-kv-offload
fi

if [ "$QWEN_MTP" = "1" ]; then
  set -- "$@" \
    --spec-type draft-mtp \
    --spec-draft-n-max 1 \
    --spec-draft-p-min 0.0
fi

if [ "$QWEN_VISION" = "1" ]; then
  set -- "$@" \
    --mmproj /models/mmproj-Qwen3.8-27B-ABLITERATED-F16.gguf \
    --no-mmproj-offload \
    --image-max-tokens 1024 \
    --mtmd-batch-max-tokens 1024
fi

exec "$@"
