#!/usr/bin/python3
"""Telegraf exec input: OpenRouter spend and tokens, by model and by API key.

Usage: openrouter_usage.py

Reads OPENROUTER_MANAGEMENT_KEY from the environment. Each agent has its own
OpenRouter key, so "by key" is "by agent". Three reads, one line-protocol
block (RT #1544):

    openrouter_usage,model=google/gemini-2.5-flash,key=josui cost=0.42,requests=310i,...
    openrouter_key,key=josui usage_daily=0.05,usage_monthly=3.1,...
    openrouter_credits total_credits=50,total_usage=12.3,balance=37.7
    openrouter_collector up=1i

openrouter_usage comes from POST /analytics/query, the source behind the
activity page: the last DAYS UTC days, one point per model, key and day,
stamped at that day's UTC midnight. A re-run writes the same series and
timestamp, so a day's figure is replaced as it settles rather than counted
twice. openrouter_key (/keys) and openrouter_credits (/credits) are the
running totals right now, for "today" and the balance.

The management key can create and delete keys, so it is sent only in the
Authorization header and never printed. A failed read goes to stderr as its
kind only and turns openrouter_collector up=0; the exit status is always 0, so
one bad read does not blank the rest.
"""

import http.client
import json
import os
import re
import sys
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Any

API_HOST = "openrouter.ai"
API_PREFIX = "/api/v1"
KEY_ENV = "OPENROUTER_MANAGEMENT_KEY"
DAYS = 3
TIMEOUT_SECONDS = 30
HTTP_ERROR = 400
ANALYTICS_ROW_LIMIT = 10000
ISO_DATE_CHARS = len("YYYY-MM-DD")
NS_PER_SECOND = 1_000_000_000
UNSAFE_TAG_RE = re.compile(r"[^A-Za-z0-9_.:/@+-]")
NO_VALUE = "unknown"

# analytics/query metric -> (field name, is an integer count)
METRICS = {
    "total_usage": ("cost", False),
    "request_count": ("requests", True),
    "tokens_prompt": ("prompt_tokens", True),
    "tokens_completion": ("completion_tokens", True),
    "reasoning_tokens": ("reasoning_tokens", True),
}
DIMENSIONS = ("model", "api_key_id")
DAY_COLUMNS = ("date__day", "created_at__day", "date")
KEY_FIELDS = ("usage", "usage_daily", "usage_weekly", "usage_monthly", "limit_remaining")


class ReadError(Exception):
    """One OpenRouter read failed; ``kind`` is safe to print."""

    def __init__(self, kind: str) -> None:
        super().__init__(kind)
        self.kind = kind


def tag(value: object) -> str:
    """A tag value that cannot break or forge line protocol."""
    text = UNSAFE_TAG_RE.sub("_", str(value)) if value not in (None, "") else NO_VALUE
    return text or NO_VALUE


def number(value: object) -> float | None:
    """A metric as a float; the API sends some counts as strings."""
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def fields(values: dict[str, tuple[float | None, bool]]) -> str:
    """Line-protocol fields, skipping missing values; integers get the i suffix."""
    out = []
    for name, (value, is_int) in values.items():
        if value is None:
            continue
        out.append(f"{name}={int(value)}i" if is_int else f"{name}={value!r}")
    return ",".join(out)


def call(path: str, key: str, body: dict[str, object] | None = None) -> object:
    """GET (or POST ``body`` to) one API path and return the decoded JSON."""
    connection = http.client.HTTPSConnection(API_HOST, timeout=TIMEOUT_SECONDS)
    try:
        connection.request(
            "POST" if body is not None else "GET",
            API_PREFIX + path,
            body=json.dumps(body) if body is not None else None,
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        )
        response = connection.getresponse()
        payload = response.read()
    except (OSError, http.client.HTTPException):
        raise ReadError("unreachable") from None
    finally:
        connection.close()
    if response.status >= HTTP_ERROR:
        raise ReadError(f"http_{response.status}")
    try:
        return json.loads(payload)
    except ValueError:
        raise ReadError("bad_json") from None


def unwrap[T](reply: object, kind: type[T]) -> T:
    """The ``data`` member of an API reply, which must be a ``kind``."""
    inner = reply.get("data") if isinstance(reply, dict) else None
    if not isinstance(inner, kind):
        raise ReadError("bad_shape")
    return inner


def day_stamp(value: object) -> int | None:
    """Nanoseconds at the UTC midnight starting the day ``value`` names."""
    if not isinstance(value, str) or len(value) < ISO_DATE_CHARS:
        return None
    try:
        day = datetime.strptime(value[:ISO_DATE_CHARS], "%Y-%m-%d").replace(tzinfo=UTC)
    except ValueError:
        return None
    return int(day.timestamp()) * NS_PER_SECOND


def query_body(now: datetime) -> dict[str, object]:
    """The analytics query: DAYS whole UTC days up to now, model by key by day."""
    start = (now - timedelta(days=DAYS - 1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return {
        "metrics": list(METRICS),
        "dimensions": list(DIMENSIONS),
        "granularity": "day",
        "limit": ANALYTICS_ROW_LIMIT,
        "time_range": {
            "start": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "end": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
    }


def usage_lines(reply: object) -> list[str]:
    """openrouter_usage points from an analytics/query reply."""
    result: dict[str, Any] = unwrap(reply, dict)
    rows = result.get("data")
    if not isinstance(rows, list):
        raise ReadError("bad_shape")
    if (result.get("metadata") or {}).get("truncated"):
        print("openrouter_usage: analytics reply truncated", file=sys.stderr)
    lines = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        stamp = next((day_stamp(row[c]) for c in DAY_COLUMNS if c in row), None)
        values = {field: (number(row.get(m)), is_int) for m, (field, is_int) in METRICS.items()}
        body = fields(values)
        if stamp is None or not body:
            continue
        tags = f"model={tag(row.get('model'))},key={tag(row.get('api_key_id'))}"
        lines.append(f"openrouter_usage,{tags} {body} {stamp}")
    return lines


def key_lines(reply: object) -> list[str]:
    """openrouter_key points from a /keys reply, one per key."""
    lines = []
    for entry in unwrap(reply, list):
        if not isinstance(entry, dict):
            continue
        body = fields({name: (number(entry.get(name)), False) for name in KEY_FIELDS})
        if body:
            lines.append(f"openrouter_key,key={tag(entry.get('name') or entry.get('label'))} {body}")
    return lines


def credit_lines(reply: object) -> list[str]:
    """The openrouter_credits point from a /credits reply."""
    credits: dict[str, Any] = unwrap(reply, dict)
    total, used = (number(credits.get(name)) for name in ("total_credits", "total_usage"))
    if total is None or used is None:
        return []
    values = {"total_credits": total, "total_usage": used, "balance": total - used}
    return ["openrouter_credits " + ",".join(f"{k}={v!r}" for k, v in values.items())]


def main() -> int:
    key = os.environ.get(KEY_ENV, "").strip()
    if not key:
        print(f"openrouter_usage: {KEY_ENV} is not set", file=sys.stderr)
        print("openrouter_collector up=0i")
        return 0
    now = datetime.now(UTC)
    reads: tuple[tuple[str, Callable[[], list[str]]], ...] = (
        ("analytics", lambda: usage_lines(call("/analytics/query", key, query_body(now)))),
        ("keys", lambda: key_lines(call("/keys", key))),
        ("credits", lambda: credit_lines(call("/credits", key))),
    )
    up = 1
    for name, read in reads:
        try:
            for line in read():
                print(line)
        except ReadError as exc:
            print(f"openrouter_usage: {name} failed: {exc.kind}", file=sys.stderr)
            up = 0
    print(f"openrouter_collector up={up}i")
    return 0


if __name__ == "__main__":
    sys.exit(main())
