#!/usr/bin/env python3
"""Prepare original course assets for the native lab from locally supplied media.

One command, standard Python only, no Windows installer/game execution. Source
and converted data remain in the Git-ignored local library.
"""
import argparse
import json
from pathlib import Path

from inspect_pga2005 import ISO9660, extract_media
from import_pga2005 import atomic_write, run_import
from import_pga2005_hud import convert as convert_hud
import import_pga2005_audio
import decode_pga2005_cameras
import decode_pga2005_objects
from installshield_cab import Cabinet

# Install-cabinet groups the native module reads (HUD art, sky, ball and tee
# meshes, generic course objects, sounds, golfer, render/camera settings,
# shaders). Extracted from the install/media ISOs in place, no installer run.
INSTALL_GROUPS = ["DataImages", "CoursesRoot", "Data-Golfball", "Courses - Generic", "Sounds - Basic",
                  "Sounds - Gallery", "Sounds - Interface", "Golfer", "Executable", "Data - Shaders"]


def prepare_install(media_dir: Path) -> Path:
    install = media_dir / "install"
    isos = [media_dir / "EA-TigerWoodsPGATour2005-CD1-Install.iso", media_dir / "EA-TigerWoodsPGATour2005-CD2-MediaDisc.iso"]
    with Cabinet.from_isos(isos) as cabinet:
        written = cabinet.extract_all(install, groups=INSTALL_GROUPS, layout="unshield")
    print(f"Install cabinets: {len(written)} files in {len(INSTALL_GROUPS)} groups")
    return install
from decode_pga2005_terrain import decode
from decode_pga2005_library import decode_materials
from decode_pga2005_holes import decode_holes
import decode_pga2005_golfer


def save_json(path, value):
    atomic_write(path, (json.dumps(value, indent=2) + "\n").encode())


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=root / "Tiger_Woods_PGA_Tour_2005_Win_ISO_EN.zip")
    parser.add_argument("--courses", nargs="+", choices=["AUS", "EDW", "FAN", "HAR", "JPN", "MON", "PBL", "SAW", "SHR", "STA", "TUR"], default=["AUS", "EDW", "FAN", "HAR", "JPN", "MON", "PBL", "SAW", "SHR", "STA", "TUR"])
    args = parser.parse_args()
    media_dir = root / "Library/SourceMedia/pga2005"
    media = media_dir / "EA-TigerWoodsPGATour2005-CD3-CoursesDisc.B6I"
    needed = [media, media_dir / "EA-TigerWoodsPGATour2005-CD1-Install.iso", media_dir / "EA-TigerWoodsPGATour2005-CD2-MediaDisc.iso"]
    if not all(path.exists() for path in needed):
        extract_media(args.archive, media_dir)
    iso = ISO9660(media)
    source_dir = media_dir / "disc3"
    try:
        wanted = {f"COURSES/{code}/{code}.{extension}" for code in args.courses for extension in ("TCR", "TCL", "INI")}
        found = set()
        for entry in iso.files():
            if entry["path"] in wanted:
                iso.inspect_file(entry, include_hash=True)
                iso.extract(entry, source_dir)
                found.add(entry["path"])
        if found != wanted:
            raise ValueError(f"Missing original course files: {sorted(wanted - found)}")
    finally:
        iso.close()
    images = run_import(media, root / "Library/Imported/pga2005")
    print(f"Imported {len(images['images'])} disc images and {len(images['courses'])} course INIs.")
    install = prepare_install(media_dir)
    hud = convert_hud(install / "DataImages/Game", root / "Library/Imported/pga2005/hud")
    print(f"HUD: {len(hud['images'])} original images")
    for code in args.courses:
        source = source_dir / "COURSES" / code
        output = root / "Library/Imported/pga2005" / code
        tcr = (source / f"{code}.TCR").read_bytes()
        terrain, report = decode(tcr)
        atomic_write(output / "terrain.ghpc", terrain)
        save_json(output / "terrain-report.json", report)
        used = {int(i) for i in report["material_triangle_counts"]}
        materials = decode_materials(tcr, [(source / f"{code}.TCL").read_bytes()], output, used)
        save_json(output / "materials.json", materials)
        holes = decode_holes(tcr, (source / f"{code}.INI").read_bytes())
        save_json(output / "holes.json", holes)
        print(f"{code}: {report['point_count']:,} vertices, {report['triangle_count']:,} triangles, {len(materials['materials'])} original materials, {holes['hole_count']} holes")
    # Original trees, tree meshes, panoramas and sky domes, validated against
    # the terrain and materials above (about 12 s per course on the M5).
    for code in args.courses:
        objects = decode_pga2005_objects.prepare_course(root, code)["summary"]
        print(f"{code}: {objects['instances']:,} original trees of {objects['object_types']} types")
    sky = decode_pga2005_objects.prepare_sky(root, "PBL" if "PBL" in args.courses else args.courses[0])
    print(f"Sky: {sky['domes']} original domes")
    # Original sounds and per-course ambience (needs the course materials above).
    if import_pga2005_audio.main(["--courses", *args.courses]) != 0:
        raise SystemExit("Audio import failed")
    # Original golfer (Tiger Woods 01char), his clubs and swing clips.
    golfer = decode_pga2005_golfer.run(install, root / "Library/Imported/pga2005/golfer", "01",
                                       list(decode_pga2005_golfer.DEFAULT_CLIPS), None, False)
    print(f"Golfer: {golfer['mesh']['vertices']} vertices, {golfer['clubs']['triangles']} club triangles, "
          f"{len(golfer['clips'])} clips")
    # The native director needs these prepared scripts on a fresh install.
    cameras = decode_pga2005_cameras.run(media_dir, root / "Library/Imported/pga2005")
    if cameras["missing"]:
        raise ValueError(f"Missing original camera scripts: {cameras['missing']}")
    print(f"Cameras: {cameras['scripts']} original scripts")


if __name__ == "__main__":
    main()
