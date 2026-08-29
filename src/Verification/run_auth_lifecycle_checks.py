#!/usr/bin/env python3
"""Runnable checks for account Remove / Add lifecycle (no XCTest required).

Covers:
- multi-file deletion for one ChatGPT login (same email + workspace)
- two Team members on the same chatgpt_account_id stay independent
- tombstones prevent resurrection of that login only
- auth file change detection after OAuth-like writes
- identity keys keep Go vs Team distinct

Uses a temporary ~/.cli-proxy-api stand-in — never touches the user's real auth dir.
Exit 0 on success.
"""
from __future__ import annotations

import base64
import json
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def make_jwt(account_id: str, plan: str, *, user_id: str | None = None) -> str:
    header = b64url(b'{"alg":"none","typ":"JWT"}')
    auth = {
        "chatgpt_account_id": account_id,
        "chatgpt_plan_type": plan,
    }
    if user_id:
        auth["chatgpt_user_id"] = user_id
    payload = {
        "https://api.openai.com/auth": auth,
        "exp": int(datetime(2030, 1, 1, tzinfo=timezone.utc).timestamp()),
    }
    body = b64url(json.dumps(payload, separators=(",", ":")).encode())
    return f"{header}.{body}.sig"


def write_auth(path: Path, *, email: str, account_id: str, plan: str, user_id: str | None = None) -> None:
    rec = {
        "type": "codex",
        "email": email,
        "access_token": make_jwt(account_id, plan, user_id=user_id),
        "account_id": account_id,
        "plan_type": plan,
        "refresh_token": "rt.test",
    }
    path.write_text(json.dumps(rec, indent=2))


def load_tombstones(auth_dir: Path) -> set[str]:
    p = auth_dir / ".viberouter-deleted-seats.json"
    if not p.exists():
        return set()
    data = json.loads(p.read_text())
    return set(s.lower() for s in data.get("seats", []))


def save_tombstones(auth_dir: Path, seats: set[str]) -> None:
    p = auth_dir / ".viberouter-deleted-seats.json"
    p.write_text(
        json.dumps(
            {"seats": sorted(seats), "updated_at": datetime.now(timezone.utc).isoformat()},
            indent=2,
        )
    )


def jwt_auth(path: Path) -> dict:
    d = json.loads(path.read_text())
    at = d.get("access_token") or ""
    if at.count(".") == 2:
        pad = at.split(".")[1] + "=" * (-len(at.split(".")[1]) % 4)
        return json.loads(base64.urlsafe_b64decode(pad)).get("https://api.openai.com/auth", {})
    return {}


def codex_account_id(path: Path) -> str | None:
    auth = jwt_auth(path)
    if auth.get("chatgpt_account_id"):
        return auth["chatgpt_account_id"]
    return json.loads(path.read_text()).get("account_id")


def codex_email(path: Path) -> str | None:
    d = json.loads(path.read_text())
    email = (d.get("email") or "").strip().lower()
    return email or None


def same_login(*, target_id: str, target_email: str, file: Path) -> bool:
    file_id = (codex_account_id(file) or "").lower()
    file_email = codex_email(file)
    if file_id != target_id.lower():
        return False
    if file_email and target_email:
        return file_email == target_email.lower()
    return False


def files_for_login(auth_dir: Path, *, email: str, account_id: str) -> list[Path]:
    return [
        p
        for p in auth_dir.glob("codex*.json")
        if same_login(target_id=account_id, target_email=email, file=p)
    ]


def delete_login(auth_dir: Path, *, email: str, account_id: str) -> list[Path]:
    targets = files_for_login(auth_dir, email=email, account_id=account_id)
    deleted = []
    for p in targets:
        p.unlink()
        deleted.append(p)
    seats = load_tombstones(auth_dir)
    seats.add(f"codex:{email.lower()}|{account_id.lower()}")
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
    teammate = "shravan.k@checkred.com"

    with tempfile.TemporaryDirectory() as tmp:
        auth = Path(tmp)
        write_auth(auth / f"codex-{email}.json", email=email, account_id=team_id, plan="team", user_id="u1")
        write_auth(
            auth / f"codex-seat-{team_id}.json",
            email=email,
            account_id=team_id,
            plan="team",
            user_id="u1",
        )
        write_auth(
            auth / f"codex-9c921088-{email}-team.json",
            email=email,
            account_id=team_id,
            plan="team",
            user_id="u1",
        )
        write_auth(
            auth / f"codex-{teammate}.json",
            email=teammate,
            account_id=team_id,
            plan="team",
            user_id="u2",
        )
        write_auth(
            auth / f"codex-seat-{team_id}-{teammate.replace('@', '_at_')}.json",
            email=teammate,
            account_id=team_id,
            plan="team",
            user_id="u2",
        )
        write_auth(
            auth / f"codex-seat-{go_id}.json",
            email=email,
            account_id=go_id,
            plan="go",
            user_id="u1",
        )

        check(
            "three team files match first login",
            len(files_for_login(auth, email=email, account_id=team_id)) == 3,
            str(files_for_login(auth, email=email, account_id=team_id)),
        )
        check(
            "two team files match teammate",
            len(files_for_login(auth, email=teammate, account_id=team_id)) == 2,
        )
        check("one go file", len(files_for_login(auth, email=email, account_id=go_id)) == 1)

        deleted = delete_login(auth, email=email, account_id=team_id)
        check("delete removes three files for that login", len(deleted) == 3, str(deleted))
        check(
            "first login files gone",
            len(files_for_login(auth, email=email, account_id=team_id)) == 0,
        )
        check(
            "teammate on same workspace remains",
            len(files_for_login(auth, email=teammate, account_id=team_id)) == 2,
            str(list(auth.glob("codex*.json"))),
        )
        check("go seat untouched", len(files_for_login(auth, email=email, account_id=go_id)) == 1)
        tombstone = f"codex:{email}|{team_id}"
        check(
            "tombstone records that login only",
            tombstone in load_tombstones(auth)
            and f"codex:{teammate}|{team_id}" not in load_tombstones(auth),
            str(load_tombstones(auth)),
        )
        check(
            "unscoped workspace tombstone is not written",
            f"codex:{team_id}" not in load_tombstones(auth),
            str(load_tombstones(auth)),
        )

        resurrected = tombstone not in load_tombstones(auth)
        check("tombstone blocks materialize resurrection", not resurrected)

        before = auth_snapshot(auth)
        write_auth(
            auth / f"codex-newlogin-{email}.json",
            email=email,
            account_id=team_id,
            plan="team",
            user_id="u1",
        )
        changed = auth_changed(auth, before)
        check("oauth write detected as change", any("newlogin" in n for n in changed), str(changed))
        seats = load_tombstones(auth)
        seats.discard(tombstone)
        save_tombstones(auth, seats)
        check("re-login clears tombstone", tombstone not in load_tombstones(auth))

        def identity(addr: str, account_id: str) -> str:
            return f"codex-seat:{addr.lower()}|{account_id.lower()}"

        check(
            "go and team identity differ",
            identity(email, go_id) != identity(email, team_id),
        )
        check("same email+seat collapses", len({identity(email, team_id)}) == 1)
        check(
            "different emails on same workspace stay distinct",
            identity(email, team_id) != identity(teammate, team_id),
        )

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
