#!/usr/bin/env python3
"""Slice the battery-sampler log by run windows and compute per-run energy.

Usage: analyze_energy.py <sampler_log> <marks.txt>

Sampler lines (phone clock):
  <epoch>|  level: 82|  voltage: 4239|  temperature: 289|  current now: -1234567|  charge counter: 4092675|
Marks lines: "START <tag> <epoch>" / "END <tag> <epoch>" / "chunks <tag> <n>"

Sign convention: current now is µA, negative while discharging. Voltage is mV,
temperature 0.1 °C, charge counter µAh (fuel-gauge coulomb counter).

Per run we report instantaneous-integral energy (Σ V·I·dt) and the coulomb-counter
delta (ΔCC·V̄) as a cross-check, plus per-token numbers vs the idle baseline.
"""
import re, sys

def parse_samples(path):
    out = []
    pat = re.compile(
        r"^(\d+)\|.*?level: (\d+)\|.*?voltage: (\d+)\|.*?temperature: (\d+)\|"
        r".*?current now: (-?\d+)\|.*?charge counter: (\d+)\|")
    for line in open(path):
        m = pat.match(line.strip())
        if m:
            t, lvl, mv, temp, ua, cc = map(int, m.groups())
            out.append(dict(t=t, level=lvl, mv=mv, temp=temp, ua=ua, cc=cc))
    return out

def parse_marks(path):
    runs, chunks = {}, {}
    for line in open(path):
        p = line.split()
        if len(p) != 3: continue
        kind, tag, val = p
        if kind == "START": runs.setdefault(tag, {})["t0"] = int(val)
        elif kind == "END": runs.setdefault(tag, {})["t1"] = int(val)
        elif kind == "chunks": chunks[tag] = int(val)
    return runs, chunks

def window(samples, t0, t1):
    return [s for s in samples if t0 <= s["t"] <= t1]

def energy(ws):
    """Integrate V*I over the window; return (joules, avg_W, dcc_joules)."""
    if len(ws) < 2: return None
    j = 0.0
    for a, b in zip(ws, ws[1:]):
        dt = b["t"] - a["t"]
        j += (abs(a["ua"]) * 1e-6) * (a["mv"] * 1e-3) * dt
    dur = ws[-1]["t"] - ws[0]["t"]
    avg_mv = sum(s["mv"] for s in ws) / len(ws)
    dcc_j = (ws[0]["cc"] - ws[-1]["cc"]) * 1e-6 * 3600 * (avg_mv * 1e-3)
    return dict(joules=j, avg_w=j / dur if dur else 0, dcc_joules=dcc_j, dur=dur,
                n=len(ws), t_start=ws[0]["temp"]/10, t_end=ws[-1]["temp"]/10,
                lvl0=ws[0]["level"], lvl1=ws[-1]["level"])

def main():
    samples = parse_samples(sys.argv[1])
    runs, chunks = parse_marks(sys.argv[2])
    idle_w = None
    if "idle" in runs and "t1" in runs["idle"]:
        e = energy(window(samples, runs["idle"]["t0"], runs["idle"]["t1"]))
        if e: idle_w = e["avg_w"]
    print(f"{'tag':28} {'dur':>5} {'n':>4} {'avgW':>6} {'J':>8} {'dccJ':>8} "
          f"{'tok':>5} {'J/tok':>7} {'ΔJ/tok':>7} {'temp':>10}")
    for tag, r in sorted(runs.items(), key=lambda kv: kv[1].get("t0", 0)):
        if "t0" not in r or "t1" not in r: continue
        e = energy(window(samples, r["t0"], r["t1"]))
        if not e:
            print(f"{tag:28} (no samples)"); continue
        tok = chunks.get(tag)
        jt = f"{e['joules']/tok:7.2f}" if tok else "      -"
        djt = (f"{(e['joules']-idle_w*e['dur'])/tok:7.2f}"
               if tok and idle_w is not None else "      -")
        print(f"{tag:28} {e['dur']:5d} {e['n']:4d} {e['avg_w']:6.2f} {e['joules']:8.1f} "
              f"{e['dcc_joules']:8.1f} {tok or 0:5d} {jt} {djt} "
              f"{e['t_start']:4.1f}→{e['t_end']:4.1f}")
    if idle_w is not None:
        print(f"\nidle baseline: {idle_w:.2f} W (subtracted in ΔJ/tok)")

if __name__ == "__main__":
    main()
