#!/usr/bin/env python3
"""Static 6502 analysis of hash-verified Asteroids editions; never runs their code.

Requires an existing Ghidra and Java installation. Original media, full listings,
decompiler output and databases remain under ignored local directories.
"""
import argparse
import json
from pathlib import Path
import subprocess

from prepare_asteroids import prepare, sha256


PROFILES = {
    # 2600 mirrors resolve these addresses to the same $1000-$1FFF cartridge window.
    # Separate projects prevent mistaken cross-bank flow; banking is not emulated.
    "2600-bank0": (0xD000, (0xD000, 0xD43C, 0xD591, 0xDB00)),
    "2600-bank1": (0xF000, (0xF000, 0xF9DA)),
    "7800-code": (0xC000, (0xD000, 0xD2FC)),
    # The XEX RUN vector reaches $5500. $5617 is the explicitly installed OS callback.
    "8bit-code": (0x5500, (0x5500, 0x5504, 0x5600, 0x5617)),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghidra", required=True, type=Path, help="Ghidra distribution root containing Ghidra/ and support/")
    parser.add_argument("--java", required=True, type=Path, help="Java home containing bin/java")
    parser.add_argument("--profile", choices=PROFILES, action="append", help="Omit to analyze every edition/bank sequentially")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    root, ghidra, java = args.root.resolve(), args.ghidra.resolve(), args.java.resolve()
    prepare(root)  # All archive and selected payload hashes are validated first.
    if not (ghidra / "support/LaunchSupport.jar").is_file() or not (java / "bin/java").is_file():
        parser.error("Ghidra or Java installation does not match the requested root")
    home, temp = root / ".tools/asteroids-ghidra-home", root / ".tools/asteroids-ghidra-tmp"
    projects = root / "Library/Research/ghidra-projects/asteroids"
    for path in (home, temp, projects):
        path.mkdir(parents=True, exist_ok=True)
    isolated = [f"-Duser.home={home}", f"-Djava.io.tmpdir={temp}"]
    support = [str(java / "bin/java"), *isolated, "-cp", str(ghidra / "support/LaunchSupport.jar"),
               "LaunchSupport", str(ghidra)]
    vmargs = subprocess.check_output([*support, "-vmargs"], text=True).splitlines()
    for profile in args.profile or PROFILES:
        base, entries = PROFILES[profile]
        target = root / "Library/SourceMedia/asteroids" / (profile + ".bin")
        out = root / "Library/Research/asteroids" / profile
        out.mkdir(parents=True, exist_ok=True)
        digest = sha256(target.read_bytes())
        command = [str(java / "bin/java"), *vmargs, "-Xmx768M", "-XX:ParallelGCThreads=2",
                   "-XX:CICompilerCount=2", "-Djava.awt.headless=true", *isolated,
                   "-cp", str(ghidra / "Ghidra/Framework/Utility/lib/Utility.jar"), "ghidra.Ghidra",
                   "ghidra.app.util.headless.AnalyzeHeadless", str(projects), profile,
                   "-import", str(target), "-overwrite", "-processor", "6502:LE:16:default",
                   "-loader", "BinaryLoader", "-loader-baseAddr", hex(base),
                   "-analysisTimeoutPerFile", "90", "-scriptPath", str(root / "Tools"),
                   "-postScript", "ExportAsteroids.java", str(out), "sha256:" + digest,
                   *[f"{address:x}" for address in entries]]
        metadata = {"profile": profile, "base_address": base, "entry_points": entries,
                    "raw_analysis_input_sha256": digest, "target_execution": False,
                    "method": "direct Ghidra static analysis, not REA Evidence",
                    "command": command,
                    "limitations": ["Static analysis is not original-game observation.",
                                    "Separate 2600 banks do not resolve cross-bank control flow.",
                                    "No OS, console firmware, video, sound, input or RNG hardware is executed.",
                                    "Function discovery is partial, including indirect calls and interrupts."]}
        with (out / "ghidra.log").open("w") as stream:
            completed = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT)
        metadata["exit_code"] = completed.returncode
        metadata["auto_analysis_timed_out"] = "Analysis timed out" in (out / "ghidra.log").read_text(errors="replace")
        (out / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n")
        print(f"{profile}: exit {completed.returncode}", flush=True)
        if completed.returncode:
            raise SystemExit(completed.returncode)


if __name__ == "__main__":
    main()
