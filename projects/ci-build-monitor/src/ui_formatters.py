# Formatters
# Time and text formatting utilities

import js

# Provider timestamps are stored as seconds-since-2020 (see
# providers_sourcehut._safe_ts_ms) so they fit the nano 30-bit smallint
# cap (~5.4e8). Compute the diff in seconds against now-as-seconds-since-2020
# directly — no clamping needed since the diff is bounded by `now - 0` which
# is well inside the smallint floor for the next ~17 years.
#
# Previous version clamped to 31622400 (366 days) AND assumed input was
# epoch-ms — which silently displayed everything older than a year as
# exactly "366 days ago".
_diff_seconds = js.get("eval")(
    "(function(ts){"
    "var now=Math.floor(Date.now()/1000)-1577836800;"
    "var d=now-ts;"
    "if(d<0)d=0;"
    "if(d>536870911)d=536870911;"
    "return d;})"
)


def format_timestamp(timestamp):
    """Format timestamp for display."""
    if not timestamp:
        return "Never"
    date = js.get("Date")(timestamp)
    return date.toLocaleString()


def format_relative_time(timestamp):
    """Format timestamp as relative time (e.g., '2 hours ago')."""
    if not timestamp:
        return "Never"

    # JS-side diff: avoids the smallint overflow on Date.now() (~1.7e12).
    seconds = _diff_seconds(timestamp).to_int()

    if seconds < 60:
        return "just now"
    elif seconds < 3600:
        minutes = seconds // 60
        if minutes == 1:
            return "1 minute ago"
        return str(minutes) + " minutes ago"
    elif seconds < 86400:
        hours = seconds // 3600
        if hours == 1:
            return "1 hour ago"
        return str(hours) + " hours ago"
    elif seconds < 2592000:  # 30 days
        days = seconds // 86400
        if days == 1:
            return "1 day ago"
        return str(days) + " days ago"
    elif seconds < 31536000:  # 365 days
        months = seconds // 2592000
        if months == 1:
            return "1 month ago"
        return str(months) + " months ago"
    else:
        years = seconds // 31536000
        if years == 1:
            return "1 year ago"
        return str(years) + " years ago"


def truncate_text(text, max_len):
    """Truncate text with ellipsis if too long."""
    if not text:
        return ""
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."
