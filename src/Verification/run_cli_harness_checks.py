#!/usr/bin/env python3
"""Sanity checks for CLI harness detection paths (no XCTest)."""
from __future__ import annotations

import shutil
import sys
from pathlib import Path


def which(name: str) -> str | None:
    return shutil.which(name)


def main() -> int:
    failures = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        if ok:
            print(f"ok  {name}")
        else:
            failures.append(name)
            print(f"FAIL {name}" + (f": {detail}" if detail else ""))

    home = Path.home()
    tools = {
        "Claude Code": (which("claude"), home / ".claude/settings.json"),
        "Codex": (which("codex"), home / ".codex/config.toml"),
        "OpenCode": (which("opencode"), home / ".config/opencode/opencode.json"),
        "Gemini": (which("gemini"), home / ".gemini/settings.json"),
        "Kiro": (which("kiro-cli") or which("kiro"), home / ".kiro"),
    }
    found = 0
    for name, (binary, config) in tools.items():
        installed = binary is not None or config.exists()
        if installed:
            found += 1
            print(f"  detected {name}: binary={binary} config_exists={config.exists()}")
        check(f"{name} detect path defined", True)

    check("at least one harness detectable on this machine", found >= 1, f"found={found}")

    # Claude settings shape
    settings = home / ".claude/settings.json"
    if settings.exists():
        text = settings.read_text()
        check("claude settings is json-ish", text.strip().startswith("{"))

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print(f"\nall harness path checks passed ({found} tools present)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
