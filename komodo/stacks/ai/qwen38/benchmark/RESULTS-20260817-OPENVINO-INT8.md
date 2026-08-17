# Qwen3.8 OpenVINO INT8 benchmark - 2026-08-17

## Outcome

The verified OpenVINO INT8 VLM runs correctly on Arc's CPU and B390 GPU with
OVMS/OpenVINO GenAI 2026.4. CPU is the better sustained-generation backend at
131K; GPU has much lower time to first token and is the only backend that
completed the practical 32K-context probe. Neither backend validated usable
near-limit 262K operation under the required 8 GiB host-memory floor.

The existing INT8 IR cannot compile for the Panther Lake NPU. After explicitly
pinning the NPU5010 compiler platform, compilation failed with an FP16-only
bufferization requirement. No NPU inference or fallback occurred. A future NPU
experiment therefore needs a separate, supported symmetric INT4/NF4 artifact;
it cannot reuse this INT8 IR.

## Fixed inputs

- Model: `Blackfrost-AI/Qwen3.8-27B-ABLITERATED-int8-ov`
- Arc path: `/mnt/user/models/Blackfrost-AI/Qwen3.8-27B-ABLITERATED-int8-ov`
- Model manifest: 22/22 payloads passed `sha256sum -c SHA256SUMS`
- Model-manifest SHA-256:
  `261548c8a275b4907156f0acb2ef24533a57761eef9254239e1ef01cce1e0c25`
- Image:
  `openvino/model_server@sha256:7eb60804f86d7f47fd278a0cc1958fde5f8493534062ae69bef27dc5ba439cf2`
- Server stack: OVMS/OpenVINO/OpenVINO GenAI 2026.4
- KV cache: U8, 10 GiB
- One runner at a time; 8 GiB host `MemAvailable` guard
- Raw bundle:
  `/mnt/user/models/Blackfrost-AI/Qwen3.8-27B-ABLITERATED-int8-ov/benchmark-results/20260817-openvino-int8`

## Result matrix

| Backend / context | Test | Result | TTFT | Decode | Safety / interpretation |
| --- | --- | --- | ---: | ---: | --- |
| CPU / 131K | Text, 365 prompt + 512 completion | Correct | 16.85 s | 3.43 tok/s | Guard clear |
| CPU / 131K | Vision, 371 prompt + 209 completion | Correct, natural stop | 22.48 s | 3.47 tok/s | Guard clear |
| GPU / 131K | Text, 365 + 512 | Correct | 2.08 s | 2.37 tok/s | B390 execution confirmed |
| GPU / 131K | Vision, 371 + 512 | Correct | 2.64 s | 2.37 tok/s | B390 execution confirmed |
| CPU / 262K | Short text + vision smoke | Correct | 23.96 / 21.17 s | n/a | Guard clear |
| CPU / 262K | 32K prompt | Bounded stop; no response byte in 16m26s | >986 s | n/a | Decision-complete timeout; projected near-limit prefill >108 min |
| GPU / 262K | Short text + vision smoke | Correct | 5.45 / 3.19 s | n/a | Guard clear |
| GPU / 262K | 33,107 prompt + 256 completion | HTTP success; marker found in reasoning | 156.44 s | 2.04 tok/s | 281.31 s total; final channel absent because reasoning used the cap |
| GPU / 262K | 236,008-token near-limit prompt | Safety abort before first byte | n/a | n/a | `MemAvailable` crossed 8 GiB; no OOM or GPU fault |
| NPU / 1K | Load/compile only | Unsupported INT8 precision path | n/a | n/a | No readiness, request, NPU activity, or fallback |

At 131K, CPU sustained generation was about 45% faster than GPU. GPU TTFT was
about 8x faster. The 131K CPU graph-pool-off soak passed six of six requests:
three text and three vision. An earlier 256-token GPU vision response used its
entire allowance in reasoning; the required 512-token rerun produced correct
final content and is the result shown above.

The GPU 32K response explicitly retrieved `FORGE-32K-7319` in reasoning, so it
demonstrates long-prompt admission and retrieval. It is not counted as a final
answer correctness pass because the output cap ended before final content. The
236,008-token probe was calibrated to 90.03% of the 262,144-token window and
was stopped by the memory guard immediately after request admission. It makes
no TTFT, retrieval, or full-context-success claim.

## NPU compile blocker

The bounded NPU profile mapped only `/dev/accel/accel0`; `/dev/dri` was absent,
the target was exactly `NPU`, and AUTO/HETERO fallback was prohibited. The
first load exposed a compiler autodetection issue:

```text
Unsupported platform: 'AUTO_DETECT'
```

Arc's `0xB03E` NPU is NPU5010, so the retry set the documented
`NPU_PLATFORM=5010`. It then reached the model compiler and failed with the
decisive precision error:

```text
[vpux-compiler] OneShotBufferizeVPU2VPUIP failed : Only supports FP16.
Compilation failed
```

OVMS ended in `LOADING_PRECONDITION_FAILED`; `npu_busy_time_us` stayed zero.
No request was sent, no device fault occurred, and CPU/GPU fallback was
impossible under the device mapping and exact target.

## OVMS graph-pool workaround

Initial VLM_CB requests intermittently failed with:

```text
Packet timestamp mismatch ... expected 1, received 0
```

Disabling OVMS MediaPipe graph pooling with `OVMS_GRAPH_QUEUE_OFF=1` eliminated
the failure and the repeated 131K CPU soak passed 6/6. All retained benchmark
profiles keep graph pooling disabled. This is a server graph-reuse workaround,
not a model conversion change.

## Recommendation

Retain CPU 131K as the practical OpenVINO INT8 configuration when sustained
generation matters. GPU is attractive for short prompts because of its much
lower TTFT, but its decode rate is slower and its 262K near-limit request
violated the host-memory floor. Do not advertise 262K as validated for this
configuration. Do not run this INT8 IR on NPU again; export a separate symmetric
INT4/NF4 model only if a follow-up experimental NPU lane is approved.

## Final host state

All OpenVINO runners, clients, guards, and monitoring processes were stopped.
Lunar remained shut off. The B390 remained bound to `xe`, the NPU remained
bound to `intel_vpu`, available host memory recovered, and the final kernel
fault scan was empty. No Unraid or Docker daemon restart was performed.
