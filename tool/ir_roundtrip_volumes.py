#!/usr/bin/env python3
"""How far does CADSketch diverge from the featuretree IR?

`flutter test test/featuretree_import_test.dart` imports featuretree's sample IR
files and exports each one again (to $CADSKETCH_IR_OUT, default
/tmp/cadsketch_ir_roundtrip). This builds three solids per file with
featuretree's reference backend (build123d) and compares their volumes:

  source      the IR as featuretree wrote it
  expected    the source minus the features CADSketch said it skipped
  roundtrip   what CADSketch exported after importing it

expected == roundtrip means everything CADSketch took in came back out intact;
source - expected is the price of the features it can't show.

  python3 tool/ir_roundtrip_volumes.py [path/to/featuretree] [roundtrip dir]
"""
import json
import os
import sys
import tempfile
from pathlib import Path

ft = Path(sys.argv[1] if len(sys.argv) > 1 else "../featuretree").resolve()
out = Path(sys.argv[2] if len(sys.argv) > 2 else
           os.environ.get("CADSKETCH_IR_OUT", Path(tempfile.gettempdir()) / "cadsketch_ir_roundtrip"))
sys.path.insert(0, str(ft))
import b3d_emit  # noqa: E402

fixtures = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "featuretree"
report = json.loads((out / "report.json").read_text())


def volume(spec):
    return b3d_emit.emit(spec)[1]["volume"]


worst = 0.0
print(f"{'part':16} {'source':>12} {'expected':>12} {'roundtrip':>12}  {'in':>5} {'skipped':>7}  drift")
for name, r in report.items():
    source = json.loads((fixtures / f"{name}.ir.json").read_text())
    back = json.loads((out / f"{name}.roundtrip.ir.json").read_text())
    skipped = {s.split(" (")[0] for s in r["skipped"]}
    kept = dict(source, features=[f for f in source["features"] if f["name"] not in skipped])
    vs, ve, vb = volume(source), volume(kept), volume(back)
    drift = abs(vb - ve) / ve
    worst = max(worst, drift)
    print(f"{name:16} {vs:12.1f} {ve:12.1f} {vb:12.1f}  {r['imported']:5d} {len(r['skipped']):7d}  {drift:.2e}")
    for s in r["skipped"]:
        print(f"    skipped  {s}")
    for s in r["notes"]:
        print(f"    note     {s}")
sys.exit(1 if worst > 1e-4 else 0)
