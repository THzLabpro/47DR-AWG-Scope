#!/usr/bin/env python3
"""Compare a published HWH parameter dump with a Vivado BD dump."""

from __future__ import annotations

import argparse
import pathlib
import re


SECTION = re.compile(r"^\[([^]]+)\]$")
ASSIGNMENT = re.compile(r"^([^=#]+)=(.*)$")


def parse(path: pathlib.Path) -> dict[str, str]:
    section = ""
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        match = SECTION.match(line)
        if match:
            section = match.group(1)
            continue
        match = ASSIGNMENT.match(line)
        if match and section:
            name = match.group(1).strip()
            if section.startswith("clk_wiz") and name.startswith("C_"):
                name = name[2:]
            values[f"{section}.{name}"] = match.group(2).strip()
    return values


def expected(key: str) -> str | None:
    if re.search(r"\.DAC[0-3]_Sampling_Rate$", key):
        return "DAC 9.0 -> 9.8 GS/s (doc/01 §1)"
    if re.search(r"\.DAC[0-3]_Outclk_Freq$", key):
        return "DAC fabric derived clock 562.5 -> 612.5 MHz"
    if key.startswith("usp_rf_data_converter_0.DAC") and key.endswith("_Refclk_Freq"):
        return "DAC PLL/reference follows the 9.8 GS/s RFDC configuration"
    if key.startswith("clk_wiz_0.") and key.split(".", 1)[1] in {
        "PRIM_IN_FREQ", "CLKOUT1_REQUESTED_OUT_FREQ", "CLKOUT2_REQUESTED_OUT_FREQ", "CLKOUT2_USED"
    }:
        return "DAC fabric MMCM retuned to 612.5 MHz"
    if key.startswith("clk_wiz_adc.") and key.split(".", 1)[1] in {
        "PRIM_IN_FREQ", "CLKOUT1_REQUESTED_OUT_FREQ"
    }:
        return "ADC fabric MMCM set to 416.666667 MHz from 200 MHz"
    return None


def relevant(key: str) -> bool:
    if key.startswith("usp_rf_data_converter_0."):
        name = key.split(".", 1)[1]
        return bool(re.match(
            r"(?:ADC|DAC)[0-3]_(?:Sampling_Rate|Outclk_Freq|Multi_Tile_Sync|Clock_Source|Clock_Dist|PLL_Enable|Refclk_Freq)$",
            name,
        ))
    if key.startswith("clk_wiz_0."):
        return key.split(".", 1)[1] in {
            "PRIM_IN_FREQ", "CLKOUT1_REQUESTED_OUT_FREQ", "CLKOUT2_REQUESTED_OUT_FREQ", "CLKOUT2_USED"
        }
    if key.startswith("clk_wiz_adc."):
        return key.split(".", 1)[1] in {"PRIM_IN_FREQ", "CLKOUT1_REQUESTED_OUT_FREQ"}
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--published", required=True, type=pathlib.Path)
    parser.add_argument("--bd", required=True, type=pathlib.Path)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    args = parser.parse_args()

    old = parse(args.published)
    new = parse(args.bd)
    keys = sorted(key for key in set(old) | set(new) if relevant(key))
    lines = [
        "# D0 BD parameter diff",
        f"# published={args.published}",
        f"# v2={args.bd}",
        "# STATUS: PASS when every changed key is explicitly expected below.",
        "",
    ]
    unexpected = 0
    changed = 0
    for key in keys:
        before = old.get(key, "<missing>")
        after = new.get(key, "<missing>")
        if before == after:
            continue
        changed += 1
        reason = expected(key)
        tag = "EXPECTED" if reason else "UNEXPECTED"
        if reason is None:
            unexpected += 1
            reason = "not in the frozen D0 change set"
        lines.append(f"{tag} {key}: {before} -> {after} :: {reason}")
    lines.append("")
    lines.append(f"changed={changed}")
    lines.append(f"unexpected={unexpected}")
    lines.append("status=" + ("PASS" if unexpected == 0 else "FAIL"))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"BD_PARAM_DIFF {args.out}")
    print(f"BD_PARAM_CHANGED {changed}")
    print(f"BD_PARAM_UNEXPECTED {unexpected}")
    return 0 if unexpected == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
