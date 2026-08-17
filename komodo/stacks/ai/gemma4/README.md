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
- CPU set and threads: CPUs `0-15`, 16 decode and 16 batch threads
- Context/cache: one 131,072-token slot with q8_0 K/V cache
- Vision: BF16 projector on CPU, with no operator-specified image-token cap
- Speculation: external MTP head, `draft-mtp`, `n_max=1`, `p_min=0`
- Resource policy: 32 GiB hard memory limit, no swap, CPU shares 256
- Model idle TTL: 600 seconds
- Loopback API: `http://127.0.0.1:9315/v1`
- Open WebUI provider URL: `http://gemma4:8080/v1` on `caddy-backend`

The primary model ID is `gemma4-26b-a4b-131k-mtp1`. Thinking is enabled and
hard-bounded to 512 tokens so a pathological thought loop cannot consume the
entire response allowance without producing visible content. llama-swap
exposes `gemma4-26b-a4b-131k-mtp1-no-thinking` as a request-filter alias on the
same loaded process; it sets `enable_thinking=false` and a zero reasoning
budget. The aliases do not load duplicate model copies. Open WebUI prefixes
this provider, so its selector shows `arc.gemma4-26b-a4b-131k-mtp1` and
`arc.gemma4-26b-a4b-131k-mtp1-no-thinking`.

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
| retained speed + MTP1 | 23.49 tok/s | 83.58 tok/s | 23.90 tok/s | 34.56 tok/s |

The full-CPU policy materially improved prompt ingestion, especially for the
uncapped 4K image, while its live contention probe remained healthy: seven
Lunar QGA probes had 14.61 ms mean and 16.91 ms maximum latency, and seven
Caddy probes had 0.37 ms mean and 0.45 ms maximum latency, with no failures.

MTP1 improved median text generation by 23.7% over the same speed/base policy.
Its two text runs accepted 111 of 147 draft tokens (75.5%) and produced 24.00
and 22.99 tok/s. The vision run accepted 20 of 20 and produced 23.90 tok/s,
about 29.8% above the speed/base median. MTP2 produced 22.97 tok/s at 62.1%
acceptance; MTP3 produced 19.61 tok/s at 43.4%. They were not retained.

The final production combination also passed with thinking enabled. The
512-token cap produced visible text at 22.25 tok/s and correct 4K vision at
22.18 tok/s, both with `finish_reason=stop`. End-to-end server time was about
35.24 seconds for text and 36.26 seconds for vision. The no-thinking alias is
the latency-oriented alternative.

The service used about 22 GiB while loaded and remained above the 10 GiB host
`MemAvailable` guard. Lunar stayed running and QGA-responsive; the B390 stayed
bound to `vfio-pci`. These results establish idle-Lunar coexistence, not an
active Moonlight-stream contention result.

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
