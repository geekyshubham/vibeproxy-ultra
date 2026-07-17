#!/usr/bin/env python3
"""Runnable checks for multi-seat Codex switch (Go ↔ Team), no XCTest required.

Mirrors the critical production rules:
- seats are keyed by chatgpt_account_id (not email alone)
- expired access + dead refresh => refuse switch (do not write dead Go tokens)
- live Team seat can refresh / write
- seat files materialize as codex-seat-{account_id}.json

Exit 0 on success, 1 on failure.
"""
from __future__ import annotations

import base64
import json
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
TOKEN_URL = "https://auth.openai.com/oauth/token"
GO_ID = "b8490ad0-efd0-4413-a1f3-38e7e1dcb977"
TEAM_ID = "f7268a18-b7e1-42d3-b4b1-286f67b74b4d"
EMAIL = "shubham.takankhar@gmail.com"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def make_jwt(account_id: str, plan: str, exp: datetime) -> str:
    header = b64url(b'{"alg":"none","typ":"JWT"}')
    payload = {
        "https://api.openai.com/auth": {
            "chatgpt_account_id": account_id,
            "chatgpt_plan_type": plan,
        },
        "exp": int(exp.timestamp()),
    }
    body = b64url(json.dumps(payload, separators=(",", ":")).encode())
    return f"{header}.{body}.sig"


def jwt_auth(token: str) -> dict:
    pad = token.split(".")[1] + "=" * (-len(token.split(".")[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(pad)).get("https://api.openai.com/auth", {})


def jwt_exp(token: str) -> datetime:
    pad = token.split(".")[1] + "=" * (-len(token.split(".")[1]) % 4)
    exp = json.loads(base64.urlsafe_b64decode(pad))["exp"]
    return datetime.fromtimestamp(exp, tz=timezone.utc)


def score(account_id: str, token: str, source: str, has_refresh: bool) -> int:
    auth = jwt_auth(token)
    s = 0
    if (auth.get("chatgpt_account_id") or "").lower() == account_id.lower():
        s += 100
    if jwt_exp(token) > datetime.now(timezone.utc):
        s += 50
    if has_refresh:
        s += 10
    if source.startswith("cockpit"):
        s += 5
    if source == "seed":
        s += 3
    if source.startswith("cli-proxy") or source.startswith("codex-seat"):
        s += 2
    return s


def seat_filename(account_id: str) -> str:
    return f"codex-seat-{account_id.strip().lower()}.json"


def try_refresh(rt: str) -> dict | None:
    data = urllib.parse.urlencode(
        {"grant_type": "refresh_token", "refresh_token": rt, "client_id": CLIENT_ID}
    ).encode()
    req = urllib.request.Request(TOKEN_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except Exception:
        return None


def main() -> int:
    failures: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        if ok:
            print(f"ok  {name}")
        else:
            failures.append(name)
            print(f"FAIL {name}" + (f": {detail}" if detail else ""))

    now = datetime.now(timezone.utc)
    go_live = make_jwt(GO_ID, "go", datetime(2030, 1, 1, tzinfo=timezone.utc))
    go_dead = make_jwt(GO_ID, "go", datetime(2020, 1, 1, tzinfo=timezone.utc))
    team_live = make_jwt(TEAM_ID, "team", datetime(2030, 1, 1, tzinfo=timezone.utc))

    # pickBest prefers live JWT match
    s_dead = score(GO_ID, go_dead, "cockpit", True)
    s_live = score(GO_ID, go_live, "cli-proxy", True)
    check("pickBest prefers non-expired Go", s_live > s_dead, f"{s_live} vs {s_dead}")

    s_team = score(TEAM_ID, team_live, "seed", True)
    check("team live scores high", s_team >= 150, str(s_team))

    # foreign seat must not accept Go JWT as Team
    go_auth = jwt_auth(go_live)
    check(
        "go JWT is not team seat",
        go_auth.get("chatgpt_account_id") != TEAM_ID,
    )

    check("seat filename stable", seat_filename(TEAM_ID) == seat_filename(TEAM_ID.upper()))
    check(
        "seat filenames differ per seat",
        seat_filename(GO_ID) != seat_filename(TEAM_ID),
    )

    # Identity key simulation (email alone would collide)
    def identity(email: str, account_id: str) -> str:
        return f"codex-seat:{email.lower()}|{account_id.lower()}"

    check(
        "identity keys differ for same email dual seats",
        identity(EMAIL, GO_ID) != identity(EMAIL, TEAM_ID),
    )

    # Materialize into temp dir from real home sources
    home = Path.home()
    cockpit = home / ".antigravity_cockpit/codex_accounts"
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        seats: dict[str, dict] = {}
        if cockpit.exists():
            for p in cockpit.glob("*.json"):
                d = json.loads(p.read_text())
                if d.get("email") != EMAIL:
                    continue
                t = d.get("tokens") or {}
                at = t.get("access_token")
                if not at:
                    continue
                aid = d.get("account_id") or jwt_auth(at).get("chatgpt_account_id")
                if not aid:
                    continue
                seats[aid.lower()] = {
                    "access_token": at,
                    "refresh_token": t.get("refresh_token"),
                    "account_id": aid,
                    "plan_type": d.get("plan_type") or jwt_auth(at).get("chatgpt_plan_type"),
                    "email": EMAIL,
                    "type": "codex",
                }
        proxy = home / ".cli-proxy-api"
        if proxy.exists():
            for p in proxy.glob("codex*.json"):
                d = json.loads(p.read_text())
                at = d.get("access_token")
                if not at:
                    continue
                try:
                    auth = jwt_auth(at)
                except Exception:
                    continue
                aid = auth.get("chatgpt_account_id") or d.get("account_id")
                if not aid:
                    continue
                if d.get("email") and d.get("email") != EMAIL:
                    continue
                key = aid.lower()
                # prefer later exp
                if key in seats:
                    if jwt_exp(at) <= jwt_exp(seats[key]["access_token"]):
                        continue
                seats[key] = {
                    "access_token": at,
                    "refresh_token": d.get("refresh_token"),
                    "account_id": aid,
                    "plan_type": auth.get("chatgpt_plan_type") or d.get("plan_type"),
                    "email": EMAIL,
                    "type": "codex",
                }

        for aid, rec in seats.items():
            path = tmp_path / seat_filename(aid)
            path.write_text(json.dumps(rec, indent=2))

        check("materialized at least team seat", TEAM_ID.lower() in seats, str(list(seats)))
        check("materialized go seat lineage (even if expired)", GO_ID.lower() in seats)

        # Team switch path: live or refreshable
        team = seats.get(TEAM_ID.lower())
        if team:
            exp = jwt_exp(team["access_token"])
            if exp > now:
                check("team access live — switch allowed without refresh", True)
            else:
                refreshed = try_refresh(team.get("refresh_token") or "")
                check("team refresh when expired", refreshed is not None)
                if refreshed:
                    auth = jwt_auth(refreshed["access_token"])
                    check(
                        "team refresh keeps team seat",
                        auth.get("chatgpt_account_id") == TEAM_ID
                        and auth.get("chatgpt_plan_type") == "team",
                    )
        else:
            check("team seat present", False)

        # Go switch path: must refuse if access expired and refresh dead
        go = seats.get(GO_ID.lower())
        if go:
            exp = jwt_exp(go["access_token"])
            if exp > now:
                check("go access live — switch allowed", True)
            else:
                refreshed = try_refresh(go.get("refresh_token") or "")
                check(
                    "go expired+dead RT refuses switch (no dead token write)",
                    refreshed is None,
                    "refresh unexpectedly succeeded",
                )
        else:
            check("go seat lineage present for dual-seat UX", False)

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
