#!/usr/bin/env python3
"""
Autonomous meta-harness proposer.

Loop:
  1. Run baseline eval (if no recent one is cached) — captures subCheckPassRate
     per fixture / per sub-check.
  2. Identify the weakest performing sub-check group (by pass rate and by
     Bernoulli variance — ceiling & floor are noise).
  3. Select a candidate overlay from a rule-based catalog keyed on the
     failure mode.
  4. Run the candidate on the same cases as the baseline, same N replicates.
  5. Compare subCheckPassRate with a Wilson lower bound; promote if Δ > ε.
  6. Append an iteration entry to .junco/meta/history.md.
  7. Repeat until no improvement for K consecutive iterations OR max-iter hit.

The candidate catalog encodes the experiments we've hand-authored (E5 write
flag, E6 per-role retries, E7 two-phase force, plus temperature / candidateCount
sweeps). Every candidate is expressed as (env_overrides, meta_config_json,
label). The proposer can therefore run without any new code edits.

Usage:
  python3 propose.py --cases "search-mode-enum search-file-count explain-pipeline" \\
                     --reps 5 --max-iter 6

Outputs to /tmp/junco-meta-propose/ by default; can be redirected with --out.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import math
import os
import pathlib
import shutil
import subprocess
import sys
from typing import Any, Callable


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BIN = REPO_ROOT / ".build" / "arm64-apple-macosx" / "debug" / "junco-eval"
HISTORY_FILE = REPO_ROOT / ".junco" / "meta" / "history.md"


@dataclasses.dataclass
class Candidate:
    label: str
    description: str
    env: dict[str, str]           # extra environment variables
    meta_config: dict[str, Any]   # written to a META_CONFIG_JSON file


CATALOG: list[Candidate] = [
    Candidate(
        label="e5-write",
        description="E5: structural guard + write-on-validation-failure (the shipped default for hard fixtures).",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={},
    ),
    Candidate(
        label="e7-force-twophase",
        description="E7: force two-phase generation for every .swift create (skeleton-first).",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1", "JUNCO_FORCE_TWOPHASE": "1"},
        meta_config={},
    ),
    Candidate(
        label="nocvf",
        description="Disable CVF retries entirely.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={"maxValidationRetries": 0},
    ),
    Candidate(
        label="retries-model-0",
        description="Per-role retries: model → 0. Keeps other roles at default.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={"validationRetriesByRole": {"model": 0}},
    ),
    Candidate(
        label="retries-view-4",
        description="Per-role retries: view → 4. SwiftUI bodies often need more attempts.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={"validationRetriesByRole": {"view": 4}},
    ),
    Candidate(
        label="greedy-hot",
        description="codeGen temperature=0.0 (fully deterministic) + greedy sampling.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={"profileOverrides": {"codeGen": {"temperature": 0.0, "samplingStrategy": "greedy"}}},
    ),
    Candidate(
        label="candidate-5",
        description="candidateCount=5 (more compile-select slots).",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={"candidateCount": 5},
    ),
    Candidate(
        label="candidate-7",
        description="candidateCount=7.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={"candidateCount": 7},
    ),
    Candidate(
        label="lean-memory",
        description="Tighten working memory: maxObservations=1, maxErrors=1.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={"maxObservations": 1, "maxErrors": 1},
    ),
    # Template-routing hypotheses (Phase K) — service template is off by default
    # after commit 6906938; these candidates measure whether the view template
    # should follow and whether the earlier apparent service-template win was noise.
    Candidate(
        label="view-template-off",
        description="Disable the view template (default-on). Measures at N=10 whether it beats AFM's direct SwiftUI generation.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1", "JUNCO_DISABLE_TEMPLATES": "view"},
        meta_config={},
    ),
    Candidate(
        label="service-template-on",
        description="Re-enable the default-disabled service template. Control for the 83% ship finding — should regress.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1", "JUNCO_ENABLE_TEMPLATES": "service"},
        meta_config={},
    ),
    Candidate(
        label="all-templates-off",
        description="All templates off — stress-test how much AFM alone can do at N=10.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1", "JUNCO_DISABLE_TEMPLATES": "1"},
        meta_config={},
    ),
    Candidate(
        label="temp-0",
        description="codeGen temperature=0 (fully deterministic, stricter than default 0.2).",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={"profileOverrides": {"codeGen": {"temperature": 0.0}}},
    ),
    Candidate(
        label="temp-0.1",
        description="codeGen temperature=0.1 — slightly less deterministic than default.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={"profileOverrides": {"codeGen": {"temperature": 0.1}}},
    ),
    Candidate(
        label="retries-view-0",
        description="view role retries=0 — write template output as-is, skip CVF retries for views.",
        env={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={"validationRetriesByRole": {"view": 0}},
    ),
]


def wilson_lower(passed: int, total: int, z: float = 1.96) -> float:
    if total == 0:
        return 0.0
    p = passed / total
    denom = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denom
    margin = (z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total))) / denom
    return max(0.0, center - margin)


def wilson_upper(passed: int, total: int, z: float = 1.96) -> float:
    if total == 0:
        return 1.0
    p = passed / total
    denom = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denom
    margin = (z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total))) / denom
    return min(1.0, center + margin)


def run_variant(
    *,
    label: str,
    cases: list[str],
    reps: int,
    env_extra: dict[str, str],
    meta_config: dict[str, Any],
    out_dir: pathlib.Path,
) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    mc_path: str | None = None
    if meta_config:
        mc_path = str(out_dir / f"mc-{label}.json")
        with open(mc_path, "w") as f:
            json.dump(meta_config, f)

    totals = {"pass": 0, "cnt": 0, "cases_pass": 0, "cases": 0, "wall": 0.0}
    per_fixture: dict[str, list[int]] = {}

    for rep in range(1, reps + 1):
        for case in cases:
            result_path = out_dir / f"{label}-r{rep}-{case}.json"
            log_path = out_dir / f"{label}-r{rep}-{case}.log"
            # Clean any artifacts each case leaves behind
            for stale in [
                "Sources/Hello.swift", "Sources/Point.swift", "Sources/Distance.swift",
                "Sources/TrafficLight.swift", "Sources/TodoItem.swift",
                "Sources/Counter.swift", "Sources/TodoListView.swift",
                "Sources/NetworkService.swift", "Sources/Nameable.swift",
                "Sources/SimpleCache.swift", "Sources/StringListBuilder.swift",
                "Sources/Book.swift", "Sources/OldName.swift", "Sources/Light.swift",
            ]:
                p = REPO_ROOT / stale
                if p.exists():
                    p.unlink()
            env = os.environ.copy()
            env.update(env_extra)
            env["JUNCO_SUMMARY_JSON"] = str(result_path)
            if mc_path:
                env["META_CONFIG_JSON"] = mc_path
            cmd = [str(BIN), "--eval", "--destructive", "--case", case, "--report", "/dev/null"]
            with open(log_path, "w") as logf:
                subprocess.run(cmd, env=env, stdout=logf, stderr=logf, cwd=str(REPO_ROOT))

            if not result_path.exists():
                continue
            with open(result_path) as f:
                d = json.load(f)
            totals["pass"] += d.get("subCheckPassed", 0)
            totals["cnt"] += d.get("subCheckCount", 0)
            totals["cases_pass"] += d.get("succeeded", 0)
            totals["cases"] += d.get("caseCount", 0)
            totals["wall"] += d.get("totalDurationSec", 0.0)
            for c in d.get("cases", []):
                if c.get("subCheckTotal", 0) == 0:
                    continue
                per_fixture.setdefault(c["name"], [0, 0])
                per_fixture[c["name"]][0] += c["subCheckPassed"]
                per_fixture[c["name"]][1] += c["subCheckTotal"]
    return {"label": label, "totals": totals, "per_fixture": per_fixture}


def pick_weakest_fixture(per_fixture: dict[str, list[int]]) -> str | None:
    """Identify a fixture with low pass rate and enough variance to be worth iterating on."""
    scored = []
    for name, (p, t) in per_fixture.items():
        if t == 0:
            continue
        rate = p / t
        # Skip fixtures at or near 100% (no headroom) or pure 0 (likely unfixable with our knobs).
        if rate >= 0.95 or rate == 0.0:
            continue
        # Rank by how much below 1.0 (headroom) and by absolute deficit.
        scored.append((rate, t - p, name))
    scored.sort()  # lowest rate first
    return scored[0][2] if scored else None


def rank_candidates_for_fixture(fixture: str) -> list[Candidate]:
    """Rule-based: map the weakest fixture to the ranked candidates.
    Order in the label tuple IS the iteration order — cheapest / most-likely first."""
    catalog_by_label = {c.label: c for c in CATALOG}
    def pick(labels):
        return [catalog_by_label[lbl] for lbl in labels if lbl in catalog_by_label]
    f = fixture.lower()
    if "todolist" in f or ("view" in f and "network" not in f):
        return pick(["view-template-off", "retries-view-0", "retries-view-4",
                     "candidate-5", "e7-force-twophase"])
    if "todo-item" in f or "string-builder" in f:
        return pick(["retries-model-0", "temp-0", "temp-0.1", "candidate-5"])
    if "network-service" in f:
        return pick(["temp-0", "temp-0.1", "candidate-5", "candidate-7", "greedy-hot"])
    if "fix" in f:
        return pick(["retries-model-0", "nocvf", "temp-0"])
    # Default: a broad sweep in priority order.
    return pick(["temp-0", "candidate-5", "nocvf", "e7-force-twophase", "lean-memory"])


def append_history(entry: str) -> None:
    if not HISTORY_FILE.exists():
        return
    text = HISTORY_FILE.read_text()
    marker = "## Rules"
    if marker in text:
        text = text.replace(marker, entry + "\n" + marker, 1)
    else:
        text += "\n" + entry
    HISTORY_FILE.write_text(text)


def report_variant(variant: dict[str, Any]) -> str:
    t = variant["totals"]
    rate = (100 * t["pass"] / t["cnt"]) if t["cnt"] else 0.0
    cases = f"{t['cases_pass']}/{t['cases']}" if t["cases"] else "0/0"
    return f"{variant['label']}: subChecks={t['pass']}/{t['cnt']} ({rate:.1f}%) cases={cases} wall={t['wall']:.1f}s"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", type=str, default="",
                        help="Space-separated case names. Default: all hard fixtures.")
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--max-iter", type=int, default=5)
    parser.add_argument("--out", type=pathlib.Path, default=pathlib.Path("/tmp/junco-meta-propose"))
    parser.add_argument("--epsilon", type=float, default=0.06,
                        help="Min fraction improvement to promote a candidate.")
    parser.add_argument("--dry-run", action="store_true", help="Plan candidates, don't run.")
    args = parser.parse_args()

    default_cases = [
        "create-todo-item", "create-string-builder", "create-swiftui-todolist",
        "create-network-service", "fix-compile-error",
    ]
    cases = args.cases.split() if args.cases else default_cases
    print(f"Proposer: {len(cases)} cases × {args.reps} reps × up to {args.max_iter} iterations")
    args.out.mkdir(parents=True, exist_ok=True)

    # 1. Baseline — the current shipped default (E5 defaults).
    print("\n[baseline] running control arm…")
    baseline = run_variant(
        label="baseline",
        cases=cases, reps=args.reps,
        env_extra={"JUNCO_WRITE_ON_VALIDATION_FAILURE": "1"},
        meta_config={},
        out_dir=args.out / "baseline",
    )
    print(report_variant(baseline))
    best = baseline

    iter_log: list[str] = [
        f"baseline: subChecks={baseline['totals']['pass']}/{baseline['totals']['cnt']} "
        f"({100*baseline['totals']['pass']/max(1,baseline['totals']['cnt']):.1f}%)"
    ]

    tried = {"baseline"}
    for iteration in range(1, args.max_iter + 1):
        weakest = pick_weakest_fixture(best["per_fixture"])
        if weakest is None:
            print("\nNo fixture with headroom & variance — stopping.")
            break
        candidates = [c for c in rank_candidates_for_fixture(weakest) if c.label not in tried]
        if not candidates:
            print(f"\nAll candidates for '{weakest}' already tried — stopping.")
            break
        candidate = candidates[0]
        tried.add(candidate.label)
        print(f"\n[iter {iteration}] weakest='{weakest}' → trying '{candidate.label}': {candidate.description}")
        if args.dry_run:
            continue
        variant = run_variant(
            label=candidate.label, cases=cases, reps=args.reps,
            env_extra=candidate.env, meta_config=candidate.meta_config,
            out_dir=args.out / candidate.label,
        )
        print(report_variant(variant))

        bp, bt = best["totals"]["pass"], best["totals"]["cnt"]
        vp, vt = variant["totals"]["pass"], variant["totals"]["cnt"]
        b_rate = bp / bt if bt else 0
        v_rate = vp / vt if vt else 0
        delta = v_rate - b_rate
        # Wilson lower-upper overlap test.
        b_upper = wilson_upper(bp, bt)
        v_lower = wilson_lower(vp, vt)
        promoted = delta > args.epsilon and v_lower > b_upper
        iter_log.append(
            f"{candidate.label}: {vp}/{vt} ({100*v_rate:.1f}%)  Δ={100*delta:+.1f}pp  "
            f"{'✅ PROMOTED' if promoted else '—'}"
        )
        if promoted:
            print(f"→ PROMOTED ({delta*100:+.1f}pp over best, Wilson CI clear)")
            best = variant
        else:
            print(f"→ rejected (Δ={delta*100:+.1f}pp, Wilson b_upper={b_upper:.3f} v_lower={v_lower:.3f})")

    # Final summary
    print("\n=== Proposer final ===")
    print(f"Best arm: {best['label']}")
    print(report_variant(best))

    # Append history entry
    ts = dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    header = f"## Iteration ∞ — {ts} — autonomous proposer run"
    body_lines = [
        header,
        "",
        f"Cases: {', '.join(cases)} ({args.reps} reps each).",
        "",
    ] + iter_log + [
        "",
        f"**Best arm: `{best['label']}`** ({100*best['totals']['pass']/max(1,best['totals']['cnt']):.1f}%).",
    ]
    append_history("\n".join(body_lines))
    print(f"\nAppended iteration to {HISTORY_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
