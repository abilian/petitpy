"""Tests for nanopython-lib/argparse.py via pytest_lite."""

import sys

sys.path.insert(0, "nanopython-lib")

import pytest
import argparse


# ── positional ──────────────────────────────────────────────────────────


def test_single_positional():
    p = argparse.ArgumentParser()
    p.add_argument("input")
    args = p.parse_args(["data.txt"])
    assert args.input == "data.txt"


def test_two_positionals_in_order():
    p = argparse.ArgumentParser()
    p.add_argument("src")
    p.add_argument("dst")
    args = p.parse_args(["a.txt", "b.txt"])
    assert args.src == "a.txt"
    assert args.dst == "b.txt"


def test_missing_positional_exits():
    p = argparse.ArgumentParser()
    p.add_argument("input")
    with pytest.raises(SystemExit):
        p.parse_args([])


def test_extra_positional_exits():
    p = argparse.ArgumentParser()
    p.add_argument("input")
    with pytest.raises(SystemExit):
        p.parse_args(["a", "b"])


# ── long + short flags ─────────────────────────────────────────────────


def test_long_flag():
    p = argparse.ArgumentParser()
    p.add_argument("--name")
    args = p.parse_args(["--name", "Alice"])
    assert args.name == "Alice"


def test_long_flag_with_equals():
    p = argparse.ArgumentParser()
    p.add_argument("--name")
    args = p.parse_args(["--name=Bob"])
    assert args.name == "Bob"


def test_short_flag_with_long_alias():
    p = argparse.ArgumentParser()
    p.add_argument("--name", "-n")
    args = p.parse_args(["-n", "Carol"])
    assert args.name == "Carol"
    args = p.parse_args(["--name", "Dave"])
    assert args.name == "Dave"


def test_short_only_flag():
    p = argparse.ArgumentParser()
    p.add_argument("-n")
    args = p.parse_args(["-n", "value"])
    assert args.n == "value"


def test_flag_requires_value():
    p = argparse.ArgumentParser()
    p.add_argument("--name")
    # --name with no following value should be an error.
    with pytest.raises(SystemExit):
        p.parse_args(["--name"])


def test_unknown_flag_exits():
    p = argparse.ArgumentParser()
    p.add_argument("--known")
    with pytest.raises(SystemExit):
        p.parse_args(["--unknown", "x"])


# ── action="store_true" / "store_false" ────────────────────────────────


def test_store_true_default_false():
    p = argparse.ArgumentParser()
    p.add_argument("--verbose", "-v", action="store_true")
    args = p.parse_args([])
    assert args.verbose is False


def test_store_true_present():
    p = argparse.ArgumentParser()
    p.add_argument("--verbose", "-v", action="store_true")
    args = p.parse_args(["--verbose"])
    assert args.verbose is True
    args = p.parse_args(["-v"])
    assert args.verbose is True


def test_store_false_default_true():
    p = argparse.ArgumentParser()
    p.add_argument("--quiet", action="store_false")
    args = p.parse_args([])
    assert args.quiet is True


def test_store_false_present():
    p = argparse.ArgumentParser()
    p.add_argument("--quiet", action="store_false")
    args = p.parse_args(["--quiet"])
    assert args.quiet is False


# ── action="count" ──────────────────────────────────────────────────────


def test_count_starts_at_zero():
    p = argparse.ArgumentParser()
    p.add_argument("-v", action="count")
    args = p.parse_args([])
    assert args.v == 0


def test_count_increments():
    p = argparse.ArgumentParser()
    p.add_argument("-v", action="count")
    args = p.parse_args(["-v", "-v", "-v"])
    assert args.v == 3


# ── type= conversion ───────────────────────────────────────────────────


def test_type_int():
    p = argparse.ArgumentParser()
    p.add_argument("--count", type=int, default=0)
    args = p.parse_args(["--count", "42"])
    assert args.count == 42
    assert isinstance(args.count, int)


def test_type_callable():
    p = argparse.ArgumentParser()
    p.add_argument("--name", type=str.upper)
    args = p.parse_args(["--name", "alice"])
    assert args.name == "ALICE"


def test_bad_type_conversion_exits():
    p = argparse.ArgumentParser()
    p.add_argument("--count", type=int)
    with pytest.raises(SystemExit):
        p.parse_args(["--count", "not-a-number"])


def test_positional_type():
    p = argparse.ArgumentParser()
    p.add_argument("n", type=int)
    args = p.parse_args(["5"])
    assert args.n == 5


# ── default ────────────────────────────────────────────────────────────


def test_default_used_when_absent():
    p = argparse.ArgumentParser()
    p.add_argument("--name", default="anonymous")
    args = p.parse_args([])
    assert args.name == "anonymous"


def test_default_overridden_when_present():
    p = argparse.ArgumentParser()
    p.add_argument("--name", default="anonymous")
    args = p.parse_args(["--name", "Eve"])
    assert args.name == "Eve"


# ── choices ────────────────────────────────────────────────────────────


def test_choices_accepts_valid():
    p = argparse.ArgumentParser()
    p.add_argument("--mode", choices=["fast", "safe"])
    args = p.parse_args(["--mode", "fast"])
    assert args.mode == "fast"


def test_choices_rejects_invalid():
    p = argparse.ArgumentParser()
    p.add_argument("--mode", choices=["fast", "safe"])
    with pytest.raises(SystemExit):
        p.parse_args(["--mode", "wrong"])


# ── mixed positional + optional ────────────────────────────────────────


def test_mixed_positional_after_flag():
    p = argparse.ArgumentParser()
    p.add_argument("filename")
    p.add_argument("--verbose", "-v", action="store_true")
    args = p.parse_args(["-v", "input.txt"])
    assert args.filename == "input.txt"
    assert args.verbose is True


def test_mixed_flag_after_positional():
    p = argparse.ArgumentParser()
    p.add_argument("filename")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args(["input.txt", "--verbose"])
    assert args.filename == "input.txt"
    assert args.verbose is True


# ── dest name derivation ───────────────────────────────────────────────


def test_hyphenated_long_flag_becomes_underscored_dest():
    p = argparse.ArgumentParser()
    p.add_argument("--max-count", type=int)
    args = p.parse_args(["--max-count", "5"])
    assert args.max_count == 5


# ── Namespace ──────────────────────────────────────────────────────────


def test_namespace_repr_includes_values():
    p = argparse.ArgumentParser()
    p.add_argument("name")
    p.add_argument("--age", type=int)
    args = p.parse_args(["Alice", "--age", "30"])
    r = repr(args)
    assert "Alice" in r
    assert "30" in r
    assert "Namespace" in r


# ── help ───────────────────────────────────────────────────────────────


def test_help_flag_exits_cleanly():
    p = argparse.ArgumentParser(description="my tool")
    p.add_argument("--foo")
    with pytest.raises(SystemExit):
        p.parse_args(["--help"])


def test_help_short_flag_exits():
    p = argparse.ArgumentParser()
    with pytest.raises(SystemExit):
        p.parse_args(["-h"])


# ── realistic-shape integration ────────────────────────────────────────


def test_full_realistic_invocation():
    p = argparse.ArgumentParser(description="example")
    p.add_argument("input")
    p.add_argument("--output", "-o", default="out.txt")
    p.add_argument("--verbose", "-v", action="store_true")
    p.add_argument("--count", type=int, default=1)
    p.add_argument("--mode", choices=["fast", "safe"], default="safe")

    args = p.parse_args(["data.txt", "-v", "--count=5", "--mode=fast"])
    assert args.input == "data.txt"
    assert args.output == "out.txt"  # default
    assert args.verbose is True
    assert args.count == 5
    assert args.mode == "fast"


if __name__ == "__main__":
    pytest.run_self_tests(globals())
