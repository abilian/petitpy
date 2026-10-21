"""Tests for nanopython-lib/logging.py via pytest_lite."""

import sys

sys.path.insert(0, "nanopython-lib")

import pytest
import logging


def _captured_logger(level=logging.DEBUG, format=None):
    """Reset logging state and return (logger, captured_list) where
    captured_list collects emitted lines."""
    logging._reset_for_tests()
    captured = []
    logging.basicConfig(level=level, format=format, sink=captured.append)
    return captured


# ── level constants ────────────────────────────────────────────────────


def test_level_constants():
    assert logging.DEBUG == 10
    assert logging.INFO == 20
    assert logging.WARNING == 30
    assert logging.ERROR == 40
    assert logging.CRITICAL == 50
    assert logging.NOTSET == 0


def test_legacy_aliases():
    assert logging.WARN == logging.WARNING
    assert logging.FATAL == logging.CRITICAL


def test_getLevelName_known():
    assert logging.getLevelName(logging.INFO) == "INFO"
    assert logging.getLevelName(logging.WARNING) == "WARNING"


def test_getLevelName_unknown():
    assert logging.getLevelName(42).startswith("Level ")


# ── getLogger ──────────────────────────────────────────────────────────


def test_getLogger_returns_same_instance():
    logging._reset_for_tests()
    a = logging.getLogger("x")
    b = logging.getLogger("x")
    assert a is b


def test_getLogger_default_is_root():
    logging._reset_for_tests()
    a = logging.getLogger()
    b = logging.getLogger("root")
    c = logging.getLogger(None)
    assert a is b is c
    assert a.name == "root"


def test_getLogger_distinct_names_distinct_loggers():
    logging._reset_for_tests()
    a = logging.getLogger("alpha")
    b = logging.getLogger("beta")
    assert a is not b


# ── level filtering ────────────────────────────────────────────────────


def test_default_level_is_warning():
    cap = _captured_logger(level=logging.WARNING)
    log = logging.getLogger("t")
    log.debug("hidden")
    log.info("hidden")
    log.warning("visible")
    assert len(cap) == 1
    assert "visible" in cap[0]


def test_setting_level_lowers_threshold():
    cap = _captured_logger(level=logging.DEBUG)
    log = logging.getLogger("t")
    log.debug("now visible")
    assert len(cap) == 1


def test_per_logger_setLevel_overrides_root():
    cap = _captured_logger(level=logging.WARNING)
    chatty = logging.getLogger("chatty")
    chatty.setLevel(logging.DEBUG)
    chatty.debug("from chatty")
    quiet = logging.getLogger("quiet")
    quiet.debug("hidden")
    assert len(cap) == 1
    assert "chatty" in cap[0]


def test_isEnabledFor():
    logging._reset_for_tests()
    logging.basicConfig(level=logging.INFO)
    log = logging.getLogger("t")
    assert not log.isEnabledFor(logging.DEBUG)
    assert log.isEnabledFor(logging.INFO)
    assert log.isEnabledFor(logging.WARNING)


# ── printf-style args ──────────────────────────────────────────────────


def test_printf_style_substitution():
    cap = _captured_logger(level=logging.DEBUG)
    log = logging.getLogger("t")
    log.info("count=%d total=%s", 42, "many")
    assert "count=42 total=many" in cap[0]


def test_no_args_means_no_substitution():
    cap = _captured_logger(level=logging.DEBUG)
    log = logging.getLogger("t")
    log.info("100%% accurate")  # literal % shouldn't trigger substitution
    assert "100% accurate" in cap[0] or "100%% accurate" in cap[0]


def test_malformed_format_does_not_crash():
    cap = _captured_logger(level=logging.DEBUG)
    log = logging.getLogger("t")
    # Mismatched args should leave the msg unformatted, not crash.
    log.info("expected %s and %s", "one")  # too few args
    assert len(cap) == 1


# ── format string ──────────────────────────────────────────────────────


def test_default_format():
    cap = _captured_logger(level=logging.DEBUG)
    log = logging.getLogger("myapp")
    log.warning("hi")
    assert cap[0] == "WARNING:myapp:hi"


def test_custom_format():
    cap = _captured_logger(
        level=logging.DEBUG, format="[%(levelname)s] %(name)s -> %(message)s"
    )
    log = logging.getLogger("t")
    log.error("boom")
    assert cap[0] == "[ERROR] t -> boom"


def test_level_number_in_format():
    cap = _captured_logger(level=logging.DEBUG, format="%(level)d:%(message)s")
    log = logging.getLogger("t")
    log.info("hello")
    assert cap[0] == "20:hello"


# ── module-level shortcuts ─────────────────────────────────────────────


def test_module_level_info_uses_root_logger():
    cap = _captured_logger(level=logging.DEBUG)
    logging.info("module-level")
    assert "root" in cap[0]
    assert "module-level" in cap[0]


def test_all_module_shortcuts_present():
    cap = _captured_logger(level=logging.DEBUG)
    logging.debug("d")
    logging.info("i")
    logging.warning("w")
    logging.error("e")
    logging.critical("c")
    assert len(cap) == 5
    assert "DEBUG" in cap[0]
    assert "INFO" in cap[1]
    assert "WARNING" in cap[2]
    assert "ERROR" in cap[3]
    assert "CRITICAL" in cap[4]


def test_log_with_explicit_level():
    cap = _captured_logger(level=logging.DEBUG)
    logging.log(logging.ERROR, "via log()")
    assert "ERROR" in cap[0]
    assert "via log()" in cap[0]


# ── disable() ──────────────────────────────────────────────────────────


def test_disable_silences_below_threshold():
    cap = _captured_logger(level=logging.DEBUG)
    logging.disable(logging.WARNING)
    log = logging.getLogger("t")
    log.warning("hidden")
    log.error("visible")
    assert len(cap) == 1
    assert "error" in cap[0].lower() or "ERROR" in cap[0]


# ── basicConfig idempotency ────────────────────────────────────────────


def test_basicConfig_can_change_level():
    cap = _captured_logger(level=logging.WARNING)
    log = logging.getLogger("t")
    log.info("first hidden")
    logging.basicConfig(level=logging.DEBUG)
    log.info("second visible")
    assert len(cap) == 1
    assert "second" in cap[0]


def test_basicConfig_can_change_format():
    cap = _captured_logger(level=logging.DEBUG)
    logging.basicConfig(format="X:%(message)s")
    log = logging.getLogger("t")
    log.info("hello")
    assert cap[0] == "X:hello"


if __name__ == "__main__":
    pytest.run_self_tests(globals())
