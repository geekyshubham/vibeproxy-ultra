#!/usr/bin/env python3
"""Cursor quota mapping + Grok idle/tmp attribution (no XCTest required)."""
from __future__ import annotations

import sys
from urllib.parse import unquote


def cursor_used_percent(obj: dict | None, remaining_keys: list[str]) -> float | None:
    if not obj:
        return None
    used = obj.get("used")
    limit = obj.get("limit")
    if isinstance(used, (int, float)) and isinstance(limit, (int, float)) and limit > 0:
        return max(0.0, min(100.0, used / limit * 100.0))
    for key in remaining_keys:
        if key in obj and isinstance(obj[key], (int, float)):
            remaining = float(obj[key])
            pct = remaining * 100 if remaining <= 1 else remaining
            if 0 <= pct <= 100:
                return max(0.0, min(100.0, 100.0 - pct))
    return None


def grok_tokens(before: int, context: int, turns: int) -> int:
    if turns <= 0:
        return 0
    return max(0, before) + max(0, context)


def is_ephemeral(path: str) -> bool:
    decoded = unquote(path).lower()
    return any(m in decoded for m in ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"))


def main() -> int:
    failures: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        if ok:
            print(f"ok  {name}")
        else:
            failures.append(name)
            print(f"FAIL {name}" + (f": {detail}" if detail else ""))

    plan = {"used": 1288, "limit": 2000, "totalPercentUsed": 0}
    pct = cursor_used_percent(plan, ["totalPercentUsed"])
    check("cursor used/limit wins over remaining-percent 0", pct is not None and abs(pct - 64.4) < 0.1, str(pct))

    leftover = {"totalPercentUsed": 94, "autoPercentUsed": 100}
    check(
        "cursor remaining-percent inverts to used",
        cursor_used_percent(leftover, ["totalPercentUsed"]) == 6.0,
        str(cursor_used_percent(leftover, ["totalPercentUsed"])),
    )
    check("unused remaining 100 → 0% used", cursor_used_percent({"autoPercentUsed": 100}, ["autoPercentUsed"]) == 0.0)

    check("grok idle context is 0", grok_tokens(0, 53041, 0) == 0)
    check("grok active is snapshot not ramp", grok_tokens(0, 53041, 11) == 53041)
    check("tmp path skipped", is_ephemeral("/private/tmp/x/signals.json"))
    check("encoded tmp skipped", is_ephemeral("%2Fprivate%2Ftmp%2Fx/signals.json"))
    check("user project kept", not is_ephemeral("/Users/me/Projects/app/signals.json"))

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
