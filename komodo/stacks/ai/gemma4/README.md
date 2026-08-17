# Arc Gemma 4 production runner

The retained Arc configuration is upstream `llama-server` behind
`llama-swap`, running CPU-only while Lunar keeps exclusive ownership of the
B390. It is an ordinary, unprofiled service in the Komodo `ai` stack and keeps
only the lightweight proxy resident when the model is idle.

## Retained configuration

- Service/container: `gemma4`
- Image: `ghcr.io/mostlygeek/llama-swap:cpu@sha256:f06135baf7195a2e3bb43fabff9e348a9f192e26644e6c758b090df965a2ab41`
- Runtime: llama-swap v250 with upstream llama.cpp b10438,
  revision `9d57ce456c94d241dde672b2db9cf18879766568`
- CPU set and threads: quiet CPUs `4-11`, 8 decode and 8 batch threads
- Context/cache: one native 262,144-token slot with F16 K/V cache
- Vision: BF16 projector on CPU with a 1,120-token maximum visual budget
- Chat template: Google Gemma 4 canonical template from official revision
  `4d7ae4984b7db7de8f8457170b3f1a419ee76d52`
- Speculation: external MTP head, `draft-mtp`, `n_max=1`, `p_min=0`
- Resource policy: 32 GiB hard memory limit, no swap, CPU shares 256
- Model idle TTL: 600 seconds
- Loopback API: `http://127.0.0.1:9315/v1`
- Open WebUI provider URL: `http://gemma4:8080/v1` on `caddy-backend`

The primary model ID is `Gemma (Thinking)`. Thinking is enabled and
hard-bounded to 512 tokens so a pathological thought loop cannot consume the
entire response allowance without producing visible content. llama-swap
exposes `Gemma (Instruct)` as a request-filter alias on the
same loaded process; it sets `enable_thinking=false` and a zero reasoning
budget. The aliases do not load duplicate model copies. The Arc Open WebUI
provider deliberately has no model-ID prefix, so its selector shows exactly
`Gemma (Thinking)` and `Gemma (Instruct)`.
The optional llama-swap display-name field is deliberately omitted so clients
fall back to each distinct model ID instead of giving both aliases the base
model's display name.

The vendored `chat_template.jinja` is byte-for-byte from the official
`google/gemma-4-26B-A4B-it` repository at revision
`4d7ae4984b7db7de8f8457170b3f1a419ee76d52`; its SHA-256 is
`ae53464bf3be25802b3a5b37def7fd89667067d7577049b3b2d74c4d8de4c6d4`.
Its attribution, pinned source, and Apache-2.0 license are retained in the
adjacent `chat_template.PROVENANCE.md` and `chat_template.LICENSE` files.
The explicit file attachment avoids relying on the older template embedded in
the quantized GGUF. The official 1,120-token visual setting is enforced with
`--image-max-tokens 1120`; actual image tokens can be lower after aspect-ratio
preserving resize and 48-pixel grid alignment.

## Measured selection result

The 2026-08-17 selection used the same deterministic text request and native
4096 x 4096 synthetic vision input for every candidate. Rates below are
server-reported; base-policy values are medians of two measured requests where
two are shown. All listed responses passed correctness and ended with
`finish_reason=stop`.

| CPU policy | Text generation | Text prefill | Vision generation | Vision prefill |
| --- | ---: | ---: | ---: | ---: |
| quiet, CPUs 4-11 | 18.50 tok/s | 48.58 tok/s | 17.18 tok/s | 17.68 tok/s |
| balanced, CPUs 4-15 | 18.76 tok/s | 69.13 tok/s | 17.82 tok/s | 19.71 tok/s |
| speed, CPUs 0-15 | 18.98 tok/s | 87.23 tok/s | 18.41 tok/s | 34.41 tok/s |
| initial speed + MTP1 selection | 23.49 tok/s | 83.58 tok/s | 23.90 tok/s | 34.56 tok/s |

The full-CPU policy materially improved prompt ingestion, especially for the
uncapped 4K image, while its live contention probe remained healthy: seven
Lunar QGA probes had 14.61 ms mean and 16.91 ms maximum latency, and seven
Caddy probes had 0.37 ms mean and 0.45 ms maximum latency, with no failures.

MTP1 improved median text generation by 23.7% over the same speed/base policy.
Its two text runs accepted 111 of 147 draft tokens (75.5%) and produced 24.00
and 22.99 tok/s. The vision run accepted 20 of 20 and produced 23.90 tok/s,
about 29.8% above the speed/base median. MTP2 produced 22.97 tok/s at 62.1%
acceptance; MTP3 produced 19.61 tok/s at 43.4%. They were not retained.

The initial speed-policy production combination also passed with thinking enabled. The
512-token cap produced visible text at 22.25 tok/s and correct 4K vision at
22.18 tok/s, both with `finish_reason=stop`. End-to-end server time was about
35.24 seconds for text and 36.26 seconds for vision. The no-thinking alias is
the latency-oriented alternative.

## Current 262K F16 verification

The operator-selected quiet 262K F16 configuration was promoted on 2026-08-17
and passed a guarded cold load plus both text aliases and the native 4096 x
4096 vision request. These are single promotion smokes, not a new comparative
benchmark:

| Request | Generation | Prefill | MTP acceptance |
| --- | ---: | ---: | ---: |
| no-thinking text | 23.15 tok/s | 45.32 tok/s | 5 / 5 |
| bounded-thinking text | 18.92 tok/s | 48.62 tok/s | 334 / 395 |
| bounded-thinking 4K vision | 18.36 tok/s | 18.14 tok/s | 263 / 290 |

All three responses ended with `finish_reason=stop`; the thinking requests had
nonempty reasoning and visible content, and the vision answer identified all
four panels, the divider, and the calibration bars. The same single
`llama-server` child served both aliases.

The short-prompt cgroup peak was 16.08 GiB and sampled host `MemAvailable`
never fell below 29.03 GiB. All cgroup OOM counters remained zero. This is not
the fully populated 262K cache footprint: the exact-fit projection remains
about 25.6-25.9 GiB as KV pages are touched, so the 32 GiB service cap and 10
GiB host guard remain mandatory. No near-limit prompt was run.

The main model declares 262K context, but the external MTP path logs a warning
that its 262K sequence exceeds a 131K training context. Long-position quality
and speculative acceptance beyond 131K therefore remain unverified.

Lunar stayed running and QGA-responsive; the B390 stayed bound to `vfio-pci`.
These results establish idle-Lunar coexistence, not an active Moonlight-stream
contention result.

## Pinned artifacts

Source: `HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP`,
revision `f9093662a2e7ae0503f637088bc96f77a1a70c83`.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-Q4_K_M.gguf` | 16,796,015,520 | `3c13133469e431312fffb8b1d9c85ae42199e6bb5746ea1da84e8ddf2097d73c` |
| `mmproj-Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-BF16.gguf` | 1,194,827,776 | `b5346e5bfd906f5e16878c2d0b8243e948ca7410fa28ea35be9b0c54a0ac10b7` |
| `mtp-gemma-4-26B-A4B-it.gguf` | 251,937,728 | `62bd3af7f66c9308de9a5454233852f8c7324c93767e8dfb824ed45b9179864a` |

The revision-qualified model directory must contain exactly these three files.
Benchmark evidence lives separately under
`/mnt/cache/models/benchmark-results/gemma4-26b-a4b-f9093662`.

## Operation

Use Komodo for lifecycle control:

```bash
docker exec komodo km execute -y deploy-stack ai gemma4 120
docker exec komodo km execute -y stop-stack ai 120 gemma4
```

A normal `deploy-stack ai` includes both Open WebUI and the lightweight Gemma
proxy. Do not start another large Arc inference profile at the same time. A
Gemma stop or redeploy does not require stopping Lunar, rebinding the B390,
restarting Docker, or restarting Arc.
