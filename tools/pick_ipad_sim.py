#!/usr/bin/env python3
"""Print `<runtime-id> <devicetype-id> <name>` for a modern iPad Pro 12.9"/13"
simulator compatible with the newest available iOS runtime.

Picking a device type by name alone can match the ancient "iPad Pro (12.9-inch)"
that can't run iOS 26 ("Incompatible device"). Selecting from the chosen
runtime's own supportedDeviceTypes guarantees the pairing boots.
"""
import json
import subprocess
import sys


def main() -> int:
    rts = json.loads(
        subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"])
    )["runtimes"]
    ios = [r for r in rts if r.get("platform") == "iOS" and r.get("isAvailable")]
    if not ios:
        sys.exit("no available iOS runtime")
    r = sorted(ios, key=lambda x: x.get("version", ""))[-1]
    cands = [
        d
        for d in r.get("supportedDeviceTypes", [])
        if "iPad Pro" in d["name"] and ("13-inch" in d["name"] or "12.9" in d["name"])
    ]
    if not cands:
        sys.exit("no compatible iPad Pro 12.9/13 device type for " + r["identifier"])
    d = cands[-1]
    print(r["identifier"], d["identifier"], d["name"].replace(" ", "_"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
