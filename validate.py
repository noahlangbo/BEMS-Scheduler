"""
validate.py
===========
Pre-scheduling checks. Thresholds are config-driven ("availability_requirements"
in config.json) so the code always matches what the current form asked for.

  - Ambulance EMTs: minimum number of weekday day shifts / nights / weekend
    shifts selected, plus enough total available hours to reach the block
    requirement.
  - BERT members: minimum A/B and C/D block selections.
  - Per-slot availability summary so personnel can spot thin days up front.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import date

from models import SHIFT_HOURS, BertMember, Volunteer, is_weekend, shift_types_for


@dataclass
class AvailabilityRequirements:
    emt_min_day_shifts: int = 2      # weekday AM/PM selections
    emt_min_night_shifts: int = 1    # NIGHT selections (any day)
    emt_min_weekend_shifts: int = 1  # weekend DAY or NIGHT selections
    bert_min_ab_blocks: int = 1      # A or B selections
    bert_min_cd_blocks: int = 1      # C or D selections
    # Optional separate categories. None preserves historical config behavior.
    emt_min_weekday_am: int | None = None
    emt_min_weekday_pm: int | None = None
    emt_min_weekday_night: int | None = None
    emt_min_weekend_day: int | None = None
    emt_min_weekend_night: int | None = None

    @classmethod
    def from_config(cls, cfg: dict) -> "AvailabilityRequirements":
        raw = cfg.get("availability_requirements") or {}
        emt = raw.get("ambulance") or {}
        bert = raw.get("bert") or {}
        return cls(
            emt_min_day_shifts=int(emt.get("min_day_shifts", 2)),
            emt_min_night_shifts=int(emt.get("min_night_shifts", 1)),
            emt_min_weekend_shifts=int(emt.get("min_weekend_shifts", 1)),
            bert_min_ab_blocks=int(bert.get("min_ab_blocks", 1)),
            bert_min_cd_blocks=int(bert.get("min_cd_blocks", 1)),
            **{
                "emt_" + key: int(emt[key]) if key in emt else None
                for key in ("min_weekday_am", "min_weekday_pm", "min_weekday_night",
                            "min_weekend_day", "min_weekend_night")
            },
        )


def check_ambulance_requirements(
    volunteers: list[Volunteer], reqs: AvailabilityRequirements
) -> list[dict]:
    """Volunteers whose submitted availability falls short of the form's minimums."""
    violations = []
    for v in volunteers:
        day = sum(1 for (d, s) in v.available if s in ("AM", "PM"))
        night = sum(1 for (d, s) in v.available if s == "NIGHT")
        weekend = sum(1 for (d, s) in v.available if is_weekend(d))
        missing = []
        if day < reqs.emt_min_day_shifts:
            missing.append(f"weekday day shifts ({day}/{reqs.emt_min_day_shifts})")
        if night < reqs.emt_min_night_shifts:
            missing.append(f"night shifts ({night}/{reqs.emt_min_night_shifts})")
        if weekend < reqs.emt_min_weekend_shifts:
            missing.append(f"weekend shifts ({weekend}/{reqs.emt_min_weekend_shifts})")
        # Availability policy differs from calendar weekends: Friday/Saturday
        # NIGHT are weekend nights; Sunday NIGHT is a weekday night.
        separate = (
            ("Weekday AM", reqs.emt_min_weekday_am,
             sum(d.weekday() < 5 and s == "AM" for d, s in v.available)),
            ("Weekday PM", reqs.emt_min_weekday_pm,
             sum(d.weekday() < 5 and s == "PM" for d, s in v.available)),
            ("Weekday NIGHT", reqs.emt_min_weekday_night,
             sum(d.weekday() not in (4, 5) and s == "NIGHT" for d, s in v.available)),
            ("Weekend DAY", reqs.emt_min_weekend_day,
             sum(d.weekday() in (5, 6) and s == "DAY" for d, s in v.available)),
            ("Weekend NIGHT", reqs.emt_min_weekend_night,
             sum(d.weekday() in (4, 5) and s == "NIGHT" for d, s in v.available)),
        )
        for label, minimum, count in separate:
            if minimum is not None and count < minimum:
                missing.append(f"{label} ({count}/{minimum})")
        if missing:
            violations.append({"volunteer": v, "missing": missing})
    return violations


def check_bert_requirements(
    bert_members: list[BertMember], reqs: AvailabilityRequirements
) -> list[dict]:
    violations = []
    for b in bert_members:
        ab = sum(1 for (_, blk) in b.campus_available if blk in ("A", "B"))
        cd = sum(1 for (_, blk) in b.campus_available if blk in ("C", "D"))
        missing = []
        if ab < reqs.bert_min_ab_blocks:
            missing.append(f"A/B blocks ({ab}/{reqs.bert_min_ab_blocks})")
        if cd < reqs.bert_min_cd_blocks:
            missing.append(f"C/D blocks ({cd}/{reqs.bert_min_cd_blocks})")
        if missing:
            violations.append({"volunteer": b, "missing": missing})
    return violations


def check_total_available_hours(volunteers: list[Volunteer], min_hours: int) -> list[dict]:
    """EMTs who cannot possibly reach the hour requirement with what they submitted."""
    warnings = []
    for v in volunteers:
        total = sum(SHIFT_HOURS[s] for (_, s) in v.available)
        if total < min_hours:
            warnings.append({"volunteer": v, "total_hours": total})
    return warnings


# ── Printing ─────────────────────────────────────────────────────────────────

def print_strike_list(violations: list[dict], title: str) -> None:
    print("\n" + "=" * 60)
    print(f"STRIKE LIST — {title}")
    print("=" * 60)
    if not violations:
        print("  ✓ Everyone met the minimum availability requirements.")
        return
    print(f"  {len(violations)} member(s) short of requirements:\n")
    for item in violations:
        v = item["volunteer"]
        print(f"  • {v.full_name:<28} Missing: {', '.join(item['missing'])}")
    print()


def print_hours_warnings(warnings: list[dict], min_hours: int) -> None:
    if not warnings:
        return
    print("\n" + "=" * 60)
    print(f"LOW AVAILABILITY — TOTAL SUBMITTED HOURS < {min_hours}")
    print("=" * 60)
    for item in warnings:
        v = item["volunteer"]
        print(f"  • {v.full_name:<28} Only {item['total_hours']}h of availability submitted")
    print()


def print_availability_summary(
    volunteers: list[Volunteer],
    schedule_dates: list[date],
    blackout_slots: set | None = None,
) -> None:
    blackout_slots = blackout_slots or set()
    counts: dict = defaultdict(int)
    evdt_counts: dict = defaultdict(int)
    for v in volunteers:
        for key in v.available:
            if key in blackout_slots:
                continue
            counts[key] += 1
            if v.is_evdt:
                evdt_counts[key] += 1

    print("\n" + "=" * 60)
    print("AVAILABILITY SUMMARY (volunteers available per slot)")
    print("=" * 60)
    for d in schedule_dates:
        for s in shift_types_for(d):
            n = counts.get((d, s), 0)
            e = evdt_counts.get((d, s), 0)
            flag = " ⚠ LOW" if n < 2 else ""
            print(f"  {d.isoformat()} ({d.strftime('%a')}) {s:<6}  {n:>2} available  ({e} EVDT){flag}")
    print()
