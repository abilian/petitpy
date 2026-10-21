# nanopython — _thread stub (ADR-003 D6).
#
# A single-threaded runtime can't honor any thread semantics, but many
# stdlib modules (logging, queue, others) `import _thread` at module load
# time and only conditionally exercise it. The stub keeps those imports
# working; calling any function that would actually create a thread
# raises NotImplementedError.

error = Exception  # CPython type; we conflate with the catch-all here.


def allocate_lock():
    return _Lock()


def start_new_thread(target, args, kwargs=None):
    raise NotImplementedError("_thread: nanopython is single-threaded")


def get_ident():
    return 1


def exit():
    raise SystemExit


class _Lock:
    """Reentrant-by-vacuity lock: there are no other threads to block."""

    def __init__(self):
        self._held = False

    def acquire(self, waitflag=1, timeout=-1):
        if self._held and waitflag == 0:
            return False
        self._held = True
        return True

    def release(self):
        if not self._held:
            raise RuntimeError("release unlocked lock")
        self._held = False

    def locked(self):
        return self._held

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *exc):
        self.release()
        return False
