#!/usr/bin/env python3
"""Shape statistics + current-rule pass rates for touch recordings.

Usage:
  python3 scripts/analyze_touchlog.py                 # all files in the app's touchlog folder
  python3 scripts/analyze_touchlog.py file.jsonl ...  # specific recordings

Recordings come from the app menu 防误触 → 录制触点数据. The file name prefix says
what the person was doing, which sets what the numbers SHOULD look like:
  1-pen       pen only, palm lifted      → pen-shaped ≈100%, finger/palm ≈0
  2-palm      palm only                  → pen-shaped 0, finger pairs 0
  3-write     normal writing, palm down  → pen strokes only from pen-shaped contacts
  4-finger    one finger writing         → finger-shaped high (only matters in finger mode)
  5-twofinger two-finger drag / pinch    → "two-finger frames accepted" ≈100%

The thresholds below MIRROR the Swift code; if you change them there, change
them here (and the other way round):
  PalmRejector.classify / isFingerShaped / isClearlyPalm  (PalmRejection.swift)
  handleTwoFingerGesture start rule `pos.y > 0.06`        (BoardTab.swift)
"""
import glob
import json
import os
import sys

# --- mirror of the Swift rules -------------------------------------------
PEN_MAX_SIZE = 0.5
PEN_MAX_MAJOR = 8.0          # default of penMaxMajor; `-`/`=` adjust it in the app
FINGER_SIZE = (0.45, 1.3)
FINGER_MAX_MAJOR = 11.0
FINGER_MAX_RATIO = 1.3
PALM_MIN_MAJOR = 12.0        # isClearlyPalm: major > 12 or size > 1.5
PALM_MIN_SIZE = 1.5
GESTURE_MIN_Y = 0.06
MATCH_RADIUS = 0.08          # NSTouch ↔ MultitouchSupport contact matching
MT_MIN_SIZE = 0.05           # MultitouchBridge drops smaller contacts


def is_pen(m): return m["size"] <= PEN_MAX_SIZE and m["maj"] <= PEN_MAX_MAJOR
def is_finger(m):
    return (FINGER_SIZE[0] <= m["size"] <= FINGER_SIZE[1] and m["maj"] <= FINGER_MAX_MAJOR
            and m["maj"] / max(m["min"], 0.1) <= FINGER_MAX_RATIO)
def is_clear_palm(m): return m["maj"] > PALM_MIN_MAJOR or m["size"] > PALM_MIN_SIZE


def frames(path):
    """Yields (time, active touches, {touch id: matched MT contact})."""
    latest = []
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            if r["type"] == "mt":
                latest = [c for c in r["c"] if c["size"] > MT_MIN_SIZE]
            elif r["type"] == "ns":
                active = [t for t in r["touches"] if not t["resting"]]
                shapes = {}
                for t in active:
                    if not latest:
                        continue
                    m = min(latest, key=lambda c: (c["x"] - t["x"]) ** 2 + (c["y"] - t["y"]) ** 2)
                    if (m["x"] - t["x"]) ** 2 + (m["y"] - t["y"]) ** 2 < MATCH_RADIUS ** 2:
                        shapes[t["id"]] = m
                yield r["t"], active, shapes


def pct(values, ps=(1, 5, 25, 50, 75, 95, 99)):
    if not values:
        return "-"
    v = sorted(values)
    return "  ".join(f"p{p}={v[min(len(v) - 1, int(p / 100 * len(v)))]:.2f}" for p in ps)


def analyze(path):
    contacts, pair_frames, pair_ok, active_frames, unmatched = [], 0, 0, 0, 0
    for _, active, shapes in frames(path):
        if active:
            active_frames += 1
        for t in active:
            if t["id"] in shapes:
                contacts.append((shapes[t["id"]], t["y"]))
            else:
                unmatched += 1
        if len(active) == 2:
            pair_frames += 1
            if all(t["id"] in shapes and is_finger(shapes[t["id"]]) and t["y"] > GESTURE_MIN_Y for t in active):
                pair_ok += 1

    n = len(contacts) or 1
    share = lambda fn: 100 * sum(fn(m) for m, _ in contacts) / n
    print(f"\n=== {os.path.basename(path)}")
    print(f"frames with contact {active_frames}, matched contact samples {len(contacts)}, unmatched {unmatched}")
    print(f"  size   {pct([m['size'] for m, _ in contacts])}")
    print(f"  major  {pct([m['maj'] for m, _ in contacts])}  (mm)")
    print(f"  minor  {pct([m['min'] for m, _ in contacts])}  (mm)")
    print(f"  ratio  {pct([m['maj'] / max(m['min'], 0.1) for m, _ in contacts])}")
    print(f"  y      {pct([y for _, y in contacts])}  (0 = bottom edge)")
    print(f"  current rules → pen-shaped {share(is_pen):.1f}%  finger-shaped {share(is_finger):.1f}%  "
          f"clearly palm {share(is_clear_palm):.1f}%")
    if pair_frames:
        print(f"  two-contact frames {pair_frames}: accepted as two-finger gesture {100 * pair_ok / pair_frames:.1f}%")


def main():
    paths = sys.argv[1:] or sorted(glob.glob(os.path.expanduser(
        "~/Library/Application Support/TrackpadStudio-Handwriting/touchlog/*.jsonl")))
    if not paths:
        sys.exit("no recordings found — record some via 防误触 → 录制触点数据")
    for p in paths:
        analyze(p)


if __name__ == "__main__":
    main()
