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
  MAIL_ENVELOPE_INDEX Default: ~/Library/Mail/V10/MailData/Envelope Index
  CALENDAR_CACHE   Default: ~/Library/Calendars/Calendar Cache
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
MAIL_ENVELOPE_INDEX="${MAIL_ENVELOPE_INDEX:-$HOME_DIR/Library/Mail/V10/MailData/Envelope Index}"
CALENDAR_CACHE="${CALENDAR_CACHE:-$HOME_DIR/Library/Calendars/Calendar Cache}"
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

export MAID_NAME DISPLAY_NAME ROLE REPORT_DATE CHAT_DB MAIL_ENVELOPE_INDEX CALENDAR_CACHE M017_LOG_DIR WORK_LOG_DIR DASHBOARD_FILE REPORT_PATH

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
mail_envelope_index = Path(os.environ["MAIL_ENVELOPE_INDEX"]).expanduser()
calendar_cache = Path(os.environ["CALENDAR_CACHE"]).expanduser()
m017_log_dir = Path(os.environ["M017_LOG_DIR"]).expanduser()
work_log_dir = Path(os.environ["WORK_LOG_DIR"]).expanduser()
dashboard_file = Path(os.environ["DASHBOARD_FILE"]).expanduser()
report_path = Path(os.environ["REPORT_PATH"]).expanduser()

correction_keywords = ("糾正", "不對", "你說錯", "漏掉")
mail_correction_keywords = ("不是廣告", "漏掉重要信", "重要信件漏掉", "不是垃圾信")
dish_missed_keywords = ("Dorothy那邊還沒回", "Step 6漏了", "沒有回報Dorothy", "漏報")
calendar_keywords = ("行事曆", "會議", "面試", "約", "排程")
canned_phrases = (
    "會處理後回主人",
    "會核對發言者與內容後回報主人",
    "明白了主人～女僕記住了",
    "（這條是 @ 別人的，我安靜）",
    "正在處理，完成後回您",
)


def day_bounds_messages_epoch(day: str) -> tuple[int, int]:
    """Return iMessage nanosecond timestamps for local Taiwan day bounds."""
    start = dt.datetime.fromisoformat(day).replace(tzinfo=TZ)
    end = start + dt.timedelta(days=1)
    apple_epoch = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
    start_ns = int((start.astimezone(dt.timezone.utc) - apple_epoch).total_seconds() * 1_000_000_000)
    end_ns = int((end.astimezone(dt.timezone.utc) - apple_epoch).total_seconds() * 1_000_000_000)
    return start_ns, end_ns


def day_bounds_unix_epoch(day: str) -> tuple[int, int]:
    """Return Unix timestamps for local Taiwan day bounds."""
    start = dt.datetime.fromisoformat(day).replace(tzinfo=TZ)
    end = start + dt.timedelta(days=1)
    return int(start.timestamp()), int(end.timestamp())


def day_bounds_cocoa_epoch(day: str) -> tuple[float, float]:
    """Return Calendar/CoreData timestamps since 2001-01-01 UTC."""
    start = dt.datetime.fromisoformat(day).replace(tzinfo=TZ)
    end = start + dt.timedelta(days=1)
    cocoa_epoch = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
    return (
        (start.astimezone(dt.timezone.utc) - cocoa_epoch).total_seconds(),
        (end.astimezone(dt.timezone.utc) - cocoa_epoch).total_seconds(),
    )


def evidence(source: str, path: Path, metric: str, count: int, confidence: str, notes: str) -> dict:
    return {
        "source": source,
        "path": str(path),
        "metric": metric,
        "count": int(count),
        "confidence": confidence,
        "notes": notes,
    }


def fetch_chat_rows(day: str, *, chat_identifier: str | None = None, is_from_me: int | None = None) -> list[sqlite3.Row]:
    if not chat_db.exists():
        raise FileNotFoundError(f"{chat_db} missing")
    start_ns, end_ns = day_bounds_messages_epoch(day)
    conn = sqlite3.connect(f"file:{chat_db}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    params: list[object] = [start_ns, end_ns]
    joins = ""
    filters = ["message.date >= ?", "message.date < ?", "message.text IS NOT NULL"]
    if chat_identifier is not None:
        joins = "JOIN chat_message_join cmj ON cmj.message_id = message.ROWID JOIN chat ON chat.ROWID = cmj.chat_id"
        filters.append("chat.chat_identifier = ?")
        params.append(chat_identifier)
    if is_from_me is not None:
        filters.append("message.is_from_me = ?")
        params.append(is_from_me)
    rows = conn.execute(
        f"""
        SELECT message.ROWID AS rowid, message.date, message.is_from_me, message.text
        FROM message
        {joins}
        WHERE {' AND '.join(filters)}
        ORDER BY message.date ASC
        """,
        params,
    ).fetchall()
    conn.close()
    return rows


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


def scan_mail_watchman() -> tuple[str, dict, list[dict]]:
    """Measure local Mail classification signals from Envelope Index plus master corrections."""
    kpi = {
        "classification_accuracy_rate": None,
        "ad_false_positive_rate": None,
        "high_priority_miss_rate": None,
        "reviewed_total": 0,
        "errors": 0,
    }
    ev: list[dict] = []
    correction_counts = {"ad_false_positive": 0, "high_priority_miss": 0}

    try:
        rows = fetch_chat_rows(report_date)
        for row in rows:
            text = row["text"] or ""
            if any(keyword in text for keyword in ("不是廣告", "不是垃圾信")):
                correction_counts["ad_false_positive"] += 1
            if any(keyword in text for keyword in ("漏掉重要信", "重要信件漏掉")):
                correction_counts["high_priority_miss"] += 1
    except Exception as exc:
        ev.append(evidence("chat_db", chat_db, "mail_watchman.corrections", 0, "low", f"correction scan unavailable: {exc}"))

    if not mail_envelope_index.exists():
        kpi["errors"] = 1
        ev.append(evidence("mail_envelope_index", mail_envelope_index, "mail_watchman.reviewed_total", 0, "low", "Envelope Index missing"))
        return "unavailable", kpi, ev

    try:
        start_epoch, end_epoch = day_bounds_unix_epoch(report_date)
        conn = sqlite3.connect(f"file:{mail_envelope_index}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        tables = {row["name"] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
        if "messages" not in tables:
            raise RuntimeError("messages table not found")
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(messages)").fetchall()}
        if "date_received" not in columns:
            raise RuntimeError("messages.date_received column not found")

        reviewed_total = conn.execute(
            "SELECT COUNT(*) FROM messages WHERE date_received >= ? AND date_received < ?",
            (start_epoch, end_epoch),
        ).fetchone()[0]

        text_columns = [col for col in ("subject", "sender", "snippet", "summary", "to_recipients") if col in columns]
        high_priority_count = 0
        if text_columns:
            high_terms = ("重要", "urgent", "deadline", "付款", "payment", "會議", "面試", "法律", "醫療")
            where_text = " OR ".join(f"LOWER(COALESCE({col}, '')) LIKE ?" for col in text_columns for _ in high_terms)
            params = [f"%{term.lower()}%" for _col in text_columns for term in high_terms]
            high_priority_count = conn.execute(
                f"SELECT COUNT(*) FROM messages WHERE date_received >= ? AND date_received < ? AND ({where_text})",
                (start_epoch, end_epoch, *params),
            ).fetchone()[0]

        ad_count = 0
        ad_notes = "ad mailbox count unavailable from inspected schema"
        if "mailbox" in columns:
            ad_count = conn.execute(
                "SELECT COUNT(*) FROM messages WHERE date_received >= ? AND date_received < ? AND mailbox LIKE ?",
                (start_epoch, end_epoch, "%廣告%"),
            ).fetchone()[0]
            ad_notes = "messages.mailbox LIKE 廣告"
        elif "mailbox_id" in columns and "mailboxes" in tables:
            mailbox_cols = {row["name"] for row in conn.execute("PRAGMA table_info(mailboxes)").fetchall()}
            label_cols = [col for col in ("name", "display_name", "url") if col in mailbox_cols]
            if label_cols:
                label_expr = " || ' ' || ".join(f"COALESCE(mailboxes.{col}, '')" for col in label_cols)
                ad_count = conn.execute(
                    f"""
                    SELECT COUNT(*)
                    FROM messages
                    JOIN mailboxes ON mailboxes.ROWID = messages.mailbox_id
                    WHERE messages.date_received >= ? AND messages.date_received < ?
                      AND ({label_expr}) LIKE ?
                    """,
                    (start_epoch, end_epoch, "%廣告%"),
                ).fetchone()[0]
                ad_notes = "messages.mailbox_id joined to mailboxes label LIKE 廣告"
        conn.close()

        ad_false_positive = correction_counts["ad_false_positive"]
        high_priority_miss = correction_counts["high_priority_miss"]
        total_classified = ad_count
        kpi.update({
            "classification_accuracy_rate": rate(max(total_classified - ad_false_positive - high_priority_miss, 0), total_classified),
            "ad_false_positive_rate": rate(ad_false_positive, ad_count),
            "high_priority_miss_rate": rate(high_priority_miss, high_priority_count),
            "reviewed_total": int(reviewed_total),
            "errors": 0,
        })
        ev.extend([
            evidence("mail_envelope_index", mail_envelope_index, "mail_watchman.reviewed_total", reviewed_total, "medium", "date_received uses Unix epoch on macOS 26"),
            evidence("mail_envelope_index", mail_envelope_index, "mail_watchman.ad_classified_count", ad_count, "low" if ad_count == 0 else "medium", ad_notes),
            evidence("chat_db", chat_db, "mail_watchman.master_corrections", ad_false_positive + high_priority_miss, "medium", "keywords: " + ",".join(mail_correction_keywords)),
        ])
        return "ok" if ad_notes != "ad mailbox count unavailable from inspected schema" else "partial", kpi, ev
    except Exception as exc:
        kpi["errors"] = 1
        ev.append(evidence("mail_envelope_index", mail_envelope_index, "mail_watchman.errors", 1, "low", f"sqlite3 read error: {exc}"))
        return "unavailable", kpi, ev


def scan_dish_counting() -> tuple[str, dict, list[dict]]:
    """Measure Dorothy dish-counting messages against Step 6 work-log completion notes."""
    dorothy_chat_id = "any;+;1773255c981f4bcfb75e418b72987ff5"
    kpi = {"report_accuracy_rate": None, "step6_missed_count": 0, "reviewed_total": 0}
    ev: list[dict] = []
    status_parts: list[str] = []

    try:
        dorothy_rows = fetch_chat_rows(report_date, chat_identifier=dorothy_chat_id)
        dish_count = sum(1 for row in dorothy_rows if "盤子" in (row["text"] or ""))
        missed_count = 0
        all_rows = fetch_chat_rows(report_date)
        for row in all_rows:
            text = row["text"] or ""
            if any(keyword in text for keyword in dish_missed_keywords):
                missed_count += 1
        kpi["reviewed_total"] = dish_count
        kpi["step6_missed_count"] = missed_count
        ev.append(evidence("chat_db", chat_db, "dish_counting.dorothy_plate_messages", dish_count, "medium", f"Dorothy chat_identifier={dorothy_chat_id}; keyword=盤子"))
        ev.append(evidence("chat_db", chat_db, "dish_counting.step6_missed_count", missed_count, "medium", "keywords: " + ",".join(dish_missed_keywords)))
        status_parts.append("ok")
    except Exception as exc:
        ev.append(evidence("chat_db", chat_db, "dish_counting.dorothy_plate_messages", 0, "low", f"chat scan unavailable: {exc}"))
        status_parts.append("unavailable")

    try:
        step6_reports = 0
        if not work_log_dir.exists():
            raise FileNotFoundError(f"{work_log_dir} missing")
        pattern = re.compile(r"(Step\s*6|第\s*6\s*步).{0,80}(完成|complete|completed|回報|Dorothy)", re.IGNORECASE)
        for path in work_log_dir.rglob("*"):
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            if report_date in text:
                step6_reports += len(pattern.findall(text))
        kpi["report_accuracy_rate"] = rate(step6_reports, kpi["reviewed_total"])
        ev.append(evidence("work_logs", work_log_dir, "dish_counting.step6_complete_reports", step6_reports, "medium", "grep Step 6 completion mentions in WorkRecord"))
        status_parts.append("ok")
    except Exception as exc:
        ev.append(evidence("work_logs", work_log_dir, "dish_counting.step6_complete_reports", 0, "low", f"work log scan unavailable: {exc}"))
        status_parts.append("unavailable")

    return ("ok" if all(part == "ok" for part in status_parts) else "partial" if any(part == "ok" for part in status_parts) else "unavailable"), kpi, ev


def scan_calendar() -> tuple[str, dict, list[dict]]:
    """Measure Calendar event creation against chat messages with date/time intent."""
    kpi = {
        "event_entry_success_rate": None,
        "timezone_accuracy_rate": None,
        "expected_event_count": 0,
        "created_event_count": 0,
    }
    ev: list[dict] = []
    statuses: list[str] = []

    try:
        rows = fetch_chat_rows(report_date)
        date_time_pattern = re.compile(r"(\d{1,2}[/-]\d{1,2}|\d{4}[/-]\d{1,2}[/-]\d{1,2}|今天|明天|後天|週[一二三四五六日天]|星期[一二三四五六日天]).{0,30}(\d{1,2}:\d{2}|\d{1,2}\s*[點时時])")
        expected = sum(
            1 for row in rows
            if any(keyword in (row["text"] or "") for keyword in calendar_keywords)
            and date_time_pattern.search(row["text"] or "")
        )
        kpi["expected_event_count"] = expected
        ev.append(evidence("chat_db", chat_db, "calendar.expected_event_count", expected, "low", "keywords with date/time pattern"))
        statuses.append("ok")
    except Exception as exc:
        ev.append(evidence("chat_db", chat_db, "calendar.expected_event_count", 0, "low", f"chat scan unavailable: {exc}"))
        statuses.append("unavailable")

    if not calendar_cache.exists():
        ev.append(evidence("calendar_cache", calendar_cache, "calendar.created_event_count", 0, "low", "Calendar Cache missing"))
        statuses.append("unavailable")
    else:
        try:
            start_cocoa, end_cocoa = day_bounds_cocoa_epoch(report_date)
            conn = sqlite3.connect(f"file:{calendar_cache}?mode=ro", uri=True)
            conn.row_factory = sqlite3.Row
            tables = {row["name"] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
            if "ZEVENT" not in tables:
                raise RuntimeError("ZEVENT table not found")
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(ZEVENT)").fetchall()}
            created_col = next((col for col in ("ZCREATIONDATE", "ZCREATEDDATE", "ZDATECREATED") if col in columns), None)
            if created_col is None:
                raise RuntimeError("ZEVENT creation-date column not found")
            created_rows = conn.execute(
                f"SELECT * FROM ZEVENT WHERE {created_col} >= ? AND {created_col} < ?",
                (start_cocoa, end_cocoa),
            ).fetchall()
            timezone_cols = [col for col in ("ZTIMEZONE", "ZTIMEZONEID", "ZSTARTTIMEZONE", "ZENDTIMEZONE") if col in columns]
            tz_ok = 0
            for row in created_rows:
                values = " ".join(str(row[col] or "") for col in timezone_cols)
                if "Asia/Taipei" in values or "UTC+8" in values or "GMT+8" in values:
                    tz_ok += 1
            created = len(created_rows)
            kpi["created_event_count"] = created
            kpi["event_entry_success_rate"] = rate(created, kpi["expected_event_count"])
            kpi["timezone_accuracy_rate"] = rate(tz_ok, created)
            ev.append(evidence("calendar_cache", calendar_cache, "calendar.created_event_count", created, "medium", f"ZEVENT.{created_col} created today"))
            ev.append(evidence("calendar_cache", calendar_cache, "calendar.timezone_accuracy", tz_ok, "low", "timezone columns: " + ",".join(timezone_cols) if timezone_cols else "no timezone columns found"))
            statuses.append("ok")
            conn.close()
        except Exception as exc:
            ev.append(evidence("calendar_cache", calendar_cache, "calendar.created_event_count", 0, "low", f"sqlite3 read error: {exc}"))
            statuses.append("unavailable")

    return ("ok" if all(part == "ok" for part in statuses) else "partial" if any(part == "ok" for part in statuses) else "unavailable"), kpi, ev


def scan_rule_compliance() -> tuple[str, dict, list[dict]]:
    """Measure outbound canned responses and no-@ reply heuristic from chat.db."""
    kpi = {
        "compliance_rate": None,
        "no_at_no_reply_violation_count": 0,
        "canned_response_violation_count": 0,
    }
    ev: list[dict] = []
    try:
        rows = fetch_chat_rows(report_date)
        outbound = [row for row in rows if int(row["is_from_me"] or 0) == 1]
        no_at_violations = 0
        canned_violations = 0
        previous_text = ""
        for row in rows:
            text = row["text"] or ""
            if int(row["is_from_me"] or 0) == 1:
                if "@" not in previous_text and previous_text.strip():
                    no_at_violations += 1
                if any(phrase in text for phrase in canned_phrases):
                    canned_violations += 1
                if "姊姊" in text and len(text.strip()) < 30:
                    canned_violations += 1
            previous_text = text
        total_interactions = len(outbound)
        violation_count = no_at_violations + canned_violations
        kpi.update({
            "compliance_rate": rate(max(total_interactions - violation_count, 0), total_interactions),
            "no_at_no_reply_violation_count": no_at_violations,
            "canned_response_violation_count": canned_violations,
        })
        ev.append(evidence("chat_db", chat_db, "rule_compliance.total_outbound_interactions", total_interactions, "low", "outbound messages from Alpha/is_from_me=1"))
        ev.append(evidence("chat_db", chat_db, "rule_compliance.no_at_no_reply_violation_count", no_at_violations, "low", "heuristic: prior inbound text lacks @ mention"))
        ev.append(evidence("chat_db", chat_db, "rule_compliance.canned_response_violation_count", canned_violations, "medium", "banned canned phrases plus short 姊姊 messages"))
        return "ok", kpi, ev
    except Exception as exc:
        ev.append(evidence("chat_db", chat_db, "rule_compliance", 0, "low", f"chat scan unavailable: {exc}"))
        return "unavailable", kpi, ev


def rate(success: int, total: int) -> float | None:
    return round(success / total, 4) if total > 0 else None


chat_status, correction_count, median_reply, p95_reply, chat_evidence = scan_chat_db()
m017_status, m017_attempts, m017_successes, tg_attempts, tg_successes, m017_evidence = scan_m017_logs()
dashboard_status, expected_signins, actual_signins, dashboard_evidence = scan_dashboard()
work_status, work_evidence = scan_work_logs()
mail_status, mail_kpi, mail_evidence = scan_mail_watchman()
dish_status, dish_kpi, dish_evidence = scan_dish_counting()
calendar_status, calendar_kpi, calendar_evidence = scan_calendar()
rule_status, rule_kpi, rule_evidence = scan_rule_compliance()

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
    "schema_version": "0.2",
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
        "mail_watchman": mail_status,
        "dish_counting": dish_status,
        "calendar": calendar_status,
        "rule_compliance": rule_status,
    },
    "kpis": {
        "mail_watchman": mail_kpi,
        "m017_nightly_merge": {
            "completeness": None,
            "commit_success_rate": rate(m017_successes, m017_attempts),
            "tg_broadcast_delivery_rate": rate(tg_successes, tg_attempts),
            "attempt_count": m017_attempts,
            "success_count": m017_successes,
        },
        "dish_counting": dish_kpi,
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
        "calendar": calendar_kpi,
        "rule_compliance": rule_kpi,
    },
    "dimensions": {
        "success_completion_rate": overall_success,
        "response_time_median_minutes": round(median_reply, 2) if median_reply is not None else None,
        "response_time_p95_minutes": round(p95_reply, 2) if p95_reply is not None else None,
        "error_misclassification_count": mail_kpi["errors"],
        "master_correction_count": correction_count,
        "rule_compliance_rate": rule_kpi["compliance_rate"],
    },
    "violations": violations,
    "corrective_actions": corrective_actions,
    "evidence": chat_evidence + m017_evidence + dashboard_evidence + work_evidence + mail_evidence + dish_evidence + calendar_evidence + rule_evidence,
}

report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(str(report_path))
PY
