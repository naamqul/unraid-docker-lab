#!/bin/sh
# Fail-closed launcher for the preconverted Qwen3.8 INT8 OpenVINO VLM.

set -eu

model_dir=/model
device=${QWEN_DEVICE:?QWEN_DEVICE is required}
context=${QWEN_CONTEXT:?QWEN_CONTEXT is required}
cache_gib=${QWEN_CACHE_GIB:?QWEN_CACHE_GIB is required}
alias=${QWEN_ALIAS:?QWEN_ALIAS is required}

case "$device" in
  CPU|GPU) ;;
  *)
    printf 'Unsupported QWEN_DEVICE: %s\n' "$device" >&2
    exit 64
    ;;
esac

case "$context:$cache_gib" in
  131072:6|262144:10) ;;
  *)
    printf 'Refusing unreviewed context/cache pair: context=%s cache=%s GiB\n' \
      "$context" "$cache_gib" >&2
    exit 64
    ;;
esac

for file in \
  config.json \
  openvino_language_model.bin \
  openvino_language_model.xml \
  openvino_text_embeddings_model.bin \
  openvino_text_embeddings_model.xml \
  openvino_vision_embeddings_model.bin \
  openvino_vision_embeddings_model.xml \
  openvino_vision_embeddings_pos_model.bin \
  openvino_vision_embeddings_pos_model.xml \
  openvino_vision_embeddings_merger_model.bin \
  openvino_vision_embeddings_merger_model.xml \
  openvino_tokenizer.bin \
  openvino_tokenizer.xml \
  openvino_detokenizer.bin \
  openvino_detokenizer.xml \
  processor_config.json \
  preprocessor_config.json \
  SHA256SUMS; do
  if [ ! -f "$model_dir/$file" ]; then
    printf 'Required OpenVINO artifact file is missing: %s/%s\n' "$model_dir" "$file" >&2
    exit 66
  fi
done

if ! grep -Eq '"model_type"[[:space:]]*:[[:space:]]*"qwen3_5"' \
  "$model_dir/config.json"; then
  printf 'config.json does not identify the expected qwen3_5 architecture.\n' >&2
  exit 65
fi

max_context=$(awk -F: '
  /"max_position_embeddings"[[:space:]]*:/ {
    value=$2
    gsub(/[,[:space:]]/, "", value)
    print value
    exit
  }
' "$model_dir/config.json")

case "$max_context" in
  ''|*[!0-9]*)
    printf 'Could not read max_position_embeddings from config.json.\n' >&2
    exit 65
    ;;
esac

if [ "$max_context" -lt "$context" ]; then
  printf 'Requested context %s exceeds artifact maximum %s.\n' \
    "$context" "$max_context" >&2
  exit 65
fi

printf 'Verifying immutable OpenVINO artifact checksums before startup.\n'
if ! (cd "$model_dir" && sha256sum --check --strict SHA256SUMS); then
  printf 'OpenVINO artifact checksum verification failed.\n' >&2
  exit 65
fi

OVMS_GRAPH_QUEUE_OFF=1
export OVMS_GRAPH_QUEUE_OFF

printf 'QWEN38_OVMS_BACKEND device=%s context=%s cache_gib=%s kv=u8 prefix_cache=false graph_queue=off model=%s\n' \
  "$device" "$context" "$cache_gib" "$alias"

exec /ovms/bin/ovms \
  --model_path "$model_dir" \
  --model_name "$alias" \
  --rest_port 8080 \
  --rest_workers 1 \
  --log_level INFO \
  --metrics_enable \
  --task text_generation \
  --target_device "$device" \
  --pipeline_type VLM_CB \
  --max_num_seqs 1 \
  --enable_prefix_caching false \
  --cache_size "$cache_gib" \
  --kv_cache_precision u8
