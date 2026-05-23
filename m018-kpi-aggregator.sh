#!/usr/bin/env bash
set -euo pipefail

# m018-kpi-aggregator: aggregate seven maids' daily KPI reports into a weekly master report.
# Author: Alpha (with v0.3 SOP design from Codex Rescue prompt).
# Triggered by launchd every Sunday 09:00 Taiwan time (UTC Weekday=0 Hour=1).
# Output: MaidMemory/PleiadesMaidMemory/kpi_weekly/YYYY-WW.md + .json
# Side effects: optional TG broadcast to office group + iMessage alert to master.
# Dry run: set DRY_RUN=1 to skip all messaging side effects.

usage() {
  cat <<'USAGE'
Usage:
  m018-kpi-aggregator.sh [--week-ending YYYY-MM-DD] [--dry-run]

Environment overrides:
  PLEIADES_ROOT     Default: ~/Library/CloudStorage/Dropbox/PleiadesMaids
  WEEKLY_OUT_DIR    Default: $PLEIADES_ROOT/MaidMemory/PleiadesMaidMemory/kpi_weekly
  DRY_RUN           Default: 0 (set to 1 to skip TG/iMessage sends)
  OFFICE_TG_CHAT    Default: -5277171676 (PleiadesMaidOffice_Telegram)
  MASTER_IMESSAGE   Default: any;-;isisam@mac.com
USAGE
}

WEEK_ENDING=""
DRY_RUN="${DRY_RUN:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --week-ending)
      WEEK_ENDING="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$WEEK_ENDING" ]]; then
  WEEK_ENDING="$(TZ=Asia/Taipei date +%F)"
fi

HOME_DIR="${HOME:-/Users/Alpha}"
PLEIADES_ROOT="${PLEIADES_ROOT:-$HOME_DIR/Library/CloudStorage/Dropbox/PleiadesMaids}"
WEEKLY_OUT_DIR="${WEEKLY_OUT_DIR:-$PLEIADES_ROOT/MaidMemory/PleiadesMaidMemory/kpi_weekly}"
OFFICE_TG_CHAT="${OFFICE_TG_CHAT:--5277171676}"
MASTER_IMESSAGE="${MASTER_IMESSAGE:-any;-;isisam@mac.com}"

mkdir -p "$WEEKLY_OUT_DIR"

export WEEK_ENDING DRY_RUN PLEIADES_ROOT WEEKLY_OUT_DIR OFFICE_TG_CHAT MASTER_IMESSAGE

# Python 3.10+ required (same pattern as kpi-eval.sh)
PYTHON_BIN=""
for p in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$p" >/dev/null 2>&1; then
    if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      PYTHON_BIN="$p"
      break
    fi
  fi
done
if [[ -z "$PYTHON_BIN" ]]; then
  echo "ERROR: Python 3.10+ not found." >&2
  exit 1
fi

"$PYTHON_BIN" <<'PY'
import datetime as dt
import json
import os
import statistics
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Asia/Taipei")
maids = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Theta", "Omega"]
week_ending = dt.date.fromisoformat(os.environ["WEEK_ENDING"])
week_start = week_ending - dt.timedelta(days=6)
days = [week_start + dt.timedelta(days=i) for i in range(7)]
iso_year, iso_week, _ = week_ending.isocalendar()
week_id = f"{iso_year}-W{iso_week:02d}"
dry_run = os.environ.get("DRY_RUN", "0") == "1"
pleiades_root = Path(os.environ["PLEIADES_ROOT"]).expanduser()
weekly_out_dir = Path(os.environ["WEEKLY_OUT_DIR"]).expanduser()
weekly_out_dir.mkdir(parents=True, exist_ok=True)

# 1. Collect daily JSON for each maid × day
def report_path(maid: str, day: dt.date) -> Path:
    return pleiades_root / "MaidMemory" / maid / "kpi_reports" / f"{day.isoformat()}.json"

reports: dict[str, dict[str, dict | None]] = {m: {} for m in maids}
for m in maids:
    for d in days:
        p = report_path(m, d)
        if p.exists():
            try:
                reports[m][d.isoformat()] = json.loads(p.read_text(encoding="utf-8"))
            except Exception as exc:
                reports[m][d.isoformat()] = {"_error": str(exc)}
        else:
            reports[m][d.isoformat()] = None

# 2. Per-maid weekly aggregates
def safe_get(d: dict | None, *keys, default=None):
    if not d:
        return default
    cur = d
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur if cur is not None else default

def trend_decline(values: list[float | None], threshold: float = 0.20) -> bool:
    """Return True if last 3 non-null values strictly decline, each drop > threshold."""
    non_null = [v for v in values if v is not None]
    if len(non_null) < 3:
        return False
    last3 = non_null[-3:]
    for i in range(1, 3):
        prev, cur = last3[i-1], last3[i]
        if prev <= 0:
            return False
        if cur >= prev * (1 - threshold):
            return False
    return True

maid_summary: dict[str, dict] = {}
high_priority_alerts: list[dict] = []

for m in maids:
    daily = reports[m]
    days_with_report = [d.isoformat() for d in days if daily.get(d.isoformat()) and "_error" not in (daily[d.isoformat()] or {})]
    days_missing = [d.isoformat() for d in days if not daily.get(d.isoformat())]

    sign_in_series = [safe_get(daily[d.isoformat()], "kpis", "dashboard", "sign_in_rate") for d in days]
    sign_in_rates = [v for v in sign_in_series if v is not None]
    sign_in_avg = round(sum(sign_in_rates) / len(sign_in_rates), 4) if sign_in_rates else None

    corrections_series = [safe_get(daily[d.isoformat()], "kpis", "response_rhythm", "master_correction_count", default=0) for d in days]
    corrections_total = sum(c for c in corrections_series if isinstance(c, int))

    canned_series = [safe_get(daily[d.isoformat()], "kpis", "rule_compliance", "canned_response_violation_count", default=0) for d in days]
    canned_total = sum(c for c in canned_series if isinstance(c, int))

    no_at_series = [safe_get(daily[d.isoformat()], "kpis", "rule_compliance", "no_at_no_reply_violation_count", default=0) for d in days]
    no_at_total = sum(c for c in no_at_series if isinstance(c, int))

    median_reply_series = [safe_get(daily[d.isoformat()], "kpis", "response_rhythm", "median_time_to_reply_minutes") for d in days]
    median_reply_vals = [v for v in median_reply_series if isinstance(v, (int, float))]
    median_reply_overall = round(statistics.median(median_reply_vals), 2) if median_reply_vals else None

    sign_in_declining = trend_decline(sign_in_series)

    # Per-maid alert escalation
    maid_alerts = []
    if corrections_total >= 10:
        maid_alerts.append({"severity": "high", "type": "master_correction_weekly_threshold", "value": corrections_total})
    if canned_total >= 10:
        maid_alerts.append({"severity": "high", "type": "canned_response_weekly_threshold", "value": canned_total})
    if sign_in_declining:
        maid_alerts.append({"severity": "medium", "type": "sign_in_rate_declining_3_days", "value": sign_in_series})
    if len(days_missing) >= 4:
        maid_alerts.append({"severity": "medium", "type": "missing_daily_reports", "value": days_missing})

    maid_summary[m] = {
        "days_reported": len(days_with_report),
        "days_missing": days_missing,
        "sign_in_rate_avg": sign_in_avg,
        "sign_in_rate_series": sign_in_series,
        "master_correction_total": corrections_total,
        "canned_response_total": canned_total,
        "no_at_no_reply_total": no_at_total,
        "median_reply_minutes_overall": median_reply_overall,
        "alerts": maid_alerts,
    }
    for a in maid_alerts:
        if a["severity"] == "high":
            high_priority_alerts.append({"maid": m, **a})

# 3. Compose weekly master report (markdown + json)
md_lines: list[str] = []
md_lines.append(f"# Pleiades Weekly KPI Report — {week_id}")
md_lines.append("")
md_lines.append(f"- Week window: **{week_start.isoformat()} → {week_ending.isoformat()}** (Taiwan UTC+8)")
md_lines.append(f"- Generated: {dt.datetime.now(TZ).replace(microsecond=0).isoformat()}")
md_lines.append(f"- Schema version: 0.3")
md_lines.append(f"- Dry run: **{dry_run}**")
md_lines.append("")

if high_priority_alerts:
    md_lines.append("## 🚨 High-Priority Alerts")
    md_lines.append("")
    for a in high_priority_alerts:
        md_lines.append(f"- **{a['maid']}** / {a['type']} = {a['value']}")
    md_lines.append("")
else:
    md_lines.append("## ✅ No High-Priority Alerts This Week")
    md_lines.append("")

md_lines.append("## Per-Maid Summary")
md_lines.append("")
md_lines.append("| Maid | Days Reported | Sign-in Avg | Corrections | Canned | No-@ Violations | Alerts |")
md_lines.append("|------|---------------|-------------|-------------|--------|-----------------|--------|")
for m in maids:
    s = maid_summary[m]
    sign_in_str = f"{s['sign_in_rate_avg']:.2f}" if s['sign_in_rate_avg'] is not None else "n/a"
    alerts_str = ", ".join(a["type"] for a in s["alerts"]) or "—"
    md_lines.append(
        f"| {m} | {s['days_reported']}/7 | {sign_in_str} | {s['master_correction_total']} | "
        f"{s['canned_response_total']} | {s['no_at_no_reply_total']} | {alerts_str} |"
    )
md_lines.append("")

md_lines.append("## Missing Reports")
md_lines.append("")
any_missing = False
for m in maids:
    missing = maid_summary[m]["days_missing"]
    if missing:
        any_missing = True
        md_lines.append(f"- **{m}**: {', '.join(missing)}")
if not any_missing:
    md_lines.append("(none)")
md_lines.append("")

md_lines.append("## Recommended Actions")
md_lines.append("")
if high_priority_alerts:
    for a in high_priority_alerts:
        md_lines.append(f"- {a['maid']} / {a['type']}: investigate root cause; reference SOP §7 (Improvement Feedback Loop).")
else:
    md_lines.append("- Continue baseline collection; review again next Sunday.")
md_lines.append("")

md_lines.append("## Source")
md_lines.append("")
md_lines.append("Generated by `m018-kpi-aggregator.sh`. See SOP `maid_kpi_evaluation_sop.md` for definitions.")
md_lines.append("")

md_text = "\n".join(md_lines)
weekly_md_path = weekly_out_dir / f"{week_id}.md"
weekly_md_path.write_text(md_text, encoding="utf-8")

weekly_json = {
    "schema_version": "0.3",
    "week_id": week_id,
    "week_start": week_start.isoformat(),
    "week_ending": week_ending.isoformat(),
    "generated_at": dt.datetime.now(TZ).replace(microsecond=0).isoformat(),
    "dry_run": dry_run,
    "maids": maid_summary,
    "high_priority_alerts": high_priority_alerts,
}
weekly_json_path = weekly_out_dir / f"{week_id}.json"
weekly_json_path.write_text(json.dumps(weekly_json, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print(f"Weekly markdown: {weekly_md_path}")
print(f"Weekly JSON: {weekly_json_path}")

# 4. Optional TG broadcast + iMessage alert (skipped on dry_run)
office_tg = os.environ.get("OFFICE_TG_CHAT", "-5277171676")
master_imessage = os.environ.get("MASTER_IMESSAGE", "any;-;isisam@mac.com")

summary_short = (
    f"📊 KPI Weekly {week_id}\n"
    f"Window {week_start.isoformat()}→{week_ending.isoformat()}\n"
    f"High-priority alerts: {len(high_priority_alerts)}\n"
    f"Report: {weekly_md_path}"
)

if dry_run:
    print("[DRY_RUN] would broadcast to TG office group:")
    print(summary_short)
    if high_priority_alerts:
        print("[DRY_RUN] would iMessage master with high-priority list")
    sys.exit(0)

# Production: send via tmux send-keys to existing maid session (real transport not wired in v0.3 skeleton)
# v0.4 will wire to imessage/telegram MCP clients or hermes_bridge.
print("[INFO] non-dry-run requested but transport not wired in v0.3 skeleton; persisted artifacts only.")
PY
