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
import re
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
        "fireMasks": table(0xf0fe, 2, "Team fire-input masks, also immediately preceding HUD low-nibble font"),
        "paddleBounds": table(0xf782, 6, "Full, left-half, right-half lower/upper paddle positions"),
        "serveSeeds": table(0xf788, 4, "ASL gives X position; carry selects horizontal sign"),
        "rowPoints": table(0xf78c, 6, "Top-to-bottom point values"),
        "rowAudioFrequency": table(0xf792, 6, "AUDF0 values by brick row"),
        "columnByteOffsets": table(0xf798, 18, "Six-row playfield byte offsets by brick column"),
        "columnRemovalMasks": table(0xf7be, 18, "AND masks clearing two playfield bits per brick"),
        "colorCodes": table(0xf7aa, 20, "Ten color codes followed by ten monochrome codes; slots BC through C5"),
        "paddleGraphics": table(0xf7d6, 3, "TIA player glyphs, fourfold pixels; 16/12/8 widths"),
        "paddleHalfWidths": table(0xf7d9, 3, "Paddle-center and rebound calculation half widths"),
        "packedVelocities": table(0xf7dc, 20, "Pairs: horizontal then vertical; integral low 2 bits and fractional high 6"),
        "variationFlags": table(0xf7f0, 12, "Steer 0x10, catch 0x08, invisible 0x40, timer 0x80, breakthrough 0x20"),
    }
    packed = tables["packedVelocities"]["bytes"]
    velocities = [[(value & 3) * 256 + (value & 0xfc) for value in packed[index:index + 2]] for index in range(0, 20, 2)]
    metadata = {
        "schemaVersion": 2, "title": "Breakout", "platform": "Atari 2600", "archive": archive.name,
        "archiveSHA256": ARCHIVE_SHA256, "archiveMember": MEMBER, "ROMBytes": len(rom), "ROMSHA256": ROM_SHA256,
        "analysisMethod": "Selected artifact byte/table decode and direct Ghidra 6502 static disassembly; no execution",
        "normalizedROMBase": "0xf000", "resetVector": "0xf237", "BRKVector": "0xf1c6",
        "tables": tables, "velocityPairs256": velocities,
        "derivedWallPoints": 18 * sum(tables["rowPoints"]["bytes"]),
        "limitations": ["Static analysis does not verify observed gameplay, audio, or display.",
                        "Native integer pixel contacts reproduce prior-frame update order; intra-scanline write edges remain unverified.",
                        "Selected timer modes bypass the scored second-wall branch; publisher instructions describe two walls. Original comparison is required.",
                        "No 864/wall-empty terminal branch appears in the fully covered static cartridge; gameplay continues to shared round exhaustion.",
                        "Original-reference comparison, physical controller checks, and sustained M1 acceptance remain absent."]
    }
    return rom, metadata


def decode_hud(rom):
    """Decode only this cartridge's two nibble-oriented digit tables.

    The display kernel walks rows Y=4..0. PF1 and PF2 have opposite bit
    orders, so both byte tables must yield the same logical three-pixel digit.
    Original glyph bytes stay solely in ignored prepared media.
    """
    digits = []
    for digit in range(10):
        low = rom[0x100 + digit * 5:0x105 + digit * 5][::-1]
        high = rom[0x200 + digit * 5:0x205 + digit * 5][::-1]
        rows = [value & 7 for value in low]
        for normal, reflected in zip(rows, high):
            bits = (reflected & 15) >> 1
            mirror = ((bits & 1) << 2) | (bits & 2) | ((bits & 4) >> 2)
            if normal != mirror:
                raise ValueError("Companion HUD glyph tables disagree after playfield bit ordering")
        digits.append(rows)
    return {"schemaVersion": 1, "sourceSHA256": ROM_SHA256, "digitRows": digits}


def verify_static_coverage(rom, listing):
    """Validate full byte coverage without interpreting source instructions.

    Listing lines are provider observations. Fixed data ranges are source table
    classifications established by their actual load sites and display kernel.
    All direct transfers, including compact BRK calls and +2 continuations, must
    select another verified instruction. RTS/RTI remain statically authored calls.
    """
    records, covered = {}, set()
    for line in listing.read_text().splitlines():
        match = re.fullmatch(r"([a-f0-9]{4}) ((?:[a-f0-9]{2} )+) +(.+)", line)
        if not match:
            continue
        address = int(match[1], 16)
        raw = bytes.fromhex(match[2])
        offset = address - 0xf000
        if offset < 0 or offset + len(raw) > len(rom) or raw != rom[offset:offset + len(raw)]:
            raise ValueError("Disassembly byte identity differs from the selected cartridge")
        byte_range = set(range(offset, offset + len(raw)))
        if byte_range & covered:
            raise ValueError("Disassembly contains overlapping instructions")
        covered.update(byte_range)
        records[address] = match[3]
    data_ranges = [(0xf0fe, 0xf132, "two input masks and ten five-row low-nibble digits"),
                   (0xf200, 0xf237, "ten companion digits and the blank five-row glyph"),
                   (0xf782, 0xf800, "game parameters and reset/BRK vectors")]
    padding = [0xf255, 0xf25a, 0xf59b, 0xf5a6, 0xf5f9]
    data = {offset for start, end, _ in data_ranges for offset in range(start - 0xf000, end - 0xf000)}
    data.update(address - 0xf000 for address in padding)
    if covered & data or covered | data != set(range(2048)):
        raise ValueError("Static coverage has unclassified or conflicting cartridge bytes")
    missing = []
    for address, text in records.items():
        direct = re.fullmatch(r"(?:JMP|JSR|BCC|BCS|BEQ|BNE|BMI|BPL|BVC|BVS) 0x([a-f0-9]+)", text)
        targets = [int(direct[1], 16)] if direct else []
        if text == "BRK":
            targets += [0xf1c6, address + 2]
            if address + 1 not in padding:
                raise ValueError("Unclassified BRK padding")
        missing.extend(target for target in targets if target not in records)
    if missing:
        raise ValueError(f"Uncovered direct control-flow targets: {missing}")
    def references(operand):
        return [{"address": f"0x{address:04x}", "instruction": text}
                for address, text in records.items() if re.search(rf"\b0x0*{operand}\b", text)]
    return {"listingSHA256": hashlib.sha256(listing.read_bytes()).hexdigest(),
            "instructionCount": len(records), "instructionByteCount": len(covered),
            "classifiedDataAndPaddingBytes": len(data), "unclassifiedBytes": 0,
            "uncoveredDirectTransferTargets": [],
            "dataRanges": [{"start": hex(start), "endExclusive": hex(end), "meaning": meaning}
                           for start, end, meaning in data_ranges],
            "BRKPaddingAddresses": [hex(address) for address in padding],
            "wallTransitionReferences": references("de"), "activeGameReferences": references("b4"),
            "sharedRoundReferences": references("b9"),
            "boundary": "Complete byte classification and direct transfer targets are static evidence, not observed original execution or hardware timing."}


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
    if args.ghidra:
        ghidra_analysis(root, rom_path, output, args.ghidra.resolve(), args.java.resolve())
    listing = output / "disassembly.txt"
    if listing.is_file():
        metadata["staticCoverage"] = verify_static_coverage(rom, listing)
    prepared = root / "Library/Imported/breakout2600"
    prepared.mkdir(parents=True, exist_ok=True)
    hud = decode_hud(rom)
    (prepared / "media.json").write_text(json.dumps(hud, indent=2) + "\n")
    metadata["HUD"] = {"lowTableAddress": "0xf100", "companionTableAddress": "0xf200",
                       "digitCount": 10, "rowsPerDigit": 5, "logicalDigitWidth": 3,
                       "rowOrder": "Y=4..0", "companionBitOrderAgreement": True,
                       "preparedPath": "Library/Imported/breakout2600/media.json",
                       "originalGlyphsCommitted": False}
    (output / "tables.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Verified {len(rom)} source bytes ({ROM_SHA256}); {metadata['derivedWallPoints']} points/wall; static preparation only")


if __name__ == "__main__":
    main()
