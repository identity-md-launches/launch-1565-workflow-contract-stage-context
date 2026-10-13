#!/usr/bin/env python3
"""Export/check ABI arrays from the pinned Foundry build; Python standard library only."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ("LaunchToken", "SwarmlerActivity", "Swarmlers", "SwarmlerHookDeployer", "SwarmlerFeeHook")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if a committed ABI differs from the build")
    args = parser.parse_args()
    for name in CONTRACTS:
        artifact = ROOT / "out" / (name + ".sol") / (name + ".json")
        if not artifact.exists():
            raise SystemExit("Missing build artifact; run forge build first: " + str(artifact))
        data = json.loads(artifact.read_text())
        for field in ("bytecode", "deployedBytecode"):
            if data[field].get("linkReferences"):
                raise SystemExit(name + " contains unresolved library references")
        text = json.dumps(data["abi"], indent=2) + "\n"
        target = ROOT / "docs" / "abi" / (name + ".json")
        if args.check:
            if not target.exists() or target.read_text() != text:
                raise SystemExit("ABI differs: " + str(target))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        print(("Checked " if args.check else "Exported ") + name)


if __name__ == "__main__":
    main()
