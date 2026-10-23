"""Self-tests for pytest_lite.

Bootstrap concern: we use pytest_lite to test pytest_lite. If discovery
is broken, the bottom block prints a clear error before trusting the
runner for the other stdlib modules. The tests below cover every public
surface: PASS/FAIL/SKIP outcomes, pytest.raises, the @skip decorator,
the run_module() programmatic entry, and summarize()'s exit-code logic.
"""

import sys


# Make petitpy-lib importable. On the dev host, run from repo root:
#     ./zig-out/bin/petitpy tests/stdlib/test_pytest_lite.py
sys.path.insert(0, "petitpy-lib")

import pytest  # noqa: E402  — the re-export shim


# ── Sanity tests on pytest_lite's own surface ────────────────────────────


def test_passing_test_passes():
    """A test that returns normally is PASS."""
    assert 1 + 1 == 2


def test_failing_assertion_is_fail():
    """A failing assert inside a test produces FAIL."""
    # We use run_module on a fake module containing one known-failing test,
    # then assert on the outcome.
    class M:
        @staticmethod
        def test_fails():
            assert 1 == 2, "intentional"

    results = pytest.run_module(M, verbose=False)
    assert len(results) == 1
    assert results[0].outcome == "FAIL"
    assert "intentional" in results[0].message


def test_exception_other_than_assertion_is_fail():
    """Any uncaught Exception produces FAIL with the exception type
    in the message."""
    class M:
        @staticmethod
        def test_raises_unrelated():
            raise ValueError("boom")

    results = pytest.run_module(M, verbose=False)
    assert results[0].outcome == "FAIL"
    assert "ValueError" in results[0].message
    assert "boom" in results[0].message


def test_inline_skip():
    """Calling pytest.skip(reason) inside a test produces SKIP."""
    class M:
        @staticmethod
        def test_will_skip():
            pytest.skip("because")

    results = pytest.run_module(M, verbose=False)
    assert results[0].outcome == "SKIP"
    assert results[0].message == "because"


def test_decorator_skip():
    """@pytest.skip on a test function produces SKIP when run."""
    @pytest.skip
    def test_inner():
        assert False, "should not run"

    class M:
        pass
    M.test_inner = test_inner

    results = pytest.run_module(M, verbose=False)
    assert results[0].outcome == "SKIP"


# ── pytest.raises ────────────────────────────────────────────────────────


def test_raises_catches_expected_exception():
    with pytest.raises(ValueError):
        int("abc")


def test_raises_value_attribute_holds_exception():
    with pytest.raises(KeyError) as cm:
        d = {}
        d["missing"]
    assert cm.value is not None
    assert "missing" in str(cm.value)


def test_raises_fails_when_no_exception():
    # Use a sub-test inside a fake module to verify the failure mode.
    class M:
        @staticmethod
        def test_no_raise():
            with pytest.raises(ValueError):
                pass  # no exception → AssertionError

    results = pytest.run_module(M, verbose=False)
    assert results[0].outcome == "FAIL"
    assert "DID NOT RAISE" in results[0].message


def test_raises_propagates_unrelated_exception():
    """If the block raises a different exception type, it should
    propagate (not be swallowed)."""
    class M:
        @staticmethod
        def test_wrong_type():
            with pytest.raises(ValueError):
                raise TypeError("not what we expected")

    results = pytest.run_module(M, verbose=False)
    # TypeError propagates, becomes the test's failure (FAIL).
    assert results[0].outcome == "FAIL"
    assert "TypeError" in results[0].message


# ── Discovery details ────────────────────────────────────────────────────


def test_non_test_functions_ignored():
    """Helper functions whose names don't start with test_ should not run."""
    class M:
        @staticmethod
        def helper():
            assert False, "should not be discovered"

        @staticmethod
        def test_real():
            pass

    results = pytest.run_module(M, verbose=False)
    names = [r.name for r in results]
    assert "helper" not in names
    assert "test_real" in names
    assert len(results) == 1


def test_non_callable_test_attributes_ignored():
    """Module-level constants named test_* shouldn't crash discovery."""
    class M:
        test_constant = 42  # not callable; should be skipped silently

        @staticmethod
        def test_real():
            pass

    results = pytest.run_module(M, verbose=False)
    assert len(results) == 1
    assert results[0].name == "test_real"


# ── summarize() exit code ────────────────────────────────────────────────


def test_summarize_returns_zero_on_all_pass():
    results = [pytest.TestResult("test_a", "PASS")]
    # Can't observe summarize's prints directly, but its return value
    # is the exit code.
    rc = pytest.summarize(results)
    assert rc == 0


def test_summarize_returns_one_on_any_fail():
    results = [
        pytest.TestResult("test_a", "PASS"),
        pytest.TestResult("test_b", "FAIL", "intentional"),
    ]
    rc = pytest.summarize(results)
    assert rc == 1


def test_summarize_skips_dont_fail():
    """A run with PASS + SKIP only (no FAIL) is success."""
    results = [
        pytest.TestResult("test_a", "PASS"),
        pytest.TestResult("test_b", "SKIP", "deferred"),
    ]
    rc = pytest.summarize(results)
    assert rc == 0


# ── Bootstrap entry ──────────────────────────────────────────────────────


if __name__ == "__main__":
    pytest.run_self_tests(globals())
