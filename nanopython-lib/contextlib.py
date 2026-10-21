"""contextlib — minimal context-manager helpers for nanopython.

Supported:
    @contextmanager       — turn a generator function into a context manager
    closing(thing)        — calls thing.close() on exit
    suppress(*exceptions) — swallows exceptions of given types
    nullcontext           — context manager that does nothing

Not supported (vs CPython contextlib):
    - ExitStack / AsyncExitStack
    - asynccontextmanager
    - functools.wraps preservation on @contextmanager (nano can't
      assign function attributes; the wrapper class works without it)

See ADR 011 for the design rationale.
"""


def contextmanager(fn):
    """Decorator: turn a single-yield generator function into a
    context manager.

    Usage::

        @contextmanager
        def timer():
            t0 = ...
            yield
            print("elapsed:", ... - t0)

        with timer():
            do_work()
    """

    class _CM:
        def __init__(self, *args, **kwargs):
            self._gen = fn(*args, **kwargs)

        def __enter__(self):
            # Two failure modes for "function didn't yield":
            #   - StopIteration: function was a generator but completed
            #     without yielding.
            #   - TypeError ("object not an iterator"): nano compiles
            #     functions with unreachable `yield` as non-generators
            #     (smarter than CPython, which always treats any yield
            #     as making the function a generator). So fn() returned
            #     None and next(None) trips TypeError.
            # Either way, the user's contract violation is the same.
            try:
                return next(self._gen)
            except StopIteration:
                raise RuntimeError("generator didn't yield")
            except TypeError:
                raise RuntimeError(
                    "function passed to @contextmanager must yield at least once"
                )

        def __exit__(self, exc_type, exc, tb):
            if exc is None:
                # Normal exit — drive the generator past the yield.
                try:
                    next(self._gen)
                except StopIteration:
                    return False
                raise RuntimeError("generator didn't stop")
            else:
                # Exception inside the with-block — propagate it into
                # the generator's `yield`, so user can `try/except` it.
                try:
                    # MicroPython supports the 1-arg form throw(exc).
                    self._gen.throw(exc)
                except StopIteration:
                    # Generator caught it and finished — suppress.
                    return True
                except BaseException as new_exc:
                    # Generator re-raised. If it's the same exception
                    # we threw in, the suppression machinery will
                    # propagate it naturally; otherwise the user
                    # transformed it, and we re-raise the new one.
                    if new_exc is exc:
                        return False
                    raise
                # If we got here, the generator yielded again — misuse.
                raise RuntimeError("generator didn't stop after throw")

    return _CM


class closing:
    """Context manager that calls ``thing.close()`` on exit, even if
    an exception was raised inside the with-block."""

    def __init__(self, thing):
        self._thing = thing

    def __enter__(self):
        return self._thing

    def __exit__(self, exc_type, exc, tb):
        self._thing.close()
        return False


class suppress:
    """Context manager that silently swallows specified exception
    types raised inside the with-block.

    Other exception types propagate normally.

    Usage::

        with suppress(FileNotFoundError):
            os.remove("maybe_gone")
    """

    def __init__(self, *exceptions):
        self._exceptions = exceptions

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            return False
        return issubclass(exc_type, self._exceptions)


class nullcontext:
    """Context manager that does nothing.

    Useful as a stand-in when code expects a context manager but the
    caller has no setup/teardown to do::

        cm = lock if needs_locking else nullcontext()
        with cm:
            do_work()
    """

    def __init__(self, enter_result=None):
        self._enter_result = enter_result

    def __enter__(self):
        return self._enter_result

    def __exit__(self, exc_type, exc, tb):
        return False
