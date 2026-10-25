#!/usr/bin/env python3
"""Flattens the screenshots that `xcresulttool export attachments` dumped into shots/<bundle>/
into shots/out/<bundle>-<name>.png, so one artifact holds the whole design-review set.

Usage: python3 Tools/export_shots.py [bundle ...]   (default: TestResults TestResultsDark)
"""
import glob
import json
import os
import shutil
import sys


def collect(node, found):
    """The manifest nests attachments differently between Xcode versions: walk everything."""
    if isinstance(node, dict):
        if "exportedFileName" in node and "suggestedHumanReadableName" in node:
            found.append(node)
        for value in node.values():
            collect(value, found)
    elif isinstance(node, list):
        for value in node:
            collect(value, found)


def main():
    bundles = sys.argv[1:] or ["TestResults", "TestResultsDark"]
    out = os.path.join("shots", "out")
    os.makedirs(out, exist_ok=True)

    exported = 0
    for bundle in bundles:
        folder = os.path.join("shots", bundle)
        manifest = os.path.join(folder, "manifest.json")
        if not os.path.isfile(manifest):
            print(f"{bundle}: no manifest.json (nothing exported)")
            continue
        with open(manifest, encoding="utf-8") as handle:
            data = json.load(handle)
        entries = []
        collect(data, entries)
        for entry in entries:
            source = os.path.join(folder, entry["exportedFileName"])
            if not os.path.isfile(source):
                continue
            name = str(entry["suggestedHumanReadableName"]).replace("/", "_")
            if not name.lower().endswith(".png"):
                name += ".png"
            shutil.copyfile(source, os.path.join(out, f"{bundle}-{name}"))
            exported += 1

    print(f"exported {exported} screenshot(s) to {out}")
    for path in sorted(glob.glob(os.path.join(out, "*.png"))):
        print(f"  {os.path.basename(path)}  {os.path.getsize(path)} bytes")
    if exported == 0:
        # Loud but not fatal: the upload step then reports "no files found".
        print("WARNING: no screenshots were exported")


if __name__ == "__main__":
    main()
