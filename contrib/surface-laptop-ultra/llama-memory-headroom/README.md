# Optional llama.cpp worker admission on the Surface Laptop Ultra

The GB10 GPU shares system RAM with the desktop and CPU jobs. During the October 19, 2026 pressure incident, NVIDIA logged `NV_ERR_NO_MEMORY` while llama.cpp, FineWeb processing, and Chromium were running. systemd-oomd killed a Ghostty scope and the llama-server service. A high-context Q8 experiment on November 22 also coincided with NVIDIA allocation failures and desktop memory pressure.

The successful November 22 runs used Inkling Q4 at a 131072-token context, a 128-token microbatch, a 2048 MiB host prompt cache, and two slots sharing a KV pool. The local preset projects about 22.4 GiB for Q4 GPU-side use, while systemd reported 2.4–3.9 GiB cgroup peaks for the Q4 service. Those figures cover different allocations. A cgroup memory cap alone cannot enforce GPU headroom.

## Build a candidate

The patch targets llama.cpp commit `94f3af3d09e74a0fb35f703194318d3b4037714a`. Apply it to a separate checkout and use the same CMake backend flags as the deployment under test. From that checkout:

```bash
git apply --check /path/to/llama-server-min-available-memory.patch
git apply /path/to/llama-server-min-available-memory.patch
c++ -std=c++17 -Wall -Wextra -pedantic -I tools/server \
  /path/to/check-memory-admission.cpp -o /tmp/check-memory-admission
/tmp/check-memory-admission
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON
cmake --build build --target llama-server --parallel 2
```

## Set a model-specific budget

The optional `LLAMA_SERVER_MIN_AVAILABLE_MIB` environment variable requires a positive integer in MiB. Leave it unset to retain standard behavior. Choose a budget from the model's measured or projected accelerator allocation, its host allocations, and the reserve appropriate to the concurrent jobs. Measure again when changing quantization, context, microbatch, projector, prompt cache, or model count. For example, 30720 MiB is a starting budget for the Q4 setup above. It budgets about 22.4 GiB for the model projection, 2 GiB for the prompt cache, and the remaining 5.6 GiB for additional allocations and a desktop reserve.

On a test router, set the environment on the parent so each model child inherits it. A systemd user service can set it with a drop-in:

```ini
[Service]
Environment=LLAMA_SERVER_MIN_AVAILABLE_MIB=30720
```

The drop-in takes effect after `systemctl --user daemon-reload` and the next start of the patched service. Remove the drop-in and reload the user manager to disable it for future starts.

Each new inference worker compares the budget with `MemAvailable` from `/proc/meminfo` immediately before loading weights and context. A rejection logs the available and required MiB, and the router remains available for a later request. Explicit model loads and automatic loads both spawn checked workers. Listing models and keeping an already loaded instance running continue to use the router's normal behavior.

This is a point-in-time admission check. Jobs can grow after the check and the NVIDIA allocator can have tighter constraints than Linux's system-wide estimate. An already sleeping worker can reload internally without spawning, so `--sleep-idle-seconds` limits which loads can be checked. The guard is intended for a router managing child processes. A directly supervised single-model service should account for the ordinary load-failure exit code in its restart policy.

See the [kernel's `MemAvailable` documentation](https://docs.kernel.org/filesystems/proc.html) for how Linux estimates available physical RAM.
