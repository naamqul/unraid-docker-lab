# Archived Arc Qwen3.8 inference trials

This package preserves the completed August 2026 Arc Qwen3.8 CPU, NPU, Vulkan,
SYCL, and OpenVINO experiments. It was removed from the production `ai` Compose
manifest on 2026-08-19 so normal AI-stack operations describe only Open WebUI
and the Gemma 4 llama-swap service.

Nothing in this directory is currently registered with Komodo or deployed on
Arc. The archived Compose project is deliberately named
`arc-qwen38-archive`, distinct from production `ai`, and every one of its 22
services remains behind an explicit profile. The original digest-pinned images,
runner configurations, launch scripts, benchmark harness, fixture, and result
summaries are retained together.

Model artifacts and raw result bundles remain outside Git at their documented
paths under `/mnt/user/models` and `/mnt/cache/models`; this cleanup did not
delete or move them. OCI images already cached by Docker were also left alone.

## Restoring a trial

Treat restoration as a new, explicitly approved deployment:

1. Revalidate the pinned image and model-artifact checksums, host devices,
   loopback port availability, memory limits, and Lunar/VFIO safety boundary.
2. Register a separate Komodo Files-on-host Stack rooted at this directory,
   with both stack and Compose project named `arc-qwen38-archive`.
3. Set `KOMODO_STACK=arc-qwen38-archive` before starting the archived memory
   guard. It intentionally refuses to run without an explicit non-production
   stack name.
4. Start exactly one profiled service, verify its backend and memory guard, run
   the bounded benchmark, then stop that service.

Do not copy these services back into `komodo/stacks/ai/compose.yaml`, register
this directory as the production `ai` stack, or run multiple large candidates
together.
