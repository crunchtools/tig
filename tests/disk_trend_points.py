#!/usr/bin/env python3
"""Line protocol for the disk-time-to-full test: 24 hours of `disk` points.

Four filesystems, each ending with 70 GiB free:

  /step     flat, then one 5 GiB step two hours ago (an image pull)
  /stopped  1.5 GiB per hour until eight hours ago, flat since
  /leak     1 GiB per hour for the whole day
  /flat     no change

On the 6-hour rate alone /step is full in about 84 hours; on the 24-hour rate
in about 336. /stopped is the reverse: full in about 70 hours on the 24-hour
rate, not growing at all on the 6-hour one. Only /leak is under 168 hours on
both.
"""
import sys
import time

GIB = 1024**3
TOTAL = 150 * GIB
USED_NOW = 80 * GIB
STEP_SIZE = 5 * GIB
STEP_AGE_HOURS = 2
LEAK_PER_HOUR = 1 * GIB
STOPPED_PER_HOUR = 1.5 * GIB
STOPPED_AGE_HOURS = 8
STEP_SECONDS = 300
POINTS = 24 * 3600 // STEP_SECONDS


def used(path: str, age_hours: float) -> float:
    """Bytes used on `path` at a point `age_hours` before now."""
    if path == "/step":
        return USED_NOW if age_hours <= STEP_AGE_HOURS else USED_NOW - STEP_SIZE
    if path == "/stopped":
        return USED_NOW - max(age_hours - STOPPED_AGE_HOURS, 0) * STOPPED_PER_HOUR
    if path == "/leak":
        return USED_NOW - age_hours * LEAK_PER_HOUR
    return USED_NOW


def main() -> None:
    now = int(sys.argv[1]) if len(sys.argv) > 1 else int(time.time())
    for path in ("/step", "/stopped", "/leak", "/flat"):
        for index in range(POINTS + 1):
            age = index * STEP_SECONDS
            value = int(used(path, age / 3600))
            print(f"disk,host=test,path={path} used={value}i,free={TOTAL - value}i {now - age}")


if __name__ == "__main__":
    main()
