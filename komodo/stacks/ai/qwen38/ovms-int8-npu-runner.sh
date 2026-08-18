#!/bin/sh
# Fail-closed, bounded NPU compatibility probe for the existing INT8 VLM IR.

set -eu

model_dir=/model
alias=${QWEN_ALIAS:?QWEN_ALIAS is required}
max_prompt_len=${QWEN_MAX_PROMPT_LEN:?QWEN_MAX_PROMPT_LEN is required}
min_response_len=${QWEN_MIN_RESPONSE_LEN:?QWEN_MIN_RESPONSE_LEN is required}
npu_platform=${QWEN_NPU_PLATFORM:?QWEN_NPU_PLATFORM is required}

case "$max_prompt_len:$min_response_len" in
  1024:128) ;;
  *)
    printf 'Refusing unreviewed NPU prompt/response pair: prompt=%s response=%s\n' \
      "$max_prompt_len" "$min_response_len" >&2
    exit 64
    ;;
esac

case "$npu_platform" in
  5010) ;;
  *)
    printf 'Refusing unreviewed NPU platform: %s\n' "$npu_platform" >&2
    exit 64
    ;;
esac

if [ ! -c /dev/accel/accel0 ]; then
  printf 'Required NPU device is unavailable: /dev/accel/accel0\n' >&2
  exit 69
fi

if [ -e /dev/dri ]; then
  printf 'GPU device path is unexpectedly visible; refusing ambiguous NPU probe.\n' >&2
  exit 65
fi

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

printf 'Verifying immutable OpenVINO artifact checksums before NPU startup.\n'
if ! (cd "$model_dir" && sha256sum --check --strict SHA256SUMS); then
  printf 'OpenVINO artifact checksum verification failed.\n' >&2
  exit 65
fi

# OpenVINO parses this environment variable numerically. It gives the startup
# log the best chance of exposing the compiled language model's execution
# device without enabling AUTO or HETERO fallback.
OPENVINO_LOG_LEVEL=4
OVMS_GRAPH_QUEUE_OFF=1
export OPENVINO_LOG_LEVEL OVMS_GRAPH_QUEUE_OFF

printf 'QWEN38_OVMS_BACKEND device=NPU platform=%s pipeline=VLM max_prompt_len=%s min_response_len=%s precision=int8-experimental fallback=forbidden graph_queue=off model=%s\n' \
  "$npu_platform" "$max_prompt_len" "$min_response_len" "$alias"
printf 'QWEN38_OVMS_DEVICE_MAP accel0=present dri=absent target=NPU\n'

exec /ovms/bin/ovms \
  --model_path "$model_dir" \
  --model_name "$alias" \
  --rest_port 8080 \
  --rest_workers 1 \
  --log_level DEBUG \
  --metrics_enable \
  --task text_generation \
  --target_device NPU \
  --pipeline_type VLM \
  --max_prompt_len "$max_prompt_len" \
  --plugin_config "{\"DEVICE_PROPERTIES\":{\"NPU\":{\"NPU_PLATFORM\":\"$npu_platform\",\"MAX_PROMPT_LEN\":$max_prompt_len,\"MIN_RESPONSE_LEN\":$min_response_len}}}"
