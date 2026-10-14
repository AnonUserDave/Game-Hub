# Mandatory hardware target: M1 MacBook Air

Owner's explicit requirement, recorded 2026-10-13: the son develops on an **M5 MacBook Pro with 24 GB RAM**, but all delivered games and the hub must be designed and optimized for the owner's **M1 MacBook Air with 8 GB unified memory**, macOS 15.6, and **2560 × 1600** display. This is a hard project constraint. Only the owner can authorize changing it.

## Required runtime baseline

- Ship native ARM64 code. No emulators, Wine, Rosetta, or compatibility runtimes.
- Support the original M1 GPU and CPU. Check optional GPU/API capabilities and provide an M1-compatible path. Do not require features available only on newer Apple Silicon.
- Fullscreen golf must render to actual **2560 × 1600 Metal attachments**, independently of macOS desktop scaling. Preserve the original visual style while improving fidelity. A hidden reduction in rendering resolution does not satisfy this requirement.
- Set shipping graphics, asset loading, concurrency and cache defaults for **8 GB shared system/GPU memory** and a **fanless** laptop. Do not size them from the developer's available 24 GB or faster GPU.
- Keep keyboard/trackpad fully usable. Preserve native support for the owner's wired BDA/PowerA XB1 Fusion Pro, USB `24c6:591a`, including input transitions, focus and reconnect behavior. Other models require their own evidence.
- Keep the hub responsive while games load, run and return. Future modules must meet the same baseline.

The current deployment minimum is macOS 14. The actual owner's validation environment is macOS 15.6. Raising either hardware or OS requirements requires the owner's explicit approval.

## Performance and memory acceptance

Target a sustained **60 FPS / 16.67 ms frame budget** at the required fullscreen resolution on the M1. Profile long enough to expose the Air's thermal limits: at least a 30-minute representative gameplay session, including loading, dense scenes, input, hole changes and return to the hub. Record average FPS, frame-time p95/p99, peak physical memory footprint, memory pressure/swap, load times and thermal behavior. State power mode, whether plugged in, render settings, app commit and source-media hashes.

Use **3 GB peak app physical footprint** as an initial engineering budget, leaving room for macOS and other applications on an 8 GB machine. This is a provisional budget to validate with measurements, not an achieved result. Avoid memory-pressure warnings and continuing swap growth. Bound decoded texture/mesh caches, reuse original course geometry across holes, release inactive modules, and keep heavy reverse-engineering jobs out of the shipped runtime.

Optimize batching, culling, resource reuse, streaming, mipmaps and appropriately chosen detail before adding costly effects. Benchmark quality changes on the M1. If faithful content cannot meet the target, document measured costs and proposed tradeoffs for the owner; do not silently lower resolution or raise the baseline.

## What the M5 can establish

The M5 may accelerate compilation, tests and offline analysis. It may perform functional smoke tests and locate regressions. Its smooth frame rates, larger caches or low memory pressure do **not** prove acceptable M1 performance. Use explicit baseline settings and bounded allocations even during M5 development. Simulation determinism and gameplay timing must not depend on processor speed.

Mark changes awaiting access to the original machine as **M1 performance unverified**. Do not label a title optimized, verified or release-ready from M5 measurements alone. Arrange M1 acceptance only when the owner makes the laptop available again; no background monitoring or remote work on it is authorized by this handoff.

## Current evidence and limits

The existing development build was compiled as native ARM64 on the M1. Native UI checks confirmed actual 2560 × 1600 fullscreen attachments with 4× MSAA in generated practice and Original Course Lab. Observed snapshots reached approximately 55–60 FPS. These are **not sustained benchmarks**. The 30-minute acceptance run, memory budget and full original-course gameplay performance remain unverified.

Son's M5 development checks (2026-10-13, not M1 evidence): the original Pebble Beach module loads in a few seconds and shows 59–60 FPS windowed at a 2720 × 1782 Metal target with 4× MSAA. Footprint is 563 MB with a course loaded and 776 MB with the Lab open; about 330 MB of that is GPU memory, mostly MSAA targets. Returning to the hub releases the session (0 leaks). The golf views now render through an sRGB attachment, which changes their brightness on every Mac; confirm it visually on the M1. Each hole draws only its own 30–68k original triangles, but frame time, memory pressure and thermals on the M1 remain **unmeasured** for this module.

The generated practice module is provisional. Original Pebble Beach 18-hole development gameplay now exists with approximate physics; original physics, characters, modes and the other game rewrites remain unfinished. See [QA](QA.md), [status](STATUS.md) and [handoff](HANDOFF.md).
