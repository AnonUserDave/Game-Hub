#!/usr/bin/env python3
"""Hash-fenced, static preparation of the owner's selected Breakout cartridge.

Copies original bytes only to ignored Library/SourceMedia. Table evidence and
Ghidra databases remain in ignored Library/Research unless --evidence explicitly
selects a first-party metadata record. No cartridge instructions are executed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

ARCHIVE_SHA256 = "15e02de8fcb47c31e3aa4081e921796027726ffdb038c0bce7e02f537869e7b2"
ROM_SHA256 = "376323f051c3c373c887fd83abead39d87d844ff283d435f4addbfc1710c6fd5"
MEMBER = "Breakout_Atari-2600_ROM_EN/Game Files/Breakout.bin"


def inspect_archive(archive):
    raw = archive.read_bytes()
    if hashlib.sha256(raw).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("Archive identity differs from the selected inventory revision")
    with zipfile.ZipFile(archive) as source:
        rom = source.read(MEMBER)
    if len(rom) != 2048 or hashlib.sha256(rom).hexdigest() != ROM_SHA256:
        raise ValueError("ROM identity differs from the selected 2048-byte revision")

    def table(address, length, meaning):
        offset = address - 0xf000
        return {"address": f"0x{address:04x}", "fileOffset": offset, "byteCount": length,
                "bytes": list(rom[offset:offset + length]), "meaning": meaning}

    tables = {
        "paddleBounds": table(0xf782, 6, "Full, left-half, right-half lower/upper paddle positions"),
        "serveSeeds": table(0xf788, 4, "ASL gives X position; carry selects horizontal sign"),
        "rowPoints": table(0xf78c, 6, "Top-to-bottom point values"),
        "rowAudioFrequency": table(0xf792, 6, "AUDF0 values by brick row"),
        "columnByteOffsets": table(0xf798, 18, "Six-row playfield byte offsets by brick column"),
        "columnRemovalMasks": table(0xf7be, 18, "AND masks clearing two playfield bits per brick"),
        "paddleGraphics": table(0xf7d6, 3, "TIA player glyphs, fourfold pixels; 16/12/8 widths"),
        "paddleHalfWidths": table(0xf7d9, 3, "Paddle-center and rebound calculation half widths"),
        "packedVelocities": table(0xf7dc, 20, "Pairs: horizontal then vertical; integral low 2 bits and fractional high 6"),
        "variationFlags": table(0xf7f0, 12, "Steer 0x10, catch 0x08, invisible 0x40, timer 0x80, breakthrough 0x20"),
    }
    packed = tables["packedVelocities"]["bytes"]
    velocities = [[(value & 3) * 256 + (value & 0xfc) for value in packed[index:index + 2]] for index in range(0, 20, 2)]
    metadata = {
        "schemaVersion": 1, "title": "Breakout", "platform": "Atari 2600", "archive": archive.name,
        "archiveSHA256": ARCHIVE_SHA256, "archiveMember": MEMBER, "ROMBytes": len(rom), "ROMSHA256": ROM_SHA256,
        "analysisMethod": "Selected artifact byte/table decode and direct Ghidra 6502 static disassembly; no execution",
        "normalizedROMBase": "0xf000", "resetVector": "0xf237", "BRKVector": "0xf1c6",
        "tables": tables, "velocityPairs256": velocities,
        "derivedWallPoints": 18 * sum(tables["rowPoints"]["bytes"]),
        "limitations": ["Static analysis does not verify observed gameplay, audio, or display.",
                        "Native rectangle collisions replace TIA prior-frame collision latches.",
                        "Original-reference comparison, physical controller checks, and sustained M1 acceptance remain absent."]
    }
    return rom, metadata


def ghidra_analysis(root, rom_path, output, ghidra, java):
    # Use a private project/home so this title does not mutate REA's active target.
    home = output / "home"
    home.mkdir(parents=True, exist_ok=True)
    launch_support = [str(java), "-cp", str(ghidra / "support/LaunchSupport.jar"), "LaunchSupport", str(ghidra)]
    vmargs = subprocess.check_output([*launch_support, "-vmargs"], text=True).splitlines()
    command = [str(java), *vmargs, "-Xmx1G", f"-Duser.home={home}", "-Djava.awt.headless=true",
               "-cp", str(ghidra / "Ghidra/Framework/Utility/lib/Utility.jar"), "ghidra.Ghidra",
               "ghidra.app.util.headless.AnalyzeHeadless", str(output), "breakout", "-import", str(rom_path),
               "-overwrite", "-loader", "BinaryLoader", "-loader-baseAddr", "f000", "-processor", "6502:LE:16:default",
               "-noanalysis", "-scriptPath", str(root / "Tools"), "-postScript", "ExportBreakout.java", str(output / "disassembly.txt")]
    with (output / "ghidra.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).check_returncode()
    (output / "provenance.json").write_text(json.dumps({"targetSHA256": ROM_SHA256, "command": command,
        "provider": "direct Ghidra static 6502 disassembly", "targetExecution": False}, indent=2) + "\n")


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=root / "Breakout_Atari-2600_ROM_EN.zip")
    parser.add_argument("--evidence", type=Path, help="Optional first-party table/provenance metadata JSON")
    parser.add_argument("--ghidra", type=Path, help="Existing Ghidra directory containing support/LaunchSupport.jar")
    parser.add_argument("--java", type=Path, help="Existing native java executable, required with --ghidra")
    args = parser.parse_args()
    if bool(args.ghidra) != bool(args.java):
        parser.error("--ghidra and --java must be supplied together")
    rom, metadata = inspect_archive(args.archive)
    media = root / "Library/SourceMedia/breakout2600"
    output = root / "Library/Research/breakout2600"
    media.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    rom_path = media / "Breakout.bin"
    rom_path.write_bytes(rom)
    (output / "tables.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(metadata, indent=2) + "\n")
    if args.ghidra:
        ghidra_analysis(root, rom_path, output, args.ghidra.resolve(), args.java.resolve())
    print(f"Verified {len(rom)} source bytes ({ROM_SHA256}); {metadata['derivedWallPoints']} points/wall; static preparation only")


if __name__ == "__main__":
    main()
