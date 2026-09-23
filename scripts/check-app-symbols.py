#!/usr/bin/env python3
"""Fail if a bundled binary needs a Swift symbol from another bundled framework that does not export it.

This is the exact shape of the 1.0 (8) App Store rejection: ExpoFont referenced
_$s15ExpoModulesCore9AnyModulePAAE18_exposedDefinition..., ExpoModulesCore did not
export it, and dyld aborted before any app code ran ("Symbol missing", guideline 2.1(a)).

usage: check-app-symbols.py <path to .app>
"""
import re
import subprocess
import sys
from pathlib import Path

# Swift mangling: $s<len><ModuleName>... , e.g. $s15ExpoModulesCore9AnyModule...
SWIFT_MODULE = re.compile(r"\$s(\d+)([A-Za-z0-9_]+)")


def macho_binaries(app: Path):
    yield from ((app / app.stem), *(fw / fw.stem for fw in sorted((app / "Frameworks").glob("*.framework"))))


def symbols(binary: Path, flag: str):
    out = subprocess.run(["nm", flag, str(binary)], capture_output=True, text=True).stdout
    return {line.split()[-1] for line in out.splitlines() if line.strip()}


def module_of(symbol: str):
    m = SWIFT_MODULE.search(symbol)
    if not m:
        return None
    length, rest = int(m.group(1)), m.group(2)
    return rest[:length] if len(rest) >= length else None


def main(app_path: str) -> int:
    app = Path(app_path)
    binaries = [b for b in macho_binaries(app) if b.exists()]
    if not binaries:
        print(f"no Mach-O binaries found in {app}")
        return 2
    exported, needed = {}, {}
    for b in binaries:
        exported[b.parent.name.removesuffix(".framework") if b.parent.name.endswith(".framework") else b.name] = symbols(b, "-gU")
        needed[b.name] = symbols(b, "-u")

    problems = []
    for consumer, undefined in needed.items():
        for sym in undefined:
            module = module_of(sym)
            if module and module in exported and sym not in exported[module]:
                problems.append((consumer, module, sym))

    print(f"checked {len(binaries)} binaries in {app.name}")
    if problems:
        print(f"MISSING SYMBOLS: {len(problems)}")
        for consumer, module, sym in problems[:20]:
            print(f"  {consumer} needs {sym}\n    expected in {module}, not exported (dyld would abort at launch)")
        return 1
    print("every cross-framework Swift symbol resolves")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
