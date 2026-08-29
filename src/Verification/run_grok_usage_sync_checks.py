#!/usr/bin/env python3
"""Grok usage-limit sync: live CLI tokens beat dead cli-proxy copies.

No XCTest required. Exit 0 on success, 1 on failure.

Catches the two regressions that kept coming back:
1. xAI refresh aimed at /oauth/token (Cloudflare 403) instead of /oauth2/token
2. Overview used a one-shot imported xAI file while Grok CLI kept ~/.grok alive
"""
from __future__ import annotations

import struct
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "src/Sources/NativeUsageFetcher.swift"
REFRESH = ROOT / "src/Sources/TokenRefreshService.swift"

# Live GetGrokCreditsConfig body captured 2026-08-29 (73% weekly pool).
BILLING_HEX = (
    "000000005e0a5c0d0000924212001a00220c0890e3bbd40610f8caa8da032a0c"
    "0890d8e0d40610f8caa8da033a07080215000092423a0208043a020805421e"
    "0802120c0890e3bbd40610f8caa8da031a0c0890d8e0d40610f8caa8da0358"
    "0162006801800000000f677270632d7374617475733a300d0a"
)


def check(name: str, ok: bool, detail: str = "") -> None:
    extra = f" — {detail}" if detail else ""
    print(f"[{'ok' if ok else 'FAIL'}] {name}{extra}")
    if not ok:
        raise SystemExit(1)


def source_contains(path: Path, needle: str) -> bool:
    return needle in path.read_text()


def grpc_web_data_frames(data: bytes) -> list[bytes]:
    frames: list[bytes] = []
    index = 0
    while index + 5 <= len(data):
        flags = data[index]
        length = int.from_bytes(data[index + 1 : index + 5], "big")
        start = index + 5
        end = start + length
        if length < 0 or end > len(data):
            break
        if flags & 0x80 == 0:
            frames.append(data[start:end])
        index = end
    return frames


def read_varint(buf: bytes, index: int) -> tuple[int | None, int]:
    value = 0
    shift = 0
    while index < len(buf) and shift < 64:
        byte = buf[index]
        index += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, index
        shift += 7
    return None, index


def scan_protobuf(buf: bytes, path: tuple[int, ...] = (), depth: int = 0) -> list[tuple[tuple[int, ...], str, float | int]]:
    fields: list[tuple[tuple[int, ...], str, float | int]] = []
    index = 0
    while index < len(buf):
        start = index
        key, index = read_varint(buf, index)
        if key is None:
            break
        field_number = key >> 3
        wire = key & 7
        field_path = path + (field_number,)
        if wire == 0:
            value, index = read_varint(buf, index)
            if value is None:
                index = start + 1
                continue
            fields.append((field_path, "varint", value))
        elif wire == 1:
            index += 8
        elif wire == 2:
            length, index = read_varint(buf, index)
            if length is None or index + length > len(buf):
                index = start + 1
                continue
            chunk = buf[index : index + length]
            index += length
            if depth < 4:
                fields.extend(scan_protobuf(chunk, field_path, depth + 1))
        elif wire == 5:
            if index + 4 > len(buf):
                break
            (value,) = struct.unpack_from("<f", buf, index)
            fields.append((field_path, "fixed32", value))
            index += 4
        else:
            index = start + 1
    return fields


def parse_billing(data: bytes, now: datetime) -> tuple[float, int] | None:
    payloads = grpc_web_data_frames(data) or ([data] if data else [])
    fields: list[tuple[tuple[int, ...], str, float | int]] = []
    for payload in payloads:
        fields.extend(scan_protobuf(payload))
    percents = [
        float(value)
        for path, kind, value in fields
        if kind == "fixed32" and path and path[-1] == 1 and 0 <= float(value) <= 100
    ]
    if not percents:
        return None
    resets = [
        int(value)
        for path, kind, value in fields
        if kind == "varint" and 1_700_000_000 <= int(value) <= 2_100_000_000
        and datetime.fromtimestamp(int(value), tz=timezone.utc) > now
        and path == (1, 5, 1)
    ] or [
        int(value)
        for path, kind, value in fields
        if kind == "varint" and 1_700_000_000 <= int(value) <= 2_100_000_000
        and datetime.fromtimestamp(int(value), tz=timezone.utc) > now
    ]
    return percents[0], min(resets) if resets else 0


def jwt(exp: datetime, extra: dict | None = None) -> str:
    import base64
    import json

    def b64(data: bytes) -> str:
        return base64.urlsafe_b64encode(data).decode().rstrip("=")

    header = b64(b'{"alg":"none","typ":"JWT"}')
    payload = {"exp": int(exp.timestamp())}
    if extra:
        payload.update(extra)
    body = b64(json.dumps(payload, separators=(",", ":")).encode())
    return f"{header}.{body}.sig"


def jwt_exp(token: str) -> datetime | None:
    import base64
    import json

    parts = token.split(".")
    if len(parts) < 2:
        return None
    pad = parts[1] + "=" * (-len(parts[1]) % 4)
    raw = json.loads(base64.urlsafe_b64decode(pad))
    value = raw.get("exp")
    return datetime.fromtimestamp(int(value), tz=timezone.utc) if value else None


def is_expired(payload: dict, now: datetime) -> bool:
    token = payload.get("access_token") or payload.get("key") or ""
    exp = jwt_exp(token)
    if exp is not None:
        return exp <= now
    raw = payload.get("expired") or payload.get("expires_at")
    if not raw:
        return False
    try:
        parsed = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed <= now


def candidates(account: dict, local: dict | None, now: datetime) -> list[tuple[str, str, bool]]:
    out: list[tuple[str, str, bool]] = []

    def append(token: str, source: str, expired: bool) -> None:
        if not token or any(t == token for t, _, _ in out):
            return
        row = (token, source, expired)
        if expired:
            out.append(row)
            return
        for i, (_, _, was_expired) in enumerate(out):
            if was_expired:
                out.insert(i, row)
                return
        out.append(row)

    account_email = account.get("email")
    local_email = (local or {}).get("email")
    if local and (local.get("access_token") or local.get("key")):
        emails_match = (
            account_email is None
            if not (account_email and local_email)
            else account_email.lower() == local_email.lower()
        )
        local_live = not is_expired(local, now)
        if emails_match or (local_email is None and local_live):
            append(local["access_token"], "grok-cli", not local_live)
    if account.get("access_token"):
        append(account["access_token"], "auth-file", is_expired(account, now))
    return out


def main() -> None:
    check("NativeUsageFetcher overlays live ~/.grok onto cli-proxy", source_contains(NATIVE, "overlayGrokCLICredentialsIfFresher"))
    check("billing prefers grok-cli token source", source_contains(NATIVE, 'source: "grok-cli"'))
    check("rotated tokens write back to ~/.grok/auth.json", source_contains(REFRESH, "updateGrokAppPayload"))
    check("xAI refresh uses OIDC /oauth2/token", source_contains(REFRESH, "https://auth.x.ai/oauth2/token"))
    check("xAI refresh sends client_id", source_contains(REFRESH, '"client_id": clientID'))
    check("legacy /oauth/token is not the only endpoint", source_contains(REFRESH, "https://auth.x.ai/oauth/token"))
    check(
        "api.x.ai/oauth/token is not a refresh target",
        "https://api.x.ai/oauth/token" not in REFRESH.read_text(),
    )

    now = datetime(2026, 8, 29, 4, 55, tzinfo=timezone.utc)
    data = bytes.fromhex(BILLING_HEX)
    frames = grpc_web_data_frames(data)
    check("grpc-web trailer does not drop the data frame", len(frames) == 1)
    parsed = parse_billing(data, now)
    check("billing protobuf reports 73% used", parsed is not None and abs(parsed[0] - 73) < 0.01, str(parsed))
    check("billing protobuf reset is 2026-09-02", parsed is not None and parsed[1] == 1_788_357_648, str(parsed))

    truncated = data[:99] + b"\xff\xff\xff"
    check("truncated second frame keeps the usage payload", bool(grpc_web_data_frames(truncated)))

    live = jwt(now + timedelta(hours=6))
    dead = jwt(now - timedelta(days=30))
    ordered = candidates(
        {"email": "user@example.com", "access_token": dead},
        {"email": "user@example.com", "access_token": live},
        now,
    )
    check("live CLI token is tried before a dead cli-proxy token", [s for _, s, _ in ordered] == ["grok-cli", "auth-file"])
    check("first candidate is the live token", ordered[0][0] == live)

    stolen = candidates(
        {"email": "other@example.com", "access_token": dead},
        {"email": "user@example.com", "access_token": live},
        now,
    )
    check("a different Grok identity does not steal the CLI token", [s for _, s, _ in stolen] == ["auth-file"])

    live_now = datetime.now(timezone.utc)
    check(
        "JWT exp wins over a stale expired field",
        not is_expired({"access_token": jwt(live_now + timedelta(hours=1)), "expired": "2020-01-01T00:00:00Z"}, live_now),
    )
    check(
        "expired JWT is expired even if the string says 2099",
        is_expired({"access_token": jwt(live_now - timedelta(minutes=1)), "expired": "2099-01-01T00:00:00Z"}, live_now),
    )

    print("all grok usage-sync checks passed")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
