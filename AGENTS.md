# Contributor instructions

Read `docs/M1_TARGET_CONSTRAINT.md` before changing runtime code, rendering, assets, dependencies, or defaults. The owner's M1 MacBook Air with 8 GB RAM and 2560 × 1600 display is the mandatory release target. The son's M5 MacBook Pro with 24 GB RAM is a development machine only. Its performance cannot establish acceptance or justify a higher baseline.

Read `docs/STATUS.md` and `docs/HANDOFF.md` before continuing. Preserve the distinction between generated practice gameplay, original asset viewing, and a completed faithful rewrite. Use native ARM64 implementations; no emulation, Wine, or Rosetta. The owner requested subagents where available.

Run checks appropriate to each change. Record which hardware was actually tested; M5 results never substitute for sustained M1 acceptance. Do not run work on the owner's laptop remotely or schedule background work without a new request.

Keep original media, extracted binaries/textures, analysis-engine installs, credentials, and local builds out of Git. The original ZIPs have already been AirDropped to the son's computer. Commit first-party source, tools, tests, manifests, and useful research records. Update status and handoff documentation with each meaningful checkpoint and push small reviewable commits.
