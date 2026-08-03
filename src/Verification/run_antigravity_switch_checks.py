#!/usr/bin/env python3
"""Parity checks for Antigravity IDE oauthToken wire format (Cockpit-compatible).

Mirrors NativeSessionManager.buildAntigravityOAuthTokenValue /
parseAntigravityAccessToken. Run:

  python3 src/Verification/run_antigravity_switch_checks.py
"""

from __future__ import annotations

import base64
import re
import sys


def encode_varint(n: int) -> bytes:
    out = bytearray()
    while n > 0x7F:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n & 0x7F)
    return bytes(out)


def encode_key(field: int, wire: int) -> bytes:
    return encode_varint((field << 3) | wire)


def encode_bytes(field: int, payload: bytes) -> bytes:
    return encode_key(field, 2) + encode_varint(len(payload)) + payload


def encode_string(field: int, s: str) -> bytes:
    return encode_bytes(field, s.encode("utf-8"))


def encode_varint_field(field: int, value: int) -> bytes:
    return encode_key(field, 0) + encode_varint(value)


AUTH_STATE = (
    '{"state":"signedIn","context":{"project":"","showProjectError":false,'
    '"errorMessage":"","ineligibleMessage":"","verificationUrl":"",'
    '"isGcpTos":false,"browserOpenFailed":false,"appealUrl":"","appealLinkText":""}}'
)


def build_oauth_token_value(
    access: str, refresh: str | None, expiry: int, existing: str | None = None
) -> str:
    sentinels = parse_sentinel_map(existing)
    sentinels["authStateWithContextSentinelKey"] = AUTH_STATE
    token = encode_string(1, access) + encode_string(2, "Bearer")
    if refresh:
        token += encode_string(3, refresh)
    token += encode_bytes(4, encode_varint_field(1, expiry))
    sentinels["oauthTokenInfoSentinelKey"] = base64.b64encode(token).decode("ascii")

    ordered: list[tuple[str, str]] = []
    for key in (
        "authStateWithContextSentinelKey",
        "oauthTokenInfoSentinelKey",
    ):
        if key in sentinels:
            ordered.append((key, sentinels.pop(key)))
    for key in sorted(sentinels):
        ordered.append((key, sentinels[key]))

    outer = b""
    for key, value in ordered:
        value_msg = encode_string(1, value)
        entry = encode_string(1, key) + encode_bytes(2, value_msg)
        outer += encode_bytes(1, entry)
    return base64.b64encode(outer).decode("ascii")


def parse_length_delimited(data: bytes) -> list[tuple[int, bytes]]:
    i = 0
    items: list[tuple[int, bytes]] = []
    while i < len(data):
        key = 0
        shift = 0
        while True:
            if i >= len(data):
                return items
            b = data[i]
            i += 1
            key |= (b & 0x7F) << shift
            if not (b & 0x80):
                break
            shift += 7
            if shift > 63:
                return items
        field = key >> 3
        wire = key & 7
        if field <= 0 or field >= 1000:
            break
        if wire == 0:
            while True:
                if i >= len(data):
                    return items
                b = data[i]
                i += 1
                if not (b & 0x80):
                    break
        elif wire == 2:
            ln = 0
            shift = 0
            while True:
                if i >= len(data):
                    return items
                b = data[i]
                i += 1
                ln |= (b & 0x7F) << shift
                if not (b & 0x80):
                    break
                shift += 7
            if i + ln > len(data):
                break
            items.append((field, data[i : i + ln]))
            i += ln
        elif wire == 1:
            i += 8
        elif wire == 5:
            i += 4
        else:
            break
    return items


def parse_sentinel_map(value: str | None) -> dict[str, str]:
    if not value:
        return {}
    try:
        outer = base64.b64decode(value)
    except Exception:
        return {}
    result: dict[str, str] = {}
    for field, payload in parse_length_delimited(outer):
        if field != 1:
            continue
        inner = parse_length_delimited(payload)
        key_b = next((p for f, p in inner if f == 1), None)
        val_msg = next((p for f, p in inner if f == 2), None)
        if key_b is None or val_msg is None:
            continue
        val_fields = parse_length_delimited(val_msg)
        val_b = next((p for f, p in val_fields if f == 1), None)
        if val_b is None:
            continue
        result[key_b.decode("utf-8")] = val_b.decode("utf-8")
    return result


def parse_access_token(value: str) -> str | None:
    info_b64 = parse_sentinel_map(value).get("oauthTokenInfoSentinelKey")
    if not info_b64:
        return None
    info = base64.b64decode(info_b64)
    for field, payload in parse_length_delimited(info):
        if field == 1:
            return payload.decode("utf-8")
    return None


def extract_email_from_user_status(raw: str) -> str | None:
    email_re = re.compile(r"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}", re.I)

    def first_email(text: str) -> str | None:
        m = email_re.search(text)
        return m.group(0) if m else None

    try:
        outer = base64.b64decode(raw)
    except Exception:
        return first_email(raw)

    if email := first_email(outer.decode("utf-8", errors="ignore")):
        return email

    ascii_text = outer.decode("utf-8", errors="ignore")
    for chunk in re.findall(r"[A-Za-z0-9+/=]{24,}", ascii_text):
        try:
            decoded = base64.b64decode(chunk + "=" * ((4 - len(chunk) % 4) % 4))
        except Exception:
            continue
        if email := first_email(decoded.decode("utf-8", errors="ignore")):
            return email
    return first_email(outer.decode("utf-8", errors="ignore"))


def main() -> int:
    access = "ya29.a0ARGnu0_test_access_token_value"
    refresh = "1//0g_test_refresh_token_value"
    expiry = 1_785_677_611

    value = build_oauth_token_value(access, refresh, expiry)
    got = parse_access_token(value)
    assert got == access, f"round-trip access mismatch: {got!r}"

    second = build_oauth_token_value("ya29.second", "1//second", 1_800_000_000, value)
    assert parse_access_token(second) == "ya29.second"

    # Nested base64 userStatus email extraction
    name_email = (
        bytes([0x1A, 0x0C])
        + b"Aiden Pierce"
        + bytes([0x22, 0x11])
        + b"d3ds3c3@gmail.com"
    )
    nested_b64 = base64.b64encode(name_email).decode("ascii")
    outer = base64.b64encode(nested_b64.encode("ascii")).decode("ascii")
    email = extract_email_from_user_status(outer)
    assert email == "d3ds3c3@gmail.com", f"email extract failed: {email!r}"

    # Real on-disk value (if present) must still parse.
    from pathlib import Path

    db = (
        Path.home()
        / "Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb"
    )
    if db.exists():
        import sqlite3

        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        cur = conn.cursor()
        cur.execute(
            "SELECT value FROM ItemTable WHERE key = ?",
            ("antigravityUnifiedStateSync.oauthToken",),
        )
        row = cur.fetchone()
        conn.close()
        if row and row[0]:
            raw = row[0] if isinstance(row[0], str) else row[0].decode("utf-8", "replace")
            tok = parse_access_token(raw)
            assert tok and tok.startswith("ya29."), f"live oauthToken unreadable: {tok!r}"

    print("run_antigravity_switch_checks: OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
