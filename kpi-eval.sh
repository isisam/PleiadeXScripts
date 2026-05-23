#!/usr/bin/env bash
set -euo pipefail

# Pleiades maid KPI self-evaluation skeleton.
# This script gathers local evidence and writes a unified JSON report.
# It intentionally does not modify launchd plists and does not send TG/iMessage.

usage() {
  cat <<'USAGE'
Usage:
  kpi-eval.sh --maid-name <Alpha|Beta|Gamma|Delta|Epsilon|Theta|Omega> [--date YYYY-MM-DD]

Environment overrides:
  CHAT_DB          Default: ~/Library/Messages/chat.db
  M017_LOG_DIR     Default: first existing m017 log directory
  WORK_LOG_DIR     Default: ~/Library/CloudStorage/Dropbox/PleiadesMaids/Obsidian/AiNoteSystem/LTCWork/Records/WorkRecord
  DASHBOARD_FILE   Default: ~/Library/CloudStorage/Dropbox/PleiadesMaids/Obsidian/AiNoteSystem/LTCWork/Records/WorkRecord/Current(Xeon Dashboard).md
  PLEIADES_ROOT    Default: ~/Library/CloudStorage/Dropbox/PleiadesMaids
USAGE
}

MAID_NAME=""
REPORT_DATE="$(TZ=Asia/Taipei date +%F)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --maid-name)
      MAID_NAME="${2:-}"
      shift 2
      ;;
    --date)
      REPORT_DATE="${2:-}"
      shift 2
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

if [[ -z "$MAID_NAME" ]]; then
  echo "--maid-name is required" >&2
  usage >&2
  exit 2
fi

case "$MAID_NAME" in
  Alpha) DISPLAY_NAME="Alpha"; ROLE="lead" ;;
  Beta) DISPLAY_NAME="Kana"; ROLE="member" ;;
  Gamma) DISPLAY_NAME="Remi"; ROLE="member" ;;
  Delta) DISPLAY_NAME="Shion"; ROLE="member" ;;
  Epsilon) DISPLAY_NAME="Epsilon"; ROLE="member" ;;
  Theta) DISPLAY_NAME="Theta"; ROLE="member" ;;
  Omega) DISPLAY_NAME="Kanade"; ROLE="member" ;;
  *)
    echo "Invalid maid name: $MAID_NAME" >&2
    echo "Expected one of: Alpha, Beta, Gamma, Delta, Epsilon, Theta, Omega" >&2
    exit 2
    ;;
esac

HOME_DIR="${HOME:-/Users/Alpha}"
PLEIADES_ROOT="${PLEIADES_ROOT:-$HOME_DIR/Library/CloudStorage/Dropbox/PleiadesMaids}"
CHAT_DB="${CHAT_DB:-$HOME_DIR/Library/Messages/chat.db}"
WORK_LOG_DIR="${WORK_LOG_DIR:-$HOME_DIR/Library/CloudStorage/Dropbox/PleiadesMaids/Obsidian/AiNoteSystem/LTCWork/Records/WorkRecord}"
DASHBOARD_FILE="${DASHBOARD_FILE:-$WORK_LOG_DIR/Current(Xeon Dashboard).md}"
REPORT_DIR="$PLEIADES_ROOT/MaidMemory/$MAID_NAME/kpi_reports"
REPORT_PATH="$REPORT_DIR/$REPORT_DATE.json"

if [[ -z "${M017_LOG_DIR:-}" ]]; then
  if [[ -d "$HOME_DIR/Library/Logs/PleiadesMaids/m017-nightly-merge" ]]; then
    M017_LOG_DIR="$HOME_DIR/Library/Logs/PleiadesMaids/m017-nightly-merge"
  else
    M017_LOG_DIR="$PLEIADES_ROOT/Logs/m017-nightly-merge"
  fi
fi

mkdir -p "$REPORT_DIR"

export MAID_NAME DISPLAY_NAME ROLE REPORT_DATE CHAT_DB M017_LOG_DIR WORK_LOG_DIR DASHBOARD_FILE REPORT_PATH

# Python 3.10+ required for PEP 604 union type syntax (X | None)
# Try candidate interpreters in order; fall back to system python3 only if it qualifies.
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
  echo "ERROR: Python 3.10+ not found (need PEP 604 union type syntax). Install via brew: brew install python@3.12" >&2
  exit 1
fi

"$PYTHON_BIN" <<'PY'
import datetime as dt
import json
import os
import re
import sqlite3
import statistics
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Asia/Taipei")
maid_name = os.environ["MAID_NAME"]
display_name = os.environ["DISPLAY_NAME"]
role = os.environ["ROLE"]
report_date = os.environ["REPORT_DATE"]
chat_db = Path(os.environ["CHAT_DB"]).expanduser()
m017_log_dir = Path(os.environ["M017_LOG_DIR"]).expanduser()
work_log_dir = Path(os.environ["WORK_LOG_DIR"]).expanduser()
dashboard_file = Path(os.environ["DASHBOARD_FILE"]).expanduser()
report_path = Path(os.environ["REPORT_PATH"]).expanduser()

correction_keywords = ("糾正", "不對", "你說錯", "漏掉")


def day_bounds_messages_epoch(day: str) -> tuple[int, int]:
    """Return iMessage nanosecond timestamps for local Taiwan day bounds."""
    start = dt.datetime.fromisoformat(day).replace(tzinfo=TZ)
    end = start + dt.timedelta(days=1)
    apple_epoch = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
    start_ns = int((start.astimezone(dt.timezone.utc) - apple_epoch).total_seconds() * 1_000_000_000)
    end_ns = int((end.astimezone(dt.timezone.utc) - apple_epoch).total_seconds() * 1_000_000_000)
    return start_ns, end_ns


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    idx = (len(ordered) - 1) * pct
    lower = int(idx)
    upper = min(lower + 1, len(ordered) - 1)
    if lower == upper:
        return float(ordered[lower])
    return float(ordered[lower] + (ordered[upper] - ordered[lower]) * (idx - lower))


def scan_chat_db() -> tuple[str, int, float | None, float | None, list[dict]]:
    """Measure correction keywords and rough iMessage reply rhythm.

    Correction count: grep-like SQL scan against message.text for Taiwan report date.
    Response rhythm: pairs an inbound message with the next outbound message and records minutes.
    This is a skeleton estimate; production deployments should restrict handles to Master Xeon.
    """
    if not chat_db.exists():
        return "missing", 0, None, None, [{
            "source": "chat_db",
            "path": str(chat_db),
            "metric": "master_correction_count",
            "count": 0,
            "confidence": "low",
            "notes": "chat.db missing",
        }]

    try:
        start_ns, end_ns = day_bounds_messages_epoch(report_date)
        conn = sqlite3.connect(f"file:{chat_db}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT ROWID AS rowid, date, is_from_me, text
            FROM message
            WHERE date >= ? AND date < ? AND text IS NOT NULL
            ORDER BY date ASC
            """,
            (start_ns, end_ns),
        ).fetchall()
        conn.close()
    except Exception as exc:
        return "unreadable", 0, None, None, [{
            "source": "chat_db",
            "path": str(chat_db),
            "metric": "master_correction_count",
            "count": 0,
            "confidence": "low",
            "notes": f"chat.db unreadable: {exc}",
        }]

    correction_count = 0
    reply_minutes: list[float] = []
    pending_inbound_ns: int | None = None

    for row in rows:
        text = row["text"] or ""
        is_from_me = int(row["is_from_me"] or 0)
        timestamp_ns = int(row["date"] or 0)

        if any(keyword in text for keyword in correction_keywords):
            correction_count += 1

        if is_from_me == 0:
            pending_inbound_ns = timestamp_ns
        elif is_from_me == 1 and pending_inbound_ns is not None and timestamp_ns > pending_inbound_ns:
            reply_minutes.append((timestamp_ns - pending_inbound_ns) / 1_000_000_000 / 60)
            pending_inbound_ns = None

    median_reply = statistics.median(reply_minutes) if reply_minutes else None
    p95_reply = percentile(reply_minutes, 0.95)
    return "ok", correction_count, median_reply, p95_reply, [{
        "source": "chat_db",
        "path": str(chat_db),
        "metric": "master_correction_count",
        "count": correction_count,
        "confidence": "medium",
        "notes": "keyword scan: " + ",".join(correction_keywords),
    }, {
        "source": "chat_db",
        "path": str(chat_db),
        "metric": "response_rhythm",
        "count": len(reply_minutes),
        "confidence": "low",
        "notes": "rough inbound-to-next-outbound pairing; restrict handles in production",
    }]


def scan_m017_logs() -> tuple[str, int, int, int, int, list[dict]]:
    """Measure m017 attempts, successes, commit success, and TG delivery from logs.

    Attempts are counted from log lines containing m017 or nightly-merge on the report date.
    Successes are lines with common success tokens. Failures are lines with error tokens.
    TG sent/delivered counts are estimated from common TG log wording.
    """
    if not m017_log_dir.exists():
        return "missing", 0, 0, 0, 0, [{
            "source": "m017_logs",
            "path": str(m017_log_dir),
            "metric": "m017_nightly_merge",
            "count": 0,
            "confidence": "low",
            "notes": "m017 log directory missing",
        }]

    log_files = [p for p in m017_log_dir.rglob("*") if p.is_file()]
    attempt_count = 0
    success_count = 0
    tg_attempt_count = 0
    tg_success_count = 0
    error_count = 0
    date_pattern = re.compile(re.escape(report_date))

    for path in log_files:
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        for line in text.splitlines():
            if not date_pattern.search(line):
                continue
            lower = line.lower()
            if "m017" in lower or "nightly-merge" in lower:
                attempt_count += 1
            if any(token in lower for token in ("success", "completed", "commit ok", "commit success")):
                success_count += 1
            if any(token in lower for token in ("error", "failed", "exception", "traceback")):
                error_count += 1
            if "tg" in lower or "telegram" in lower:
                if any(token in lower for token in ("send", "sent", "broadcast")):
                    tg_attempt_count += 1
                if any(token in lower for token in ("delivered", "sent", "ok", "success")):
                    tg_success_count += 1

    return "ok", attempt_count, success_count, tg_attempt_count, tg_success_count, [{
        "source": "m017_logs",
        "path": str(m017_log_dir),
        "metric": "m017_nightly_merge",
        "count": attempt_count,
        "confidence": "medium",
        "notes": f"success_count={success_count}; error_count={error_count}; tg_attempt_count={tg_attempt_count}; tg_success_count={tg_success_count}",
    }]


def scan_dashboard() -> tuple[str, int, int, list[dict]]:
    """Measure dashboard sign-in by searching the current dashboard for date and maid name."""
    if not dashboard_file.exists():
        return "missing", 1, 0, [{
            "source": "dashboard",
            "path": str(dashboard_file),
            "metric": "dashboard.sign_in_rate",
            "count": 0,
            "confidence": "low",
            "notes": "dashboard file missing",
        }]
    try:
        text = dashboard_file.read_text(encoding="utf-8", errors="ignore")
    except Exception as exc:
        return "unreadable", 1, 0, [{
            "source": "dashboard",
            "path": str(dashboard_file),
            "metric": "dashboard.sign_in_rate",
            "count": 0,
            "confidence": "low",
            "notes": f"dashboard unreadable: {exc}",
        }]

    # v0.1.2 (Alpha 2026-05-24): section-aware dashboard sign-in parsing.
    # Naive substring scan was false-positive on Today:(YYYYMMDD) header and persistent
    # sub-block name. Now: find date anchor → scan its section → confirm maid sub-block
    # has actual content (✅ / [x] / HH:MM / non-empty bullet).
    dt_obj = dt.date.fromisoformat(report_date)
    date_formats = (
        report_date,                          # 2026-05-24
        dt_obj.strftime("%Y%m%d"),            # 20260524
        f"{dt_obj.month}/{dt_obj.day}",       # 5/24
        dt_obj.strftime("%m/%d"),             # 05/24
    )
    lines = text.splitlines()
    maid_block_headers = {"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Theta", "Omega",
                          "Kana", "Remi", "Shion", "Kanade", "LTC", "Xeon", "Pleiades"}
    next_section_pattern = re.compile(r"^---\s*$|^Today:\(|^\d{4}-\d{2}-\d{2}\b|^\d{8}\b")
    next_date_short = re.compile(r"^\d{1,2}/\d{1,2}\b")
    sign_in_content_pattern = re.compile(r"^\s*-\s*(✅|\[x\]|\d{1,2}:\d{2})|^\s*\d{1,2}:\d{2}|^\s*-\s+\S+")

    section_start = None
    matched_format = None
    for i, line in enumerate(lines):
        # Skip header "Today:(YYYYMMDD)" which is a pre-insert marker, not the actual section
        if line.startswith("Today:("):
            continue
        for fmt in date_formats:
            if fmt in line:
                section_start = i
                matched_format = fmt
                break
        if section_start is not None:
            break

    if section_start is None:
        return "ok", 1, 0, [{
            "source": "dashboard",
            "path": str(dashboard_file),
            "metric": "dashboard.sign_in_rate",
            "count": 0,
            "confidence": "low",
            "notes": f"no date anchor found; tried formats {date_formats}",
        }]

    section_end = len(lines)
    for j in range(section_start + 1, len(lines)):
        line = lines[j]
        if next_section_pattern.match(line):
            section_end = j
            break
        if next_date_short.match(line):
            section_end = j
            break

    actual = 0
    target_names = {maid_name, display_name}
    for j in range(section_start, section_end):
        if lines[j].strip() in target_names:
            # Found maid sub-block header; scan content until next sub-block or section end
            for k in range(j + 1, section_end):
                next_line = lines[k].strip()
                if next_line in maid_block_headers and next_line not in target_names:
                    break
                if sign_in_content_pattern.match(lines[k]):
                    actual = 1
                    break
            break

    return "ok", 1, actual, [{
        "source": "dashboard",
        "path": str(dashboard_file),
        "metric": "dashboard.sign_in_rate",
        "count": actual,
        "confidence": "medium",
        "notes": f"section-aware: date {matched_format!r} at line {section_start}, section [{section_start},{section_end})",
    }]


def scan_work_logs() -> tuple[str, list[dict]]:
    """Confirm work log availability; task-specific KPI extraction is added per workflow."""
    if not work_log_dir.exists():
        return "missing", [{
            "source": "work_logs",
            "path": str(work_log_dir),
            "metric": "work_log_availability",
            "count": 0,
            "confidence": "low",
            "notes": "work log directory missing",
        }]
    return "ok", [{
        "source": "work_logs",
        "path": str(work_log_dir),
        "metric": "work_log_availability",
        "count": 1,
        "confidence": "medium",
        "notes": "directory exists; workflow-specific parsers can be added",
    }]


def rate(success: int, total: int) -> float | None:
    return round(success / total, 4) if total > 0 else None


chat_status, correction_count, median_reply, p95_reply, chat_evidence = scan_chat_db()
m017_status, m017_attempts, m017_successes, tg_attempts, tg_successes, m017_evidence = scan_m017_logs()
dashboard_status, expected_signins, actual_signins, dashboard_evidence = scan_dashboard()
work_status, work_evidence = scan_work_logs()

violations = []
corrective_actions = []

if correction_count >= 3:
    violations.append({
        "type": "master_correction_accumulation",
        "severity": "medium",
        "metric": "response_rhythm.master_correction_count",
        "value": correction_count,
        "notes": "single-day correction count reached escalation threshold",
    })
    corrective_actions.append({
        "trigger": "master_correction_count",
        "action": "Review the 10 messages before and after each correction keyword; classify cause as misread, omission, rule conflict, stale data, tool failure, or response quality issue.",
        "owner": maid_name,
    })

if expected_signins and actual_signins < expected_signins:
    violations.append({
        "type": "dashboard_sign_in_missing",
        "severity": "low",
        "metric": "dashboard.sign_in_rate",
        "value": rate(actual_signins, expected_signins),
        "notes": "dashboard scan did not find both report date and maid/display name",
    })
    corrective_actions.append({
        "trigger": "dashboard_sign_in_rate",
        "action": "Check dashboard heading, maid name format, and sign-in schedule; record failure reason without fabricating a sign-in.",
        "owner": maid_name,
    })

if m017_attempts and m017_successes == 0:
    violations.append({
        "type": "m017_merge_success_missing",
        "severity": "high",
        "metric": "m017_nightly_merge.commit_success_rate",
        "value": 0,
        "notes": "m017 attempts found without success markers",
    })
    corrective_actions.append({
        "trigger": "m017_nightly_merge",
        "action": "Compare expected and actual merge logs; inspect Dropbox sync, file locks, commit errors, and path changes.",
        "owner": maid_name,
    })

success_rates = [
    value for value in (
        rate(m017_successes, m017_attempts),
        rate(actual_signins, expected_signins),
    )
    if value is not None
]
overall_success = round(sum(success_rates) / len(success_rates), 4) if success_rates else None

report = {
    "schema_version": "0.1",
    "report_date": report_date,
    "timezone": "Asia/Taipei",
    "maid": {
        "name": maid_name,
        "display_name": display_name,
        "role": role,
    },
    "generated_at": dt.datetime.now(TZ).replace(microsecond=0).isoformat(),
    "source_status": {
        "chat_db": chat_status,
        "m017_logs": m017_status,
        "work_logs": work_status,
        "dashboard": dashboard_status,
    },
    "kpis": {
        "mail_watchman": {
            "classification_accuracy_rate": None,
            "ad_false_positive_rate": None,
            "high_priority_miss_rate": None,
            "reviewed_total": 0,
            "errors": 0,
        },
        "m017_nightly_merge": {
            "completeness": None,
            "commit_success_rate": rate(m017_successes, m017_attempts),
            "tg_broadcast_delivery_rate": rate(tg_successes, tg_attempts),
            "attempt_count": m017_attempts,
            "success_count": m017_successes,
        },
        "dish_counting": {
            "report_accuracy_rate": None,
            "step6_missed_count": 0,
            "reviewed_total": 0,
        },
        "dashboard": {
            "sign_in_rate": rate(actual_signins, expected_signins),
            "expected_sign_ins": expected_signins,
            "actual_sign_ins": actual_signins,
        },
        "response_rhythm": {
            "median_time_to_reply_minutes": round(median_reply, 2) if median_reply is not None else None,
            "p95_time_to_reply_minutes": round(p95_reply, 2) if p95_reply is not None else None,
            "master_correction_count": correction_count,
        },
        "ad_classification": {
            "accuracy_rate": None,
            "rule_coverage_rate": None,
            "regression_error_count": 0,
        },
        "calendar": {
            "event_entry_success_rate": None,
            "timezone_accuracy_rate": None,
            "expected_event_count": 0,
            "created_event_count": 0,
        },
        "rule_compliance": {
            "compliance_rate": None,
            "no_at_no_reply_violation_count": 0,
            "canned_response_violation_count": 0,
        },
    },
    "dimensions": {
        "success_completion_rate": overall_success,
        "response_time_median_minutes": round(median_reply, 2) if median_reply is not None else None,
        "response_time_p95_minutes": round(p95_reply, 2) if p95_reply is not None else None,
        "error_misclassification_count": 0,
        "master_correction_count": correction_count,
        "rule_compliance_rate": None,
    },
    "violations": violations,
    "corrective_actions": corrective_actions,
    "evidence": chat_evidence + m017_evidence + dashboard_evidence + work_evidence,
}

report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(str(report_path))
PY
