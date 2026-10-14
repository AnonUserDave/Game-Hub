#!/usr/bin/env python3
"""Direct static Ghidra fallback when REA's Darwin xcrun helper is unavailable.

Uses Ghidra's public headless entry point and public script API. Output is
direct Ghidra evidence, not REA Evidence. Never executes the target binary.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from analyze_pga2005_rea import PROFILES


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghidra", required=True, type=Path)
    parser.add_argument("--java", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--procedure", action="append")
    parser.add_argument("--keep-project", action="store_true", help="Keep local ignored database for follow-up analysis")
    parser.add_argument("--resume-project", action="store_true", help="Reuse the exact local project without reimport or auto-analysis")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    ghidra, java = args.ghidra.resolve(), args.java.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    home, temporary = root / ".tools/ghidra-home", root / ".tools/ghidra-temp"
    projects = root / "Library/Research/ghidra-projects"
    for p in (home, temporary, projects):
        p.mkdir(parents=True, exist_ok=True)
    isolated = [f"-Duser.home={home}", f"-Djava.io.tmpdir={temporary}"]
    support = [str(java / "bin/java"), *isolated, "-cp",
               str(ghidra / "support/LaunchSupport.jar"), "LaunchSupport", str(ghidra)]
    vmargs = subprocess.check_output([*support, "-vmargs"], text=True).splitlines()
    addresses = args.procedure or PROFILES[args.profile]
    target_sha256 = hashlib.sha256(args.target.read_bytes()).hexdigest()
    project_name = "pga2005-" + args.profile
    if args.resume_project and not (projects / (project_name + ".gpr")).is_file():
        parser.error("No matching local Ghidra project to resume")
    target_arguments = (["-process", args.target.name, "-noanalysis"] if args.resume_project
                        else ["-import", str(args.target.resolve()), "-overwrite",
                              "-analysisTimeoutPerFile", "180"])
    command = [str(java / "bin/java"), *vmargs, "-Xmx2G", "-XX:ParallelGCThreads=2",
               "-XX:CICompilerCount=2", "-Djava.awt.headless=true", *isolated,
               "-cp", str(ghidra / "Ghidra/Framework/Utility/lib/Utility.jar"),
               "ghidra.Ghidra", "ghidra.app.util.headless.AnalyzeHeadless",
               str(projects), project_name, *target_arguments,
               "-scriptPath", str(root / "Tools"),
               "-postScript", "ExportGameFunctions.java", str(output), "sha256:" + target_sha256, *addresses]
    if not args.keep_project:
        command.append("-deleteProject")
    metadata = {"method": "direct Ghidra static analysis; no game execution",
                "rea_evidence": False, "target": str(args.target.resolve()),
                "sha256": target_sha256,
                "profile": args.profile, "addresses": addresses,
                "ghidra": str(ghidra), "command": command}
    (output / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n")
    with (output / "ghidra.log").open("w") as stream:
        completed = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT)
    metadata["exit_code"] = completed.returncode
    log = (output / "ghidra.log").read_text(errors="replace")
    metadata["auto_analysis_timed_out"] = "Analysis timed out" in log
    metadata["limitations"] = [
        "Static decompiler output is not original source or runtime behavior.",
        "External DLL implementations are not imported into this database.",
    ]
    if metadata["auto_analysis_timed_out"]:
        metadata["limitations"].append("Whole-program auto-analysis timed out; selected functions may still decompile successfully.")
    (output / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n")
    raise SystemExit(completed.returncode)


if __name__ == "__main__":
    main()
