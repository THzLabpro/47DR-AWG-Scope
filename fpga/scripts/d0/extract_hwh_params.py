#!/usr/bin/env python3
"""Extract an XSA and publish every IP parameter in its HWH handoff."""

from __future__ import annotations

import argparse
import pathlib
import zipfile
import xml.etree.ElementTree as ET


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xsa", required=True, type=pathlib.Path)
    parser.add_argument("--extract-dir", required=True, type=pathlib.Path)
    parser.add_argument("--report", required=True, type=pathlib.Path)
    args = parser.parse_args()

    args.extract_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.xsa) as archive:
        archive.extractall(args.extract_dir)

    hwh_files = sorted(args.extract_dir.rglob("*.hwh"))
    if not hwh_files:
        raise SystemExit(f"No .hwh file found under {args.extract_dir}")
    hwh = hwh_files[0]
    root = ET.parse(hwh).getroot()
    system_info = root.find("SYSTEMINFO")
    modules = root.find("MODULES")
    if modules is None:
        raise SystemExit(f"HWH has no MODULES section: {hwh}")

    lines: list[str] = []
    lines.append("# D0 published BD parameters")
    lines.append(f"# source_xsa={args.xsa.resolve()}")
    lines.append(f"# source_hwh={hwh.resolve()}")
    if system_info is not None:
        lines.append(
            "# part="
            + system_info.attrib.get("DEVICE", "?")
            + "-"
            + system_info.attrib.get("PACKAGE", "?")
            + system_info.attrib.get("SPEEDGRADE", "?")
        )
    lines.append(f"# module_count={len(list(modules))}")
    lines.append("")

    for module in sorted(modules, key=lambda node: node.attrib.get("INSTANCE", "")):
        instance = module.attrib.get("INSTANCE", "")
        lines.append(f"[{instance}]")
        lines.append(f"VLNV={module.attrib.get('VLNV', '')}")
        params = module.find("PARAMETERS")
        if params is not None:
            for param in sorted(params, key=lambda node: node.attrib.get("NAME", "")):
                name = param.attrib.get("NAME", "")
                value = param.attrib.get("VALUE", "")
                lines.append(f"{name}={value}")
        lines.append("")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"EXTRACTED_XSA {args.xsa}")
    print(f"HWH {hwh}")
    print(f"PUBLISHED_PARAMS {args.report}")
    print(f"MODULES {len(list(modules))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
