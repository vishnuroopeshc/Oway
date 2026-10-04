#!/usr/bin/env python3
"""Replay a realistic human walk into an Android emulator's GPS.

Walks the real OSM route from SR Comfort PG (Arekere) to Royal Meenakshi
Mall, feeding fixes via `adb emu geo fix`, with human-like behaviour:
variable pace, GPS jitter, waiting at a signal, a U-turn, a side-street
detour, and a single GPS outlier spike.

Usage (start a walk in the app first, then):
    python3 tool/walk_sim/simulate_walk.py [--interval 0.7] [--seed 7]

Run it twice: on the 1st walk the route should be mostly GOLD (re-walked
stretches GREEN); on the 2nd walk it should be almost entirely GREEN.
"""

import argparse
import json
import math
import os
import random
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
M_PER_DEG_LAT = 111320.0


class Route:
    """A polyline addressable by distance along it, in meters."""

    def __init__(self, lon_lat):
        self.lat0 = lon_lat[0][1]
        self.m_per_deg_lon = M_PER_DEG_LAT * math.cos(math.radians(self.lat0))
        self.xy = [self._to_xy(lon, lat) for lon, lat in lon_lat]
        self.cum = [0.0]
        for a, b in zip(self.xy, self.xy[1:]):
            self.cum.append(self.cum[-1] + math.dist(a, b))
        self.length = self.cum[-1]

    def _to_xy(self, lon, lat):
        return (lon * self.m_per_deg_lon, lat * M_PER_DEG_LAT)

    def to_lon_lat(self, x, y):
        return (x / self.m_per_deg_lon, y / M_PER_DEG_LAT)

    def at(self, s):
        """(x, y) point and unit direction at distance s along the route."""
        s = max(0.0, min(s, self.length))
        i = 1
        while i < len(self.cum) - 1 and self.cum[i] < s:
            i += 1
        a, b = self.xy[i - 1], self.xy[i]
        seg = self.cum[i] - self.cum[i - 1] or 1e-9
        t = (s - self.cum[i - 1]) / seg
        d = ((b[0] - a[0]) / seg, (b[1] - a[1]) / seg)
        return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t), d


def build_plan(route, rng):
    """List of (phase_label, expected_colour, x, y) fixes."""
    plan = []
    s = 0.0

    def jitter(p, sigma):
        return (p[0] + rng.gauss(0, sigma), p[1] + rng.gauss(0, sigma))

    def walk_to(target, label, expect, sigma=2.5):
        nonlocal s
        direction = 1 if target >= s else -1
        while (target - s) * direction > 0:
            step = rng.uniform(3.5, 7.5)  # pace + GPS interval variance
            s = s + direction * step
            if (target - s) * direction < 0:
                s = target
            p, _ = route.at(s)
            plan.append((label, expect, *jitter(p, sigma)))

    def stand(n, label, expect, sigma=3.0):
        p, _ = route.at(s)
        for _ in range(n):
            plan.append((label, expect, *jitter(p, sigma)))

    def detour(length, label_out, label_back):
        p, d = route.at(s)
        normal = (-d[1], d[0])
        steps = int(length / 5)
        out = [
            (p[0] + normal[0] * 5 * k, p[1] + normal[1] * 5 * k)
            for k in range(1, steps + 1)
        ]
        for q in out:
            plan.append((label_out, "GOLD", *jitter(q, 2.0)))
        for q in reversed(out[:-1]):
            plan.append((label_back, "GREEN", *jitter(q, 2.0)))
        plan.append((label_back, "GREEN", *jitter(p, 2.0)))

    def outlier(offset):
        p, d = route.at(s)
        normal = (-d[1], d[0])
        plan.append(("GPS outlier spike", "no flip", p[0] + normal[0] * offset,
                     p[1] + normal[1] * offset))

    L = route.length
    stand(3, "Leaving the PG", "GOLD")
    walk_to(0.27 * L, "Walking to the signal", "GOLD")
    stand(8, "Waiting at the signal", "GOLD", sigma=4.0)
    walk_to(0.48 * L, "Walking on", "GOLD")
    walk_to(0.42 * L, "U-turn: forgot something, walking back", "GREEN")
    walk_to(0.48 * L, "Turning again over the same stretch", "GREEN")
    walk_to(0.68 * L, "Fresh stretch", "GOLD")
    detour(60, "Side-street detour (out)", "Side-street detour (back)")
    walk_to(0.80 * L, "Back on the main road", "GOLD")
    outlier(40)
    walk_to(L, "Last stretch to the mall", "GOLD")
    stand(4, "Arrived at Royal Meenakshi Mall", "GOLD")
    return plan


def geo_fix(route, x, y):
    lon, lat = route.to_lon_lat(x, y)
    subprocess.run(
        [ADB, "-s", "emulator-5554", "emu", "geo", "fix", f"{lon:.7f}",
         f"{lat:.7f}"],
        check=True, capture_output=True,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=0.7,
                    help="real seconds between fixes")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with open(os.path.join(HERE, "route_arekere_to_meenakshi.json")) as f:
        route = Route(json.load(f)["coordinates_lon_lat"])
    plan = build_plan(route, random.Random(args.seed))
    print(f"Route {route.length:.0f} m, {len(plan)} fixes, "
          f"~{len(plan) * args.interval / 60:.1f} min")

    last_label = None
    for i, (label, expect, x, y) in enumerate(plan):
        if label != last_label:
            print(f"[{i:4d}] {label}  (expect {expect})", flush=True)
            last_label = label
        if not args.dry_run:
            geo_fix(route, x, y)
            time.sleep(args.interval)
    print("Done. Tap Stop in the app.")


if __name__ == "__main__":
    main()
