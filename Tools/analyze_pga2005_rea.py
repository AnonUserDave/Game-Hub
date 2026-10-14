#!/usr/bin/env python3
"""Run bounded static PGA2005 analysis through an installed REA MCP server.

Uses public MCP JSON-RPC over stdio, keeps one Ghidra database per binary,
exports complete evidence locally, and never executes the game. Pass paths to
an existing REA launcher, Node, Ghidra, and JDK; no machine config is changed.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


PROFILES = {
    "course": [
        "0x100090a0",  # CourseDataManager::ReadHeaders
        "0x1000d180",  # MappedCourseC::ReadHeaders
        "0x1000d6b0",  # tagPatch::FixupOffsets
        "0x1000e110",  # TerrainVertexCompressed::GetTerrainVertex
        "0x1000e660",  # tagSurfaceStructureCompressed::GetSurfaceStructure
        "0x1000cd50",  # MappedDataManagerC::LoadMemObject
        "0x1000e260",  # TerrainVertexHelper::SizeOf
        "0x1000e270",  # TerrainVertexHelper::SizeOfCompressed
    ],
    "physics": [
        "0x101f5b7d",  # CBallFlight::Flying
        "0x101f6112",  # CBallFlight::RollingAndSlipping
        "0x101f6742",  # CBallFlight::PureRolling
        "0x101f4e6a",  # CBallFlight::Impact
        "0x101f795f",  # CBallFlight::BallLoop
        "0x101f8696",  # CBallFlight::BallLoopUpdatePos
        "0x101f758b",  # CBallFlight::StartBall
    ],
}


class Rea:
    def __init__(self, command: list[str], env: dict[str, str], stderr):
        self.process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=stderr,
                                        text=True, bufsize=1)
        self.sequence = 0
        self.request("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "gamehub-pga2005-static", "version": "1"},
        })
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        identifier = self.sequence
        self.send({"jsonrpc": "2.0", "id": identifier,
                   "method": method, "params": params})
        while line := self.process.stdout.readline():
            message = json.loads(line)
            if message.get("id") != identifier:
                continue
            if "error" in message:
                raise RuntimeError(message["error"])
            return message["result"]
        raise RuntimeError(f"REA exited with {self.process.poll()}")

    def call(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(result)
        structured = result.get("structuredContent")
        if structured is not None:
            return structured
        values = [json.loads(c["text"]) for c in result.get("content", [])
                  if c.get("type") == "text"]
        return values[0] if len(values) == 1 else values

    def shutdown(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node", required=True, type=Path)
    parser.add_argument("--rea-launcher", required=True, type=Path)
    parser.add_argument("--ghidra", required=True, type=Path)
    parser.add_argument("--java", required=True, type=Path, help="JDK Home directory")
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--procedure", action="append", help="Override profile with exact addresses")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.update(GHIDRA_INSTALL_DIR=str(args.ghidra.resolve()),
               JAVA_HOME=str(args.java.resolve()))
    server = None
    opened = False
    with (output / "rea-server.log").open("w") as errors:
        try:
            server = Rea([str(args.node.resolve()), str(args.rea_launcher.resolve()), "mcp"], env, errors)
            target = server.call("open_binary", {
                "path": str(args.target.resolve()), "provider_id": "ghidra"})
            opened = True
            (output / "target.json").write_text(json.dumps(target, indent=2) + "\n")
            print("Opened", args.target.name, flush=True)
            overview = server.call("binary_overview", {})
            (output / "overview.json").write_text(json.dumps(overview, indent=2) + "\n")
            print("Overview", overview.get("evidence_id"), flush=True)
            for address in args.procedure or PROFILES[args.profile]:
                result = server.call("analyze_function", {"procedure": address})
                (output / f"function-{address}.json").write_text(json.dumps(result, indent=2) + "\n")
                normalized = result.get("normalized_result", {})
                code = normalized.get("pseudocode", "")
                (output / f"function-{address}.c.txt").write_text(code + "\n")
                print(address, result.get("evidence_id"), "pseudocode bytes", len(code), flush=True)
            result = server.call("export_evidence_bundle", {"path": str(output / "evidence.json"), "overwrite": True})
            print("Exported", result, flush=True)
        finally:
            if server:
                if opened:
                    try:
                        server.call("export_evidence_bundle", {"path": str(output / "evidence.json"), "overwrite": True})
                        server.call("close_binary", {})
                    except Exception as error:
                        print("Cleanup warning:", error, file=sys.stderr)
                server.shutdown()


if __name__ == "__main__":
    main()
