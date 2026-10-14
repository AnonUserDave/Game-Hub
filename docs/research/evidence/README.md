# Checkpoint research metadata

These curated reports preserve source hashes, archive inventories, binary/export addresses, REA evidence identifiers, numeric physics observations, mesh-layout checks and independent texture-decoder comparisons. They are copied from local `Library/Research` at the 2026-10-13 handoff. They are static research records, not proof of complete runtime parity.

Original media, extracted executable binaries/textures, large disassembly/decompiler output and Ghidra databases remain ignored. Reproduce deeper analysis with the versioned `Tools/analyze_pga2005_*.py`, `ExportGameFunctions.java`, decoder scripts and the user's AirDropped source ZIPs; see [the REA ledger](../PGA2005-REA.md) for exact functions, source identities, setup and limitations.

Absolute paths in these historical reports describe the original laptop. Resolve equivalent files in the new clone; do not assume Alex's home directory exists on the son's machine. No authentication state or portable tool installations belong here.

`pga2005-patch-layers-surfaces.json` (2026-10-13, son's M5) adds the per-hole
patch-layer predicate, course-condition masks, surface flag bits, lie-record
selection and coefficient uses recovered by direct Ghidra 12.1.2 and LLVM
objdump analysis. It holds addresses, short constants and SHA-256 identities
only. It is not REA Evidence; see the ledger section of the same date.
