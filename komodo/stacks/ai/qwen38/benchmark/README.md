# Arc Qwen3.8 runner benchmark

The completed 2026-08-16 Arc comparison and retained configuration are recorded
in [`RESULTS-20260816.md`](RESULTS-20260816.md).

The `qwen38-sycl` profile is retained only to reproduce the documented B390
load failure. Keep it stopped until a newer Intel llama.cpp build is validated.

This directory contains a dependency-free benchmark client for comparing
multiple OpenAI-compatible Qwen3.8 runners with the same fixed workload. The
Python client does not start, stop, reconfigure, or download anything. Runner
lifecycle stays in Komodo/llama-swap. The separate `safety-watch.sh` is an
opt-in host guard that can stop only one explicitly allowlisted Qwen3.8 service
through Komodo if host memory crosses the configured floor.

The checked-in corpus exercises:

- OpenAI chat text generation;
- OpenAI chat vision using a local, checksummed PNG fixture;
- a tokenizer-calibrated 32K prompt;
- a tokenizer-calibrated near-limit retrieval probe (90% of configured context).

Each request is streamed so the client can measure time to first token and
stream-chunk latency. It also records server timings, usage, Prometheus metric
deltas, speculative draft/accept counts, context evidence, correctness checks,
and safety status. Every run writes both JSON and CSV.

## Requirements

- Python 3.10 or newer; only the standard library is used.
- A runner exposing `POST /v1/chat/completions`.
- For 32K and near-limit probes, a llama.cpp-compatible `POST /tokenize`
  endpoint. With llama-swap, set `native_base_url` to the selected runner's
  `/upstream/<model-id>` route. Estimated token counts are disabled by default.
- For MTP counters, expose the selected runner's `/metrics` endpoint.

## Configure the Arc runners

`runners.arc.example.json` matches the loopback ports and 262K/MTP1 aliases in
the sibling Arc Compose and llama-swap files. `runners.generic.example.json`
is a deployment-neutral starting point. Copy a template to a run-specific
file before changing it. Secrets are referenced by environment variable name
and are never written to results.

Each runner may be one of:

- `upstream-cpu`
- `ik-cpu`
- `openvino-npu`
- `intel-sycl`

The backend label is metadata plus a validation policy; the harness never
changes devices. OpenVINO NPU and Intel SYCL profiles should provide
startup-log evidence and at least one numeric accelerator activity counter.
This prevents a CPU fallback from being accepted as an accelerator result.

Validate the corpus and runner file without making a network request:

```bash
python3 benchmark.py \
  --runner-config runners.arc.example.json \
  --validate-only
```

Run all configured runners:

```bash
python3 benchmark.py \
  --runner-config runners.arc.example.json \
  --abort-file /tmp/qwen38-benchmark/abort-RUN_ID \
  --output-dir /path/to/results
```

The Arc template selects `*-262k-mtp1`. If 262K cannot pass the memory and
exact-context gates, make a copied 131K runner file with these replacements:

| Runner | 262K value | 131K fallback |
| --- | --- | --- |
| upstream native/model | `qwen38-upstream-262k-mtp1` | `qwen38-upstream-131k-mtp1` |
| ik native/model | `qwen38-ik-262k-mtp1` | `qwen38-ik-131k-mtp1` |
| OpenVINO port/model | `9295` / `qwen38-openvino-262k-vision` | `9297` / `qwen38-openvino-131k-vision` |
| every runner context | `262144` | `131072` |

The upstream and ik llama-swap files also expose `mtp2` and `mtp3` aliases.
Change both `model` and the final component of `native_base_url` together when
running those follow-up sweeps. The current OpenVINO service does not enable
MTP, so its Arc profile explicitly disables the nonzero-MTP gate and names the
lane `openvino-npu-feasibility`. It can establish real NPU execution and vision
compatibility, but it is not an MTP-parity result.

Run selected profiles/workloads while debugging:

```bash
python3 benchmark.py \
  --runner-config /path/to/runners.json \
  --runner upstream-cpu \
  --workload text_interactive \
  --workload vision_interactive \
  --repetitions 1 \
  --output-dir /path/to/results
```

A single endpoint can be supplied without a JSON runner file:

```bash
python3 benchmark.py \
  --runner-name upstream-cpu \
  --backend upstream-cpu \
  --base-url http://127.0.0.1:8080/v1 \
  --native-base-url http://127.0.0.1:8080 \
  --model qwen38-upstream-cpu \
  --context 262144 \
  --output-dir ./results
```

## Safety behavior

The harness aborts before the next request when any of these occurs:

- the optional stop file exists;
- local `MemAvailable` falls below the configured floor;
- the configured consecutive-error limit is reached;
- a generated prompt plus output reserve would exceed context;
- the server reports a different context while exact-context checking is on.

It never invokes SSH, Docker, Komodo, llama-swap lifecycle endpoints, or shell
commands. Partial results are atomically retained when a run aborts. Set
`require_memory_check` only when the harness runs on the inference host; a
remote client cannot measure the server's `/proc/meminfo`.

### Guard model loading on Arc

The Python floor cannot protect memory consumed before Python reaches its
first check. Before the approved service start/model load, create a private
temporary directory and start the host watcher from a second SSH session or a
detached `setsid` wrapper. Arc does not ship `tmux`. Use a fresh abort filename;
the watcher intentionally refuses to remove or reuse one.

```bash
install -d -m 700 /tmp/qwen38-benchmark
sh safety-watch.sh qwen38-upstream /tmp/qwen38-benchmark/abort-RUN_ID 8
```

Pass that same path to Python with `--abort-file`. Stop the watcher with
Ctrl-C after the finite run. Valid service arguments are exactly the seven
`qwen38-*` benchmark services in `compose.yaml`. At the threshold, the watcher
touches the abort file and runs only:

```text
docker exec komodo km execute -y stop-stack ai 10 SERVICE
```

It has no code path for Lunar, the Docker daemon, another stack, or Arc power
control. An unreadable `MemAvailable` is treated as unsafe and invokes the same
single-service stop. The optional third argument, or `MIN_FREE_GIB`, sets the
floor; it defaults to 8 GiB.

For an NPU runner, `require_backend_evidence` and `require_activity` default to
true. The Arc template expects finite startup-log files under
`/tmp/qwen38-benchmark` and an Intel NPU busy-time counter. Capture the selected
service's startup log there after it loads, and adjust the counter path to the
installed driver. A finite HTTP evidence endpoint may instead be supplied with
`backend_evidence_url`; do not point it at a never-ending log stream. A runner
is rejected if the counter does not increase during a measured request. Do not
disable these checks for a result presented as NPU.

## Output

The JSON file is authoritative. The CSV is a flattened request table for quick
comparison. Large prompts and full model responses are not copied into output:
their SHA-256 digests, sizes, token counts, correctness checks, and a short
response preview are recorded instead.

The most useful fields are:

- `ttft_seconds`
- `duration_seconds`
- `stream_interval_p50_seconds` / `stream_interval_p95_seconds`
- `prompt_tokens_per_second` / `predicted_tokens_per_second`
- `draft_tokens` / `accepted_tokens` / `acceptance_rate`
- `reported_prompt_tokens`
- `context_truncated`
- `correctness_passed`
- `memory_available_before_bytes` / `memory_available_after_bytes`

Do not compare runners unless they used the same corpus hash, image hash,
context, sampling settings, and successfully passed the applicable context,
vision, MTP, and backend-evidence gates. Keep the non-MTP OpenVINO feasibility
lane separate from upstream-versus-ik MTP winner selection.
