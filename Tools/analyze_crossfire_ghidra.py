#!/usr/bin/env python3
"""Static Crossfire 6502 analysis with the loader's byte-copy relocation.

Never executes the supplied code. Ghidra output and address images are ignored.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

SOURCE_SHA256 = "d1dca8251e6b3d3114e7eeac5aaa34c1d4ed9dc338fed02a8ef6aa6d48efe6c7"


def address_image(source: bytes) -> bytes:
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("Crossfire source identity mismatch")
    memory = bytearray(0x2000 + len(source))
    memory[0x2000:] = source
    # $2000 loader sets $3C/D=$2300, $3E/F=$2FFF, $42/43=$0300,
    # calls monitor MOVE ($FE2C) then jumps to $0800. Static byte copy only.
    memory[0x300:0x1000] = memory[0x2300:0x3000]
    return bytes(memory[0x300:])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--ghidra", required=True, type=Path)
    p.add_argument("--java", required=True, type=Path)
    p.add_argument("--entry", action="append", default=[])
    args = p.parse_args()
    if not (args.ghidra / "support/LaunchSupport.jar").is_file() or not (args.java / "bin/java").is_file():
        p.error("Use the actual Ghidra distribution root (for example ghidra_12.1.2_PUBLIC) and Java Contents/Home")
    root = Path(__file__).resolve().parent.parent
    out = root / "Library/Research/crossfire"
    projects = root / "Library/Research/ghidra-projects/crossfire"
    temporary = root / ".tools/crossfire-ghidra-tmp"
    home = root / ".tools/crossfire-ghidra-home"
    for path in (out, projects, temporary, home):
        path.mkdir(parents=True, exist_ok=True)
    target = out / "crossfire-address-image.bin"
    target.write_bytes(address_image((root / "Library/SourceMedia/retro/crossfire-apple-ii/program-01.bin").read_bytes()))
    isolated = [f"-Duser.home={home}", f"-Djava.io.tmpdir={temporary}"]
    support = [str(args.java / "bin/java"), *isolated, "-cp",
               str(args.ghidra / "support/LaunchSupport.jar"), "LaunchSupport", str(args.ghidra)]
    vmargs = subprocess.check_output([*support, "-vmargs"], text=True).splitlines()
    image_sha = hashlib.sha256(target.read_bytes()).hexdigest()
    entries = ["2000", "4000", "0400", "6a00", *args.entry]
    command = [str(args.java / "bin/java"), *vmargs, "-Xmx768M", "-XX:ParallelGCThreads=2",
               "-XX:CICompilerCount=2", "-Djava.awt.headless=true", *isolated,
               "-cp", str(args.ghidra / "Ghidra/Framework/Utility/lib/Utility.jar"),
               "ghidra.Ghidra", "ghidra.app.util.headless.AnalyzeHeadless", str(projects), "crossfire",
               "-import", str(target), "-overwrite", "-processor", "6502:LE:16:default",
               "-loader", "BinaryLoader", "-loader-baseAddr", "0x300", "-analysisTimeoutPerFile", "90",
               "-scriptPath", str(root / "Tools"), "-postScript", "ExportAsteroids.java",
               str(out), "sha256:" + image_sha, *entries]
    with (out / "ghidra.log").open("w") as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT)
    evidence = {"method": "Direct Ghidra static analysis; not REA Evidence", "target_execution": False,
                "source_sha256": SOURCE_SHA256, "address_image_sha256": image_sha,
                "relocation": {"source_start": 0x2300, "source_end": 0x2FFF, "destination": 0x300},
                "entry_points": entries, "exit_code": result.returncode,
                "command": command, "limitations": ["No Apple II execution or emulator.",
                    "The loader's final $0800 transfer appears to target sprite-like data; its execution path remains unresolved.",
                    "Indirect calls and self-modifying routines require manual static interpretation."]}
    (out / "provenance.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Crossfire static analysis exit {result.returncode}")
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
