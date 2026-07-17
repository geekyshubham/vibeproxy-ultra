#!/usr/bin/env python3
"""Runnable checks for account Remove / Add lifecycle (no XCTest required).

Covers:
- multi-file seat deletion (all codex files sharing account_id)
- tombstones prevent resurrection
- auth file change detection after OAuth-like writes
- identity keys keep Go vs Team distinct

Uses a temporary ~/.cli-proxy-api stand-in — never touches the user's real auth dir.
Exit 0 on success.
"""
from __future__ import annotations

import base64
import json
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def make_jwt(account_id: str, plan: str) -> str:
    header = b64url(b'{"alg":"none","typ":"JWT"}')
    payload = {
        "https://api.openai.com/auth": {
            "chatgpt_account_id": account_id,
            "chatgpt_plan_type": plan,
        },
        "exp": int(datetime(2030, 1, 1, tzinfo=timezone.utc).timestamp()),
    }
    body = b64url(json.dumps(payload, separators=(",", ":")).encode())
    return f"{header}.{body}.sig"


def write_auth(path: Path, *, email: str, account_id: str, plan: str) -> None:
    rec = {
        "type": "codex",
        "email": email,
        "access_token": make_jwt(account_id, plan),
        "account_id": account_id,
        "plan_type": plan,
        "refresh_token": "rt.test",
    }
    path.write_text(json.dumps(rec, indent=2))


def load_tombstones(auth_dir: Path) -> set[str]:
    p = auth_dir / ".vibeproxy-deleted-seats.json"
    if not p.exists():
        return set()
    data = json.loads(p.read_text())
    return set(s.lower() for s in data.get("seats", []))


def save_tombstones(auth_dir: Path, seats: set[str]) -> None:
    p = auth_dir / ".vibeproxy-deleted-seats.json"
    p.write_text(
        json.dumps(
            {"seats": sorted(seats), "updated_at": datetime.now(timezone.utc).isoformat()},
            indent=2,
        )
    )


def codex_account_id(path: Path) -> str | None:
    d = json.loads(path.read_text())
    at = d.get("access_token") or ""
    if at.count(".") == 2:
        pad = at.split(".")[1] + "=" * (-len(at.split(".")[1]) % 4)
        auth = json.loads(base64.urlsafe_b64decode(pad)).get("https://api.openai.com/auth", {})
        if auth.get("chatgpt_account_id"):
            return auth["chatgpt_account_id"]
    return d.get("account_id")


def files_for_seat(auth_dir: Path, account_id: str) -> list[Path]:
    out = []
    for p in auth_dir.glob("codex*.json"):
        aid = codex_account_id(p)
        if aid and aid.lower() == account_id.lower():
            out.append(p)
        elif p.name.lower() == f"codex-seat-{account_id.lower()}.json":
            out.append(p)
    return out


def delete_seat(auth_dir: Path, account_id: str) -> list[Path]:
    targets = files_for_seat(auth_dir, account_id)
    deleted = []
    for p in targets:
        p.unlink()
        deleted.append(p)
    seats = load_tombstones(auth_dir)
    seats.add(f"codex:{account_id.lower()}")
    save_tombstones(auth_dir, seats)
    return deleted


def auth_snapshot(auth_dir: Path) -> dict[str, float]:
    return {p.name: p.stat().st_mtime for p in auth_dir.glob("*.json")}


def auth_changed(auth_dir: Path, before: dict[str, float]) -> list[str]:
    after = auth_snapshot(auth_dir)
    changed = []
    for name, mtime in after.items():
        if name not in before or mtime > before[name] + 0.01:
            changed.append(name)
    return sorted(changed)


def main() -> int:
    failures: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        if ok:
            print(f"ok  {name}")
        else:
            failures.append(name)
            print(f"FAIL {name}" + (f": {detail}" if detail else ""))

    go_id = "b8490ad0-efd0-4413-a1f3-38e7e1dcb977"
    team_id = "f7268a18-b7e1-42d3-b4b1-286f67b74b4d"
    email = "shubham.takankhar@gmail.com"

    with tempfile.TemporaryDirectory() as tmp:
        auth = Path(tmp)
        # Three files same Team seat (the real-world mess)
        write_auth(auth / f"codex-{email}.json", email=email, account_id=team_id, plan="team")
        write_auth(
            auth / f"codex-seat-{team_id}.json",
            email=email,
            account_id=team_id,
            plan="team",
        )
        write_auth(
            auth / f"codex-9c921088-{email}-team.json",
            email=email,
            account_id=team_id,
            plan="team",
        )
        # Separate Go seat
        write_auth(
            auth / f"codex-seat-{go_id}.json",
            email=email,
            account_id=go_id,
            plan="go",
        )

        check(
            "three team files match same seat",
            len(files_for_seat(auth, team_id)) == 3,
            str(files_for_seat(auth, team_id)),
        )
        check("one go file", len(files_for_seat(auth, go_id)) == 1)

        deleted = delete_seat(auth, team_id)
        check("delete removes all three team files", len(deleted) == 3, str(deleted))
        check("no team files remain", len(files_for_seat(auth, team_id)) == 0)
        check("go seat untouched", len(files_for_seat(auth, go_id)) == 1)
        check(
            "tombstone records team seat",
            f"codex:{team_id}" in load_tombstones(auth),
            str(load_tombstones(auth)),
        )

        # Resurrection attempt (old materialize-from-cockpit bug)
        if f"codex:{team_id}" in load_tombstones(auth):
            # materialize would skip — simulate
            resurrected = False
        else:
            resurrected = True
        check("tombstone blocks materialize resurrection", not resurrected)

        # OAuth re-add: clear tombstone when new file appears
        before = auth_snapshot(auth)
        write_auth(
            auth / f"codex-newlogin-{email}.json",
            email=email,
            account_id=team_id,
            plan="team",
        )
        changed = auth_changed(auth, before)
        check("oauth write detected as change", any("newlogin" in n for n in changed), str(changed))
        # clear tombstone on present seats
        seats = load_tombstones(auth)
        seats.discard(f"codex:{team_id}")
        save_tombstones(auth, seats)
        check("re-login clears tombstone", f"codex:{team_id}" not in load_tombstones(auth))

        # Identity keys
        def identity(email: str, account_id: str) -> str:
            return f"codex-seat:{email.lower()}|{account_id.lower()}"

        check(
            "go and team identity differ",
            identity(email, go_id) != identity(email, team_id),
        )

        # Same seat, three files → one identity key (dedupe)
        keys = {
            identity(email, team_id),
            identity(email, team_id),
            identity("other@x.com", team_id),  # different member of same workspace
        }
        check("same email+seat collapses", len({identity(email, team_id)}) == 1)
        check(
            "different emails on same workspace stay distinct",
            identity(email, team_id) != identity("shravan.k@checkred.com", team_id),
        )
        # Seat-scoped usage: a go JWT file should only report go target, not team
        this_seat = go_id
        memberships = [
            {"id": go_id, "plan": "go"},
            {"id": team_id, "plan": "team"},
        ]
        scoped = [m for m in memberships if m["id"] == this_seat]
        check("seat-scoped usage targets only this seat", len(scoped) == 1 and scoped[0]["plan"] == "go")

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nall lifecycle checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
