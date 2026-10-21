"""nanopython — datetime subset (POSIX-timestamp-backed).

Ships enough for the audit-log-timestamp idiom:

    datetime.now(timezone.utc).isoformat()

and general timestamp arithmetic. Full CPython calendar surface
(strptime, weekdays, dst, comparisons across tzs, replace()) is NOT
implemented — the module is a minimum-viable stand-in for CPython
code that writes ISO timestamps and does simple deltas.

Ships:
  * datetime.now(tz=None) → naive or UTC-aware
  * datetime.utcnow(), datetime.fromtimestamp(ts, tz=None)
  * datetime.fromisoformat(s) — supports "YYYY-MM-DDTHH:MM:SS[.fff][+HH:MM]"
  * datetime.isoformat(sep='T')
  * datetime.timestamp() → float seconds since epoch
  * datetime.__sub__ → timedelta
  * timedelta with days, seconds, microseconds arithmetic
  * timezone(offset, name=None), timezone.utc
"""
import time as _time


class timedelta:
    """Duration between two datetimes. Total ~microsecond resolution."""

    def __init__(self, days=0, seconds=0, microseconds=0,
                 milliseconds=0, minutes=0, hours=0, weeks=0):
        total_us = (
            microseconds
            + milliseconds * 1000
            + seconds * 1_000_000
            + minutes * 60 * 1_000_000
            + hours * 3600 * 1_000_000
            + days * 86400 * 1_000_000
            + weeks * 7 * 86400 * 1_000_000
        )
        # Normalize into (days, seconds, microseconds) matching CPython.
        d, r = divmod(total_us, 86400 * 1_000_000)
        s, us = divmod(r, 1_000_000)
        self.days = d
        self.seconds = s
        self.microseconds = us

    def total_seconds(self):
        return self.days * 86400 + self.seconds + self.microseconds / 1_000_000.0

    def __add__(self, other):
        if isinstance(other, timedelta):
            return timedelta(days=self.days + other.days,
                             seconds=self.seconds + other.seconds,
                             microseconds=self.microseconds + other.microseconds)
        return NotImplemented

    def __sub__(self, other):
        if isinstance(other, timedelta):
            return timedelta(days=self.days - other.days,
                             seconds=self.seconds - other.seconds,
                             microseconds=self.microseconds - other.microseconds)
        return NotImplemented

    def __eq__(self, other):
        if isinstance(other, timedelta):
            return (self.days == other.days
                    and self.seconds == other.seconds
                    and self.microseconds == other.microseconds)
        return NotImplemented

    def __repr__(self):
        return ("timedelta(days=" + str(self.days)
                + ", seconds=" + str(self.seconds)
                + ", microseconds=" + str(self.microseconds) + ")")


class timezone:
    """Fixed-offset tz. `timezone.utc` is UTC."""

    def __init__(self, offset, name=None):
        # `offset` is a timedelta or int-seconds (accepted as convenience).
        if isinstance(offset, int):
            offset = timedelta(seconds=offset)
        self._offset = offset
        self._name = name

    def utcoffset(self, dt=None):
        return self._offset

    def tzname(self, dt=None):
        if self._name is not None:
            return self._name
        total = int(self._offset.total_seconds())
        h, r = divmod(abs(total), 3600)
        m = r // 60
        sign = "+" if total >= 0 else "-"
        return "UTC" + sign + str(h).zfill(2) + ":" + str(m).zfill(2)

    def __repr__(self):
        return "timezone(" + repr(self._offset) + ")"

    def __eq__(self, other):
        if isinstance(other, timezone):
            return self._offset == other._offset
        return NotImplemented


timezone.utc = timezone(timedelta(0), "UTC")


class datetime:
    """Wall-clock datetime with optional timezone.

    Internally stores seconds-since-epoch (int) + microseconds (int)
    + tzinfo. `year`/`month`/`day` etc. are lazy-computed via
    _civil_from_epoch.
    """

    def __init__(self, year, month, day, hour=0, minute=0, second=0,
                 microsecond=0, tzinfo=None):
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.microsecond = microsecond
        self.tzinfo = tzinfo

    @classmethod
    def now(cls, tz=None):
        now_ns = _time.time_ns()
        sec = now_ns // 1_000_000_000
        us = (now_ns % 1_000_000_000) // 1000
        return cls._from_epoch(sec, us, tz)

    @classmethod
    def utcnow(cls):
        return cls.now(timezone.utc)

    @classmethod
    def fromtimestamp(cls, ts, tz=None):
        sec = int(ts)
        us = int((ts - sec) * 1_000_000)
        return cls._from_epoch(sec, us, tz)

    @classmethod
    def _from_epoch(cls, sec, us, tz):
        # If a tz is provided, we treat sec as UTC and adjust — but the
        # simple case here is timezone.utc (no offset shift). For non-
        # UTC tz, add the offset. Preserves clock resolution for
        # everything under an hour boundary.
        if tz is not None:
            offset_secs = int(tz.utcoffset().total_seconds())
            sec += offset_secs
        y, mo, d, h, mi, s = _civil_from_epoch(sec)
        return cls(y, mo, d, h, mi, s, us, tz)

    def isoformat(self, sep="T"):
        parts = (str(self.year).zfill(4)
                 + "-" + str(self.month).zfill(2)
                 + "-" + str(self.day).zfill(2)
                 + sep + str(self.hour).zfill(2)
                 + ":" + str(self.minute).zfill(2)
                 + ":" + str(self.second).zfill(2))
        if self.microsecond:
            parts += "." + str(self.microsecond).zfill(6)
        if self.tzinfo is not None:
            off = self.tzinfo.utcoffset()
            total = int(off.total_seconds())
            if total == 0:
                parts += "+00:00"
            else:
                sign = "+" if total >= 0 else "-"
                h, r = divmod(abs(total), 3600)
                m = r // 60
                parts += sign + str(h).zfill(2) + ":" + str(m).zfill(2)
        return parts

    def timestamp(self):
        sec = _epoch_from_civil(self.year, self.month, self.day,
                                self.hour, self.minute, self.second)
        if self.tzinfo is not None:
            sec -= int(self.tzinfo.utcoffset().total_seconds())
        return sec + self.microsecond / 1_000_000.0

    @classmethod
    def fromisoformat(cls, s):
        # Accepts "YYYY-MM-DD[Tsep]HH:MM:SS[.ffffff][±HH:MM]"
        # or "YYYY-MM-DD" (date-only).
        tz = None
        # Tz suffix
        for i in range(len(s) - 1, 9, -1):
            if s[i] in "+-":
                off = s[i:]
                s = s[:i]
                sign = 1 if off[0] == "+" else -1
                h, m = off[1:].split(":")
                tz = timezone(timedelta(minutes=sign * (int(h) * 60 + int(m))))
                break
        if s.endswith("Z"):
            tz = timezone.utc
            s = s[:-1]
        # Split date/time.
        us = 0
        if "T" in s or " " in s:
            date_s, time_s = s.replace(" ", "T").split("T", 1)
            if "." in time_s:
                time_s, us_s = time_s.split(".", 1)
                us = int(us_s.ljust(6, "0")[:6])
            hh, mm, ss = time_s.split(":")
            h, mi, sec = int(hh), int(mm), int(ss)
        else:
            date_s, h, mi, sec = s, 0, 0, 0
        yy, mo, dd = date_s.split("-")
        return cls(int(yy), int(mo), int(dd), h, mi, sec, us, tz)

    def __sub__(self, other):
        if isinstance(other, datetime):
            return timedelta(seconds=self.timestamp() - other.timestamp())
        return NotImplemented

    def __eq__(self, other):
        if isinstance(other, datetime):
            return (self.year == other.year and self.month == other.month
                    and self.day == other.day and self.hour == other.hour
                    and self.minute == other.minute and self.second == other.second
                    and self.microsecond == other.microsecond)
        return NotImplemented

    def __repr__(self):
        return "datetime(" + str(self.year) + ", " + str(self.month) + ", " + str(self.day) + ")"

    def __str__(self):
        return self.isoformat(" ")


class date:
    """Date without time — stub for CPython compat imports."""
    def __init__(self, year, month, day):
        self.year = year
        self.month = month
        self.day = day

    def isoformat(self):
        return str(self.year).zfill(4) + "-" + str(self.month).zfill(2) + "-" + str(self.day).zfill(2)

    def __str__(self):
        return self.isoformat()


class time:
    """Time without date — stub for CPython compat imports.

    Named `time` (masking the module import if used carelessly — CPython
    has the same issue; users must `from datetime import time as _t` or
    similar).
    """
    def __init__(self, hour=0, minute=0, second=0, microsecond=0, tzinfo=None):
        self.hour = hour
        self.minute = minute
        self.second = second
        self.microsecond = microsecond
        self.tzinfo = tzinfo


# ── civil ⇄ epoch helpers (Howard Hinnant's algorithm) ───────────────

def _civil_from_epoch(z):
    """POSIX epoch seconds (UTC) → (year, month, day, hour, minute, second)."""
    days = z // 86400
    tod = z - days * 86400
    days += 719468
    era = days // 146097 if days >= 0 else (days - 146096) // 146097
    doe = days - era * 146097                     # [0, 146096]
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365  # [0, 399]
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)  # [0, 365]
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    h = tod // 3600
    tod -= h * 3600
    mi = tod // 60
    s = tod - mi * 60
    return y, m, d, h, mi, s


def _epoch_from_civil(y, m, d, h, mi, s):
    """Civil UTC → POSIX epoch seconds."""
    if m <= 2:
        y -= 1
    era = y // 400 if y >= 0 else (y - 399) // 400
    yoe = y - era * 400                           # [0, 399]
    doy = (153 * (m + 9 if m <= 2 else m - 3) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy   # [0, 146096]
    days = era * 146097 + doe - 719468
    return days * 86400 + h * 3600 + mi * 60 + s
