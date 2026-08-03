#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import math
import re
import statistics
from bisect import bisect_left
from datetime import datetime
from pathlib import Path


GC_PREFIX = "HXCPP_GC_TIMELINE,"
GC_HEADER_PREFIX = "HXCPP_GC_TIMELINE_HEADER,"
CENSUS_SUMMARY_PREFIX = "HXCPP_GC_CENSUS_SUMMARY,"
CENSUS_CLASS_PREFIX = "HXCPP_GC_CENSUS_CLASS,"
CENSUS_RAW_SMALL_PREFIX = "HXCPP_GC_CENSUS_RAW_SMALL,"
CENSUS_RAW_LARGE_PREFIX = "HXCPP_GC_CENSUS_RAW_LARGE,"
RETENTION_BEGIN_PREFIX = "HXCPP_GC_RETENTION_TRACE_BEGIN,"
RETENTION_PATH_PREFIX = "HXCPP_GC_RETENTION_PATH,"
RETENTION_END_PREFIX = "HXCPP_GC_RETENTION_TRACE_END,"
LOG_TIMESTAMP = re.compile(r"\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\]")
FLOOR_FRACTION = re.compile(r"floor (\d+)/(\d+)")


def load_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def number(row: dict[str, str], key: str, default: float = 0.0) -> float:
    try:
        return float(row.get(key, default))
    except (TypeError, ValueError):
        return default


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] * (upper - position) + ordered[upper] * (position - lower)


def robust_growth(values: list[float], duration_minutes: float) -> tuple[float, float]:
    if len(values) < 2 or duration_minutes <= 0:
        return 0.0, 0.0
    window = max(1, len(values) // 10)
    start = statistics.median(values[:window])
    end = statistics.median(values[-window:])
    return end - start, (end - start) / duration_minutes


def nearest_row(rows: list[dict[str, str]], times: list[float], elapsed: float) -> dict[str, str] | None:
    if not rows:
        return None
    index = bisect_left(times, elapsed)
    candidates = []
    if index < len(rows):
        candidates.append(rows[index])
    if index:
        candidates.append(rows[index - 1])
    return min(candidates, key=lambda row: abs(number(row, "elapsed_sec") - elapsed))


def parse_gc_log(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    header: list[str] = []
    rows: list[dict[str, str]] = []
    if not path.exists():
        return header, rows

    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            header_at = line.find(GC_HEADER_PREFIX)
            if header_at >= 0:
                header = next(csv.reader([line[header_at + len(GC_HEADER_PREFIX) :].strip()]))
                continue
            data_at = line.find(GC_PREFIX)
            if data_at >= 0 and header:
                values = next(csv.reader([line[data_at + len(GC_PREFIX) :].strip()]))
                if len(values) == len(header):
                    rows.append(dict(zip(header, values)))
    return header, rows


def load_session(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def parse_game_events(path: Path, started_at: str) -> list[dict[str, str]]:
    if not path.exists() or not started_at:
        return []
    start = datetime.fromisoformat(started_at)
    events: list[dict[str, str]] = []
    current_floor = ""

    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            timestamp_match = LOG_TIMESTAMP.search(line)
            if not timestamp_match:
                continue
            timestamp = datetime.fromisoformat(timestamp_match.group(1)).replace(tzinfo=start.tzinfo)
            elapsed = (timestamp - start).total_seconds()

            if "Welcome (" in line and " to the dungeon " in line:
                floor_match = FLOOR_FRACTION.search(line)
                if floor_match:
                    current_floor = floor_match.group(1)
                    events.append(
                        {
                            "elapsed_sec": f"{elapsed:.6f}",
                            "type": "floor_start",
                            "floor": current_floor,
                            "label": f"Entrée floor {current_floor}/{floor_match.group(2)}",
                        }
                    )
            elif "destroy DistributedDungeonFloor" in line:
                events.append(
                    {
                        "elapsed_sec": f"{elapsed:.6f}",
                        "type": "floor_destroy",
                        "floor": current_floor,
                        "label": f"Destruction floor {current_floor}" if current_floor else "Destruction floor",
                    }
                )
            elif "finished the dungeon" in line:
                floor_match = FLOOR_FRACTION.search(line)
                floor = floor_match.group(1) if floor_match else current_floor
                events.append(
                    {
                        "elapsed_sec": f"{elapsed:.6f}",
                        "type": "dungeon_finish",
                        "floor": floor,
                        "label": f"Fin du donjon au floor {floor}" if floor else "Fin du donjon",
                    }
                )
            elif "MAIN STATE MACHINE TRANSITION -- " in line:
                transition = line.split("MAIN STATE MACHINE TRANSITION -- ", 1)[1].strip()
                events.append(
                    {
                        "elapsed_sec": f"{elapsed:.6f}",
                        "type": "state",
                        "floor": current_floor,
                        "label": transition,
                    }
                )

    return events


def parse_census_log(
    path: Path,
) -> tuple[list[dict[str, str]], list[dict[str, str]], list[dict[str, str]]]:
    summaries: list[dict[str, str]] = []
    classes: list[dict[str, str]] = []
    raw_sizes: list[dict[str, str]] = []
    if not path.exists():
        return summaries, classes, raw_sizes

    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            at = line.find(CENSUS_SUMMARY_PREFIX)
            if at >= 0:
                values = line[at + len(CENSUS_SUMMARY_PREFIX) :].strip().split(",")
                if len(values) == 9:
                    summaries.append(
                        dict(
                            zip(
                                [
                                    "gc_seq",
                                    "elapsed_ms",
                                    "object_count",
                                    "object_bytes",
                                    "raw_small_count",
                                    "raw_small_bytes",
                                    "raw_large_count",
                                    "raw_large_bytes",
                                    "external_large_bytes",
                                ],
                                values,
                            )
                        )
                    )
                continue

            at = line.find(CENSUS_CLASS_PREFIX)
            if at >= 0:
                values = line[at + len(CENSUS_CLASS_PREFIX) :].strip().split(",", 3)
                if len(values) == 4:
                    classes.append(
                        {
                            "gc_seq": values[0],
                            "count": values[1],
                            "bytes": values[2],
                            "class": values[3],
                        }
                    )
                continue

            for prefix, kind in (
                (CENSUS_RAW_SMALL_PREFIX, "small"),
                (CENSUS_RAW_LARGE_PREFIX, "large"),
            ):
                at = line.find(prefix)
                if at >= 0:
                    values = line[at + len(prefix) :].strip().split(",")
                    if len(values) == 4:
                        raw_sizes.append(
                            {
                                "gc_seq": values[0],
                                "kind": kind,
                                "size_bytes": values[1],
                                "count": values[2],
                                "bytes": values[3],
                            }
                        )
                    break

    return summaries, classes, raw_sizes


def parse_retention_log(path: Path) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    summaries: list[dict[str, str]] = []
    paths: list[dict[str, str]] = []
    current_seq = ""
    current_class = ""
    if not path.exists():
        return summaries, paths

    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            at = line.find(RETENTION_BEGIN_PREFIX)
            if at >= 0:
                values = line[at + len(RETENTION_BEGIN_PREFIX) :].strip().split(",", 1)
                if len(values) == 2:
                    current_seq, current_class = values
                continue

            at = line.find(RETENTION_PATH_PREFIX)
            if at >= 0 and current_seq:
                values = next(
                    csv.reader([line[at + len(RETENTION_PATH_PREFIX) :].strip()])
                )
                if len(values) >= 2:
                    try:
                        int(values[0])
                    except ValueError:
                        continue
                    paths.append(
                        {
                            "gc_seq": current_seq,
                            "class": current_class,
                            "count": values[0],
                            "path": ",".join(values[1:]),
                        }
                    )
                continue

            at = line.find(RETENTION_END_PREFIX)
            if at >= 0:
                values = line[at + len(RETENTION_END_PREFIX) :].strip().split(",")
                if len(values) == 6:
                    summaries.append(
                        dict(
                            zip(
                                [
                                    "gc_seq",
                                    "class",
                                    "matched_objects",
                                    "recorded_unique_paths",
                                    "printed_paths",
                                    "unrecorded_matches",
                                ],
                                values,
                            )
                        )
                    )
                current_seq = ""
                current_class = ""

    return summaries, paths


def write_rows(path: Path, rows: list[dict[str, str]]) -> None:
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def mb(value: float) -> float:
    return value / (1024 * 1024)


def kib_to_mb(value: float) -> float:
    return value / 1024


def phase_summary(gc_rows: list[dict[str, str]]) -> str:
    phase_names = [
        ("sync_ms", "synchronisation des threads"),
        ("mark_ms", "marquage du graphe vivant"),
        ("reclaim_ms", "récupération des blocs"),
        ("large_sweep_ms", "balayage des grosses allocations"),
        ("defrag_ms", "défragmentation"),
        ("finalize_ms", "finalisation/préparation"),
        ("resume_ms", "reprise des threads"),
    ]
    totals = [(sum(number(row, field) for row in gc_rows), label) for field, label in phase_names]
    totals.sort(reverse=True)
    if not totals or totals[0][0] <= 0:
        return "indéterminée"
    return f"{totals[0][1]} ({totals[0][0]:.1f} ms cumulées)"


def make_svg(path: Path, memory_rows: list[dict[str, str]], gc_rows: list[dict[str, str]]) -> None:
    if len(memory_rows) < 2:
        return
    width, height = 1200, 620
    left, right, top, bottom = 85, 30, 35, 65
    plot_width = width - left - right
    plot_height = height - top - bottom
    end_time = max(number(row, "elapsed_sec") for row in memory_rows)
    if end_time <= 0:
        return

    series = [
        ("RSS", "#e45756", [(number(r, "elapsed_sec"), kib_to_mb(number(r, "rss_kb"))) for r in memory_rows]),
        ("PSS", "#f58518", [(number(r, "elapsed_sec"), kib_to_mb(number(r, "pss_kb"))) for r in memory_rows]),
    ]
    if gc_rows:
        series.extend(
            [
                (
                    "tas hxcpp vivant",
                    "#4c78a8",
                    [(number(r, "elapsed_ms") / 1000, mb(number(r, "after_usage_bytes"))) for r in gc_rows],
                ),
                (
                    "tas hxcpp réservé",
                    "#54a24b",
                    [(number(r, "elapsed_ms") / 1000, mb(number(r, "after_reserved_bytes"))) for r in gc_rows],
                ),
            ]
        )
    max_memory = max((value for _, _, points in series for _, value in points), default=1)
    max_memory = max(max_memory, 1)
    max_stall = max((number(row, "stall_ms") for row in gc_rows), default=1)
    max_stall = max(max_stall, 1)

    def x(value: float) -> float:
        return left + value / end_time * plot_width

    def y_memory(value: float) -> float:
        return top + plot_height - value / max_memory * plot_height

    def y_stall(value: float) -> float:
        return top + plot_height - value / max_stall * plot_height

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#101418"/>',
        f'<line x1="{left}" y1="{top + plot_height}" x2="{left + plot_width}" y2="{top + plot_height}" stroke="#89929b"/>',
        f'<line x1="{left}" y1="{top}" x2="{left}" y2="{top + plot_height}" stroke="#89929b"/>',
        f'<text x="{left}" y="22" fill="#e8eaed" font-family="sans-serif" font-size="16">Mémoire et pauses GC au fil de la session</text>',
        f'<text x="15" y="{top + 15}" fill="#c7cdd3" font-family="sans-serif" font-size="12">{max_memory:.0f} MiB</text>',
        f'<text x="20" y="{top + plot_height}" fill="#c7cdd3" font-family="sans-serif" font-size="12">0 MiB</text>',
        f'<text x="{left + plot_width - 90}" y="{top + plot_height + 35}" fill="#c7cdd3" font-family="sans-serif" font-size="12">{end_time / 60:.1f} min</text>',
    ]

    for label, color, points in series:
        coordinates = " ".join(f"{x(px):.1f},{y_memory(py):.1f}" for px, py in points)
        lines.append(f'<polyline points="{coordinates}" fill="none" stroke="{color}" stroke-width="2"/>')

    for row in gc_rows:
        px = x(number(row, "elapsed_ms") / 1000)
        py = y_stall(number(row, "stall_ms"))
        lines.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="1.8" fill="#b279a2" opacity="0.75"/>')

    legend_x = left + 10
    legend_y = top + 20
    for index, (label, color, _) in enumerate(series + [("pause GC (échelle relative)", "#b279a2", [])]):
        y_pos = legend_y + index * 20
        lines.append(f'<line x1="{legend_x}" y1="{y_pos}" x2="{legend_x + 22}" y2="{y_pos}" stroke="{color}" stroke-width="3"/>')
        lines.append(f'<text x="{legend_x + 30}" y="{y_pos + 4}" fill="#e8eaed" font-family="sans-serif" font-size="12">{label}</text>')

    lines.append("</svg>")
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze a DRH GC diagnostic session")
    parser.add_argument("session_directory", type=Path)
    args = parser.parse_args()
    session_dir = args.session_directory.resolve()

    session = load_session(session_dir / "session.txt")
    memory_rows = load_csv(session_dir / "memory.csv")
    events = load_csv(session_dir / "events.csv")
    header, gc_rows = parse_gc_log(session_dir / "game.log")
    game_events = parse_game_events(session_dir / "game.log", session.get("started_at", ""))
    census_summaries, census_classes, census_raw_sizes = parse_census_log(session_dir / "game.log")
    retention_summaries, retention_paths = parse_retention_log(session_dir / "game.log")

    if header and gc_rows:
        write_rows(session_dir / "gc_timeline.csv", gc_rows)
    write_rows(session_dir / "game_events.csv", game_events)
    write_rows(session_dir / "gc_census_summary.csv", census_summaries)
    write_rows(session_dir / "gc_census_classes.csv", census_classes)
    write_rows(session_dir / "gc_census_raw_sizes.csv", census_raw_sizes)
    write_rows(session_dir / "gc_retention_summary.csv", retention_summaries)
    write_rows(session_dir / "gc_retention_paths.csv", retention_paths)

    duration_sec = max(
        [number(row, "elapsed_sec") for row in memory_rows]
        + [number(row, "elapsed_ms") / 1000 for row in gc_rows]
        + [0.0]
    )
    duration_minutes = duration_sec / 60

    report: list[str] = ["# Analyse de la session GC", ""]
    report.append(f"- Durée mesurée : {duration_minutes:.1f} min")
    report.append(f"- Échantillons système : {len(memory_rows)}")
    report.append(f"- Collections instrumentées : {len(gc_rows)}")
    report.append(f"- Marqueurs utilisateur : {len(events)}")
    report.append(f"- Événements de jeu détectés : {len(game_events)}")
    report.append(f"- Recensements du tas : {len(census_summaries)}")
    report.append(f"- Traces de rétention : {len(retention_summaries)}")

    if memory_rows:
        rss = [kib_to_mb(number(row, "rss_kb")) for row in memory_rows]
        pss = [kib_to_mb(number(row, "pss_kb")) for row in memory_rows]
        anon = [kib_to_mb(number(row, "rss_anon_kb")) for row in memory_rows]
        process_vram = [kib_to_mb(number(row, "process_vram_kb")) for row in memory_rows]
        global_vram = [kib_to_mb(number(row, "global_vram_used_kb")) for row in memory_rows]
        rss_growth, rss_rate = robust_growth(rss, duration_minutes)
        pss_growth, pss_rate = robust_growth(pss, duration_minutes)
        anon_growth, anon_rate = robust_growth(anon, duration_minutes)
        process_vram_growth, _ = robust_growth(process_vram, duration_minutes)
        global_vram_growth, _ = robust_growth(global_vram, duration_minutes)

        report.extend(
            [
                "",
                "## Mémoire du processus",
                "",
                f"- RSS : {rss[0]:.1f} → {rss[-1]:.1f} MiB, pic {max(rss):.1f} MiB",
                f"- Croissance RSS robuste : {rss_growth:+.1f} MiB ({rss_rate:+.1f} MiB/min)",
                f"- Croissance PSS robuste : {pss_growth:+.1f} MiB ({pss_rate:+.1f} MiB/min)",
                f"- Croissance anonyme robuste : {anon_growth:+.1f} MiB ({anon_rate:+.1f} MiB/min)",
                f"- Croissance VRAM attribuée au processus : {process_vram_growth:+.1f} MiB",
                f"- Croissance VRAM globale : {global_vram_growth:+.1f} MiB",
            ]
        )

    if gc_rows:
        stalls = [number(row, "stall_ms") for row in gc_rows]
        usage = [mb(number(row, "after_usage_bytes")) for row in gc_rows]
        reserved = [mb(number(row, "after_reserved_bytes")) for row in gc_rows]
        large = [mb(number(row, "large_bytes")) for row in gc_rows]
        heap_growth, heap_rate = robust_growth(usage, duration_minutes)
        reserved_growth, reserved_rate = robust_growth(reserved, duration_minutes)
        large_growth, large_rate = robust_growth(large, duration_minutes)
        total_stall = sum(stalls)
        split_large = "large_gc_bytes" in gc_rows[0]
        reclaimed = [
            max(0.0, mb(number(row, "before_usage_bytes") - number(row, "after_usage_bytes")))
            for row in gc_rows
        ]

        report.extend(
            [
                "",
                "## Tas hxcpp et collectes",
                "",
                f"- Tas vivant après GC : {usage[0]:.1f} → {usage[-1]:.1f} MiB, pic {max(usage):.1f} MiB",
                f"- Croissance robuste du vivant : {heap_growth:+.1f} MiB ({heap_rate:+.1f} MiB/min)",
                f"- Tas réservé : {reserved[0]:.1f} → {reserved[-1]:.1f} MiB ({reserved_rate:+.1f} MiB/min)",
                f"- Grosses allocations hxcpp : {large[0]:.1f} → {large[-1]:.1f} MiB ({large_rate:+.1f} MiB/min)",
                f"- Temps GC cumulé instrumenté : {total_stall:.1f} ms ({total_stall / max(duration_sec * 10, 1):.3f} %)",
                f"- Pause médiane / p95 / maximum : {statistics.median(stalls):.2f} / {percentile(stalls, 0.95):.2f} / {max(stalls):.2f} ms",
                f"- Phase dominante cumulée : {phase_summary(gc_rows)}",
                f"- Mémoire temporaire récupérée par GC, médiane / p95 / maximum : "
                f"{statistics.median(reclaimed):.1f} / {percentile(reclaimed, 0.95):.1f} / {max(reclaimed):.1f} MiB",
            ]
        )
        if split_large:
            gc_large = [mb(number(row, "large_gc_bytes")) for row in gc_rows]
            external_large = [mb(number(row, "large_external_bytes")) for row in gc_rows]
            report.append(
                f"- Grosses allocations suivies par le GC : {gc_large[0]:.1f} → {gc_large[-1]:.1f} MiB ; "
                f"mémoire native déclarée au GC : {external_large[0]:.1f} → {external_large[-1]:.1f} MiB"
            )

        if "mode" in gc_rows[0]:
            report.extend(["", "### Modes de collecte", ""])
            report.append("| Mode | GC | temps cumulé | pause médiane | p95 | max | marquage cumulé |")
            report.append("|---|---:|---:|---:|---:|---:|---:|")
            for mode in ("gen", "std"):
                subset = [row for row in gc_rows if row.get("mode") == mode]
                if not subset:
                    continue
                subset_stalls = [number(row, "stall_ms") for row in subset]
                subset_marks = [number(row, "mark_ms") for row in subset]
                report.append(
                    f"| `{mode}` | {len(subset)} | {sum(subset_stalls):.1f} ms | "
                    f"{statistics.median(subset_stalls):.2f} ms | "
                    f"{percentile(subset_stalls, 0.95):.2f} ms | {max(subset_stalls):.2f} ms | "
                    f"{sum(subset_marks):.1f} ms |"
                )

            remembered = [
                number(row, "remembered_set")
                for row in gc_rows
                if row.get("mode") == "gen"
            ]
            if remembered:
                report.append(
                    f"- Remembered set des collectes générationnelles, médiane / p95 / maximum : "
                    f"{statistics.median(remembered):.0f} / {percentile(remembered, 0.95):.0f} / "
                    f"{max(remembered):.0f} références"
                )

        memory_times = [number(row, "elapsed_sec") for row in memory_rows]
        gaps: list[float] = []
        if memory_rows:
            for row in gc_rows:
                system_row = nearest_row(memory_rows, memory_times, number(row, "elapsed_ms") / 1000)
                if system_row is not None:
                    gaps.append(kib_to_mb(number(system_row, "rss_kb")) - mb(number(row, "after_reserved_bytes")))
        if gaps:
            gap_growth, gap_rate = robust_growth(gaps, duration_minutes)
            report.append(
                f"- Écart RSS − tas hxcpp réservé : {gaps[0]:.1f} → {gaps[-1]:.1f} MiB "
                f"({gap_growth:+.1f} MiB, {gap_rate:+.1f} MiB/min)"
            )

        report.extend(["", "### Évolution par quart temporel", ""])
        report.append("| Quart | GC | GC/min | pause médiane | p95 | max | tas vivant fin |")
        report.append("|---|---:|---:|---:|---:|---:|---:|")
        for quarter in range(4):
            start = duration_sec * quarter / 4
            end = duration_sec * (quarter + 1) / 4
            subset = [
                row
                for row in gc_rows
                if start <= number(row, "elapsed_ms") / 1000 <= end
            ]
            if subset:
                subset_stalls = [number(row, "stall_ms") for row in subset]
                report.append(
                    f"| {quarter + 1} | {len(subset)} | {len(subset) / max(duration_minutes / 4, 0.001):.2f} | "
                    f"{statistics.median(subset_stalls):.2f} ms | "
                    f"{percentile(subset_stalls, 0.95):.2f} ms | {max(subset_stalls):.2f} ms | "
                    f"{mb(number(subset[-1], 'after_usage_bytes')):.1f} MiB |"
                )
            else:
                report.append(f"| {quarter + 1} | 0 | 0 | — | — | — | — |")

        floor_starts = [event for event in game_events if event.get("type") == "floor_start"]
        floor_destroys = {
            event.get("floor", ""): event
            for event in game_events
            if event.get("type") == "floor_destroy" and event.get("floor")
        }
        if floor_starts:
            report.extend(["", "### Évolution par floor détecté dans les logs", ""])
            report.append("| Floor | Durée | GC | vivant min | vivant fin | 1er GC après destruction | RSS fin |")
            report.append("|---:|---:|---:|---:|---:|---:|---:|")
            memory_times = [number(row, "elapsed_sec") for row in memory_rows]
            for index, event in enumerate(floor_starts):
                floor = event.get("floor", "")
                start = number(event, "elapsed_sec")
                destroy = floor_destroys.get(floor)
                if destroy:
                    end = number(destroy, "elapsed_sec")
                elif index + 1 < len(floor_starts):
                    end = number(floor_starts[index + 1], "elapsed_sec")
                else:
                    end = duration_sec

                subset = [
                    row
                    for row in gc_rows
                    if start <= number(row, "elapsed_ms") / 1000 <= end
                ]
                live_values = [mb(number(row, "after_usage_bytes")) for row in subset]
                live_min = f"{min(live_values):.1f} MiB" if live_values else "—"
                live_end = f"{live_values[-1]:.1f} MiB" if live_values else "—"
                post_destroy = "—"
                if destroy:
                    after = [
                        row
                        for row in gc_rows
                        if number(row, "elapsed_ms") / 1000 >= number(destroy, "elapsed_sec")
                    ]
                    if after:
                        post_destroy = f"{mb(number(after[0], 'after_usage_bytes')):.1f} MiB"

                rss_end = "—"
                if memory_rows:
                    system_row = nearest_row(memory_rows, memory_times, end)
                    if system_row:
                        rss_end = f"{kib_to_mb(number(system_row, 'rss_kb')):.1f} MiB"
                report.append(
                    f"| {floor} | {(end - start):.1f} s | {len(subset)} | {live_min} | {live_end} | "
                    f"{post_destroy} | {rss_end} |"
                )

        slowest = sorted(gc_rows, key=lambda row: number(row, "stall_ms"), reverse=True)[:10]
        report.extend(["", "### Dix pauses les plus longues", ""])
        mode_column = "Mode | " if "mode" in gc_rows[0] else ""
        mode_separator = "---| " if "mode" in gc_rows[0] else ""
        report.append(f"| Temps | Pause | {mode_column}Cause | Scan complet | Marquage | Récupération | Tas vivant |")
        report.append(f"|---:|---:|{mode_separator}---|---:|---:|---:|---:|")
        for row in slowest:
            mode_value = f"`{row.get('mode', '')}` | " if "mode" in gc_rows[0] else ""
            report.append(
                f"| {number(row, 'elapsed_ms') / 60000:.2f} min | {number(row, 'stall_ms'):.2f} ms | "
                f"{mode_value}{row.get('cause', '')} | {row.get('full_scan', '')} | {number(row, 'mark_ms'):.2f} ms | "
                f"{number(row, 'reclaim_ms'):.2f} ms | {mb(number(row, 'after_usage_bytes')):.1f} MiB |"
            )

    if census_summaries:
        first_summary = census_summaries[0]
        last_summary = census_summaries[-1]
        first_seq = first_summary.get("gc_seq", "")
        last_seq = last_summary.get("gc_seq", "")
        report.extend(["", "## Recensement des survivants", ""])
        report.append(
            f"- Objets (taille superficielle) : {int(number(first_summary, 'object_count')):,} / "
            f"{mb(number(first_summary, 'object_bytes')):.1f} MiB → "
            f"{int(number(last_summary, 'object_count')):,} / {mb(number(last_summary, 'object_bytes')):.1f} MiB"
        )
        report.append(
            f"- Buffers bruts < 4 Kio : {int(number(first_summary, 'raw_small_count')):,} / "
            f"{mb(number(first_summary, 'raw_small_bytes')):.1f} MiB → "
            f"{int(number(last_summary, 'raw_small_count')):,} / {mb(number(last_summary, 'raw_small_bytes')):.1f} MiB"
        )
        report.append(
            f"- Buffers bruts ≥ 4 Kio : {int(number(first_summary, 'raw_large_count')):,} / "
            f"{mb(number(first_summary, 'raw_large_bytes')):.1f} MiB → "
            f"{int(number(last_summary, 'raw_large_count')):,} / {mb(number(last_summary, 'raw_large_bytes')):.1f} MiB"
        )
        report.append(
            f"- Mémoire native déclarée au GC : {mb(number(first_summary, 'external_large_bytes')):.1f} → "
            f"{mb(number(last_summary, 'external_large_bytes')):.1f} MiB"
        )

        class_snapshots: dict[str, dict[str, tuple[int, int]]] = {}
        for row in census_classes:
            seq = row.get("gc_seq", "")
            name = row.get("class", "")
            previous = class_snapshots.setdefault(seq, {}).get(name, (0, 0))
            class_snapshots[seq][name] = (
                previous[0] + int(number(row, "count")),
                previous[1] + int(number(row, "bytes")),
            )
        first_classes = class_snapshots.get(first_seq, {})
        last_classes = class_snapshots.get(last_seq, {})
        class_growth = []
        for name in set(first_classes) | set(last_classes):
            first_count, first_bytes = first_classes.get(name, (0, 0))
            last_count, last_bytes = last_classes.get(name, (0, 0))
            class_growth.append(
                (last_count - first_count, last_bytes - first_bytes, name, first_count, last_count)
            )
        top_classes = [row for row in sorted(class_growth, reverse=True) if row[0] > 0][:20]
        if top_classes:
            report.extend(["", "### Classes dont le nombre de survivants augmente le plus", ""])
            report.append("| Classe | Nombre initial | Nombre final | Δ nombre | Δ taille superficielle |")
            report.append("|---|---:|---:|---:|---:|")
            for count_delta, bytes_delta, name, first_count, last_count in top_classes:
                report.append(
                    f"| `{name}` | {first_count:,} | {last_count:,} | {count_delta:+,} | {mb(bytes_delta):+.2f} MiB |"
                )

        raw_snapshots: dict[str, dict[tuple[str, int], tuple[int, int]]] = {}
        for row in census_raw_sizes:
            seq = row.get("gc_seq", "")
            key = (row.get("kind", ""), int(number(row, "size_bytes")))
            raw_snapshots.setdefault(seq, {})[key] = (
                int(number(row, "count")),
                int(number(row, "bytes")),
            )
        first_raw = raw_snapshots.get(first_seq, {})
        last_raw = raw_snapshots.get(last_seq, {})
        raw_growth = []
        for key in set(first_raw) | set(last_raw):
            first_count, first_bytes = first_raw.get(key, (0, 0))
            last_count, last_bytes = last_raw.get(key, (0, 0))
            raw_growth.append(
                (last_bytes - first_bytes, last_count - first_count, key, first_count, last_count)
            )
        top_raw = [row for row in sorted(raw_growth, reverse=True) if row[0] > 0][:20]
        if top_raw:
            report.extend(["", "### Tailles de buffers qui retiennent le plus de mémoire supplémentaire", ""])
            report.append("| Type | Taille unitaire | Nombre initial | Nombre final | Δ mémoire |")
            report.append("|---|---:|---:|---:|---:|")
            for bytes_delta, _, (kind, size), first_count, last_count in top_raw:
                report.append(
                    f"| {kind} | {size:,} o | {first_count:,} | {last_count:,} | {mb(bytes_delta):+.2f} MiB |"
                )

    if retention_summaries:
        report.extend(["", "## Trace de rétention", ""])
        paths_by_trace: dict[tuple[str, str], list[dict[str, str]]] = {}
        for row in retention_paths:
            paths_by_trace.setdefault(
                (row.get("gc_seq", ""), row.get("class", "")), []
            ).append(row)

        for summary in retention_summaries:
            seq = summary.get("gc_seq", "")
            class_name = summary.get("class", "")
            report.append(
                f"- Collection {seq}, `{class_name}` : "
                f"{int(number(summary, 'matched_objects')):,} objets atteints, "
                f"{int(number(summary, 'recorded_unique_paths')):,} chemins distincts mémorisés, "
                f"{int(number(summary, 'unrecorded_matches')):,} occurrences non mémorisées."
            )
            trace_paths = sorted(
                paths_by_trace.get((seq, class_name), []),
                key=lambda row: int(number(row, "count")),
                reverse=True,
            )[:20]
            if trace_paths:
                report.extend(
                    [
                        "",
                        "| Occurrences | Chemin depuis la racine GC |",
                        "|---:|---|",
                    ]
                )
                for row in trace_paths:
                    display_path = row.get("path", "").replace(",", " → ").replace("|", "\\|")
                    report.append(
                        f"| {int(number(row, 'count')):,} | `{display_path}` |"
                    )
                report.append("")

    if events:
        report.extend(["", "## Marqueurs", ""])
        for event in events:
            report.append(f"- {number(event, 'elapsed_sec') / 60:.2f} min — {event.get('label', '')}")

    if not gc_rows:
        report.extend(
            [
                "",
                "> Aucune ligne HXCPP_GC_TIMELINE n’a été trouvée. Vérifier que le binaire de diagnostic a bien été utilisé.",
            ]
        )

    report_path = session_dir / "analysis.md"
    report_path.write_text("\n".join(report) + "\n", encoding="utf-8")
    make_svg(session_dir / "timeline.svg", memory_rows, gc_rows)
    print("\n".join(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
