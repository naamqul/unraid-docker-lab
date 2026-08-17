# Arc Gemma 4 production runner

The retained Arc configuration is upstream `llama-server` behind
`llama-swap`, running CPU-only while Lunar keeps exclusive ownership of the
B390. It is an ordinary, unprofiled service in the Komodo `ai` stack and keeps
only the lightweight proxy resident when the model is idle.

## Retained configuration

- Service/container: `gemma4`
- Image: moving CPU channel `ghcr.io/mostlygeek/llama-swap:cpu`, resolved and
  validated at `sha256:c88bef25891a575e4e2bb09cf7b11940a03b6c253f4fe6b14e87c37046054564`
- Runtime: llama-swap v250 with upstream llama.cpp b10454,
  revision `4df29be4f4c3673f428170fda944a5b19f743bb8`
- CPU set and threads: quiet CPUs `4-11`, 8 decode and 8 batch threads
- Context/cache: one native 262,144-token slot with F16 K/V cache
- Vision: BF16 projector on CPU with a 1,120-token maximum visual budget
- Batch/microbatch: 2,048 logical and 2,048 physical tokens
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

The initial 2026-08-17 selection, before the b10454 image refresh, used the
same deterministic text request and native
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
| bounded-thinking 4K vision (legacy 280-token image budget) | 18.36 tok/s | 18.14 tok/s | 263 / 290 |

All three responses ended with `finish_reason=stop`; the thinking requests had
nonempty reasoning and visible content, and the vision answer identified all
four panels, the divider, and the calibration bars. The same single
`llama-server` child served both aliases.

After attaching the current official chat template and increasing the visual
budget, the same 4096 x 4096 fixture passed through the public Caddy endpoint
with 1,193 prompt tokens. Its square image resolves to 1,089 visual soft
tokens under Gemma 4's 48-pixel grid alignment. Prefill was 9.12 tok/s,
generation was 16.09 tok/s, MTP accepted 140 of 150 drafts (93.3%), server
processing took 148.82 seconds, and end-to-end time was 160.27 seconds. The
answer correctly identified all four shapes and colors, the white divider,
and the calibration bars, with nonempty reasoning, visible content, and
`finish_reason=stop`.

The first 1,120-budget attempt exposed llama.cpp's non-causal vision constraint:
the previous 512-token microbatch was smaller than the image embedding and the
model child exited. Raising `--ubatch-size` to 1,152 fixed the request and
established the safe minimum; the later b10454 A/B below determined whether a
larger production value was worth its allocation. The b10438 vision-run cgroup
peak was 17.02 GiB, sampled host `MemAvailable` stayed above 28.10 GiB, and all
cgroup OOM counters remained zero.

This is still not the fully populated 262K cache footprint. The exact-fit
projection, including the larger vision microbatch, is about 26.4-26.7 GiB as
KV pages are touched, leaving roughly 5.3-5.6 GiB below the 32 GiB service
cap. The 10 GiB host guard remains mandatory, and no near-limit prompt was
run.

The main model declares 262K context, but the external MTP path logs a warning
that its 262K sequence exceeds a 131K training context. Long-position quality
and speculative acceptance beyond 131K therefore remain unverified.

Lunar stayed running and QGA-responsive; the B390 stayed bound to `vfio-pci`.
These results establish idle-Lunar coexistence, not an active Moonlight-stream
contention result.

## Refreshed b10454 batch result

The refreshed image was tested with the same CPU set, artifacts, 262K F16
slot, MTP1, and official template. Each candidate received one warm-up followed
by three exact 4,096-token, uncached `Gemma (Instruct)` prefills with one output
token:

| Batch / microbatch | Prefill runs | Median | Median end to end |
| --- | --- | ---: | ---: |
| 2,048 / 1,152 | 34.14, 33.79, 37.43 tok/s | 34.14 tok/s | 120.02 s |
| 2,048 / 2,048 | 38.61, 38.94, 39.00 tok/s | 38.94 tok/s | 105.21 s |

The 2,048-token physical microbatch improved median prompt ingestion by 14.07%
and is retained. Raising the logical batch above its existing 2,048-token
default was not justified: the CPU-only, single-slot path still executes 4K
input as two logical batches, and no additional measured gain supported a
larger value.

The retained candidate then passed both aliases and a native 4096 x 4096
vision gate at the 1,120-token visual budget. Instruct returned visible content
without reasoning at 20.22 generation tok/s; Thinking returned reasoning plus
visible content at 21.61 tok/s. Vision used 1,142 prompt tokens, reached 9.42
prefill and 15.19 generation tok/s, completed in 124.21 seconds, and correctly
reported all four colors and the white divider. Every gate ended with
`finish_reason=stop`.

The measured 2,048-token vision peak was 17.68 GiB and sampled host
`MemAvailable` stayed at or above 28.18 GiB; every cgroup memory and OOM counter
remained zero. The exact b10454 estimator attributes 5,720 MiB to context and
2,130 MiB to compute at this setting, 1,082 MiB more than microbatch 1,152.
The projected fully populated service footprint is therefore about 27.5-27.8
GiB, leaving about 4.2-4.5 GiB below the 32 GiB cap. The separate 10 GiB host
availability guard still applies.

Evidence is under
`/mnt/cache/models/benchmark-results/gemma4-26b-a4b-f9093662/20260817T151000Z-ubatch-b10454`.

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
