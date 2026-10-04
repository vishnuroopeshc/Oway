#!/usr/bin/env python3
"""Offline replay of the app's GREEN/GOLD classification for simulated walks.

Mirrors lib/screens/home_screen.dart `_onPosition` (10m node radius, 20m
session-node maturity, 2-fix flip debounce, 5m GPS distanceFilter) so each
phase of a simulated walk can be checked against its expected colour without
squinting at emulator screenshots.

    python3 tool/walk_sim/check_classification.py
"""

import json
import math
import os
import random

from simulate_walk import HERE, Route, build_plan

NODE_RADIUS = 10.0
MATURITY = 2 * NODE_RADIUS
DISTANCE_FILTER = 5.0


def sample_along(a, b):
    d = math.dist(a, b)
    if d <= NODE_RADIUS:
        return [b]
    n = math.ceil(d / NODE_RADIUS)
    return [(a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n)
            for i in range(1, n + 1)]


def explored(nodes, p, max_marker=None):
    return any(
        (max_marker is None or m <= max_marker) and math.dist(p, q) <= NODE_RADIUS
        for q, m in nodes
    )


JUMP_HOLD = 30.0  # a single fix jumping farther than this is held for one fix


def run_walk(plan, known):
    """Returns (recorded points, per-segment [(label, expect, is_new, metres)])."""
    pts, segs, session, pending = [], [], [], []
    start = (plan[0][2], plan[0][3])
    pts.append(start)
    displayed_new = not explored(known, start)
    if displayed_new:
        pending.append(start)
    streak = 0
    held = None
    accepted = []
    for label, expect, x, y in plan[1:]:
        p = (x, y)
        if held is not None:
            h, held = held, None
            if math.dist(h[2:], p) <= JUMP_HOLD:
                accepted.append(h)
        elif math.dist(pts[-1], p) > JUMP_HOLD:
            held = (label, expect, x, y)
            continue
        accepted.append((label, expect, x, y))
        while accepted:
            label_, expect_, ax, ay = accepted.pop(0)
            displayed_new, streak, pending = _process(
                (ax, ay), label_, expect_, pts, segs, known, session, pending,
                displayed_new, streak)
    return pts, segs


def _process(p, label, expect, pts, segs, known, session, pending,
             displayed_new, streak):
        if math.dist(pts[-1], p) < DISTANCE_FILTER:
            return displayed_new, streak, pending
        prev = pts[-1]
        seg = math.dist(prev, p)
        still_pending = []
        for q in pending:
            (session if math.dist(q, p) > MATURITY else still_pending).append(q)
        pending = still_pending
        raw_new = False
        for s in sample_along(prev, p):
            if not (explored(known, s) or explored([(q, 0) for q in session], s)):
                pending.append(s)
                raw_new = True
        if raw_new == displayed_new:
            streak = 0
        else:
            streak += 1
            if streak >= 2:
                displayed_new, streak = raw_new, 0
        segs.append((label, expect, displayed_new, seg))
        pts.append(p)
        return displayed_new, streak, pending


def report(title, segs):
    print(f"\n== {title}")
    order, agg = [], {}
    for label, expect, is_new, m in segs:
        if label not in agg:
            order.append(label)
            agg[label] = [expect, 0.0, 0.0]
        agg[label][1 if is_new else 2] += m
    tot_g = sum(a[1] for a in agg.values())
    tot_n = sum(a[2] for a in agg.values())
    for label in order:
        expect, gold, green = agg[label]
        print(f"  {label:42s} expect {expect:7s}  gold {gold:6.0f} m  green {green:6.0f} m")
    print(f"  {'TOTAL':42s} {'':14s}  gold {tot_g:6.0f} m  green {tot_n:6.0f} m")


def main():
    with open(os.path.join(HERE, "route_arekere_to_meenakshi.json")) as f:
        route = Route(json.load(f)["coordinates_lon_lat"])

    pts1, segs1 = run_walk(build_plan(route, random.Random(7)), [])
    report("Walk 1 (seed 7, nothing explored yet)", segs1)

    known = [(q, 0.0) for a, b in zip(pts1, pts1[1:]) for q in sample_along(a, b)]
    known.append((pts1[0], 0.0))
    _, segs2 = run_walk(build_plan(route, random.Random(11)), known)
    report("Walk 2 (seed 11, same route again)", segs2)


if __name__ == "__main__":
    main()
