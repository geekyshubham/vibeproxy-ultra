#!/usr/bin/env python3
"""Runnable checks for multi-seat Codex switch (Go ↔ Team), no XCTest required.

Mirrors the critical production rules:
- seats are keyed by chatgpt_account_id (not email alone)
- expired access + dead refresh => refuse switch (do not write dead Go tokens)
- recently-expired cli-proxy tokens beat ancient Cockpit copies
- unique refresh tokens are tried newest-first
- seat files materialize as codex-seat-{account_id}.json

Exit 0 on success, 1 on failure.
"""
from __future__ import annotations

import base64
import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

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
    now = datetime.now(timezone.utc)
    exp = jwt_exp(token)
    if exp > now:
        s += 50
    if has_refresh:
        s += 10
    hours = (exp - now).total_seconds() / 3600
    s += int(max(-400, min(400, hours)))
    if source.startswith("cockpit"):
        s += 5
    if source == "seed":
        s += 3
    if source.startswith("cli-proxy") or source.startswith("codex-seat"):
        s += 2
    return s


def seat_filename(account_id: str) -> str:
    return f"codex-seat-{account_id.strip().lower()}.json"


def unique_refresh_lineages(cands: list[tuple[datetime, str]]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for _, rt in sorted(cands, key=lambda c: c[0], reverse=True):
        if not rt or rt in seen:
            continue
        seen.add(rt)
        out.append(rt)
    return out


def main() -> int:
    failures: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        if ok:
            print(f"ok  {name}")
        else:
            failures.append(name)
            print(f"FAIL {name}" + (f": {detail}" if detail else ""))

    go_live = make_jwt(GO_ID, "go", datetime(2030, 1, 1, tzinfo=timezone.utc))
    go_dead = make_jwt(GO_ID, "go", datetime(2020, 1, 1, tzinfo=timezone.utc))
    team_live = make_jwt(TEAM_ID, "team", datetime(2030, 1, 1, tzinfo=timezone.utc))

    # pickBest prefers live JWT match
    s_dead = score(GO_ID, go_dead, "cockpit", True)
    s_live = score(GO_ID, go_live, "cli-proxy", True)
    check("pickBest prefers non-expired Go", s_live > s_dead, f"{s_live} vs {s_dead}")

    s_team = score(TEAM_ID, team_live, "seed", True)
    check("team live scores high", s_team >= 150, str(s_team))

    team_recent_dead = make_jwt(TEAM_ID, "team", datetime.now(timezone.utc) - timedelta(hours=25))
    team_ancient = make_jwt(TEAM_ID, "team", datetime(2026, 7, 11, tzinfo=timezone.utc))
    s_recent = score(TEAM_ID, team_recent_dead, "cli-proxy", True)
    s_ancient = score(TEAM_ID, team_ancient, "cockpit", True)
    check(
        "recently-expired cli-proxy beats ancient cockpit",
        s_recent > s_ancient,
        f"{s_recent} vs {s_ancient}",
    )
    order = unique_refresh_lineages(
        [
            (jwt_exp(team_ancient), "rt-old"),
            (jwt_exp(team_recent_dead), "rt-mid"),
            (jwt_exp(team_recent_dead), "rt-mid"),
        ]
    )
    check("unique RTs newest-first, duplicates dropped", order == ["rt-mid", "rt-old"], str(order))

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

    # Native "Active" match: seat id alone must not mark two Team users current.
    # Mirrors NativeSessionManager.matchesSession (email + seat for Codex).
    def matches_session(
        account_email: str | None,
        account_seat: str | None,
        identity_email: str | None,
        identity_seat: str | None,
    ) -> bool:
        seat_match = (
            bool(account_seat)
            and bool(identity_seat)
            and account_seat.lower() == identity_seat.lower()
        )
        email_match = None
        if account_email and identity_email:
            email_match = account_email.lower() == identity_email.lower()
        if seat_match:
            if email_match is not None:
                return email_match
            return True
        if account_seat and identity_seat:
            return False
        return email_match is True

    check(
        "same Team different emails: only native login is Active",
        matches_session("shubhamt@olap.site", TEAM_ID, "shubhamt@olap.site", TEAM_ID)
        and not matches_session("shuham@olap.site", TEAM_ID, "shubhamt@olap.site", TEAM_ID),
    )
    check(
        "same email different seats: only matching seat is Active",
        matches_session(EMAIL, TEAM_ID, EMAIL, TEAM_ID)
        and not matches_session(EMAIL, GO_ID, EMAIL, TEAM_ID),
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

        # Do not POST real refresh tokens here. A success without persist rotates
        # the family out from under the auth files. Switch refuses expired+dead
        # (Swift resolveFresh); live refresh is keep-alive / switch-path only.
        team = seats.get(TEAM_ID.lower())
        check("team seat present", team is not None)
        go = seats.get(GO_ID.lower())
        check("go seat lineage present for dual-seat UX", go is not None)

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
