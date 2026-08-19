#!/usr/bin/env python3
"""Checks for paste-JSON account import shapes (no XCTest required).

Mirrors ManualTokenImporter.detectType / nested-token unwrap:
- ~/.codex/auth.json with tokens{}
- Cursor {email, accessToken, refreshToken}
- Claude {claudeAiOauth:{}}
"""
from __future__ import annotations

import json
import sys


def check(name: str, ok: bool, detail: str = "") -> None:
    status = "ok" if ok else "FAIL"
    extra = f" — {detail}" if detail else ""
    print(f"[{status}] {name}{extra}")
    if not ok:
        raise SystemExit(1)


def unwrap(raw: dict) -> dict:
    out = dict(raw)
    tokens = raw.get("tokens")
    if isinstance(tokens, dict):
        for key, value in tokens.items():
            out.setdefault(key, value)
    oauth = raw.get("claudeAiOauth")
    if isinstance(oauth, dict):
        out.setdefault("access_token", oauth.get("accessToken") or oauth.get("access_token"))
        out.setdefault("refresh_token", oauth.get("refreshToken") or oauth.get("refresh_token"))
        out.setdefault("email", oauth.get("email"))
    return out


def detect(raw: dict, preferred: str) -> str:
    t = str(raw.get("type") or "").lower()
    if t:
        return t
    if raw.get("tokens") or str(raw.get("auth_mode") or "").lower() == "chatgpt":
        return "codex"
    if raw.get("claudeAiOauth") is not None:
        return "claude"
    if raw.get("cachedEmail") or raw.get("cursor_access_token"):
        return "cursor"
    return preferred


def main() -> None:
    codex = {
        "auth_mode": "chatgpt",
        "OPENAI_API_KEY": None,
        "tokens": {
            "access_token": "at",
            "refresh_token": "rt.1.example",
            "id_token": "id",
            "account_id": "acct-1",
        },
        "last_refresh": "2026-06-08T09:03:29Z",
    }
    u = unwrap(codex)
    check("codex nested tokens unwrap", u.get("refresh_token") == "rt.1.example" and u.get("account_id") == "acct-1")
    check("codex detect from auth.json", detect(codex, "cursor") == "codex")

    cursor = {"email": "dev@example.com", "accessToken": "ca", "refreshToken": "cr", "membershipType": "pro"}
    check("cursor detect prefers explicit type field", detect({"type": "cursor", **cursor}, "codex") == "cursor")

    claude = {"claudeAiOauth": {"accessToken": "at", "refreshToken": "rt", "email": "c@x.com"}}
    u = unwrap(claude)
    check("claude wrapper unwrap", u.get("access_token") == "at" and u.get("refresh_token") == "rt")
    check("claude detect", detect(claude, "codex") == "claude")

    print("all checks passed")


if __name__ == "__main__":
    main()
    sys.exit(0)
