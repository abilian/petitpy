"""nanopython — Python wrapper around the low-level `_subprocess`
built-in.

CPython-shaped surface. The low-level primitive lives in the C-side
`_subprocess` module (built via feature-subprocess); this wrapper
handles the kwargs surface, the CompletedProcess / CalledProcessError
/ TimeoutExpired classes, and the `capture_output` sugar.

Supported kwargs to run():
  * input          — bytes to send to child stdin
  * capture_output — True to capture stdout/stderr, False to discard
                     (default False)
  * timeout        — float seconds; when exceeded, child is SIGTERM'd
                     and TimeoutExpired raised
  * check          — True to raise CalledProcessError on non-zero exit
                     (default False)
  * env            — accepted but currently IGNORED by the low-level;
                     parent env is always inherited. Silent no-op.
  * shell          — must be False (or omitted); shell=True raises
                     ValueError.
  * stdin, stdout, stderr — accepted but ignored beyond capture_output.

Not supported: `Popen` (deferred — hop3-rootd doesn't need it),
`check_output` (add if a caller needs it — cheap wrapper on run).
"""
import _subprocess


PIPE = -1
STDOUT = -2
DEVNULL = -3


class CompletedProcess:
    """Return value of run(). Attributes: args, returncode, stdout, stderr."""
    def __init__(self, args, returncode, stdout=None, stderr=None):
        self.args = args
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr

    def __repr__(self):
        parts = ["CompletedProcess(args=", repr(self.args),
                 ", returncode=", str(self.returncode)]
        if self.stdout is not None:
            parts.append(", stdout=" + repr(self.stdout))
        if self.stderr is not None:
            parts.append(", stderr=" + repr(self.stderr))
        parts.append(")")
        return "".join(parts)

    def check_returncode(self):
        if self.returncode != 0:
            raise CalledProcessError(self.returncode, self.args,
                                     self.stdout, self.stderr)


class SubprocessError(Exception):
    pass


class CalledProcessError(SubprocessError):
    """Raised when run() with check=True gets a non-zero returncode."""
    def __init__(self, returncode, cmd, output=None, stderr=None):
        self.returncode = returncode
        self.cmd = cmd
        self.output = output
        self.stderr = stderr
        super().__init__("Command " + repr(cmd) + " returned non-zero exit status " + str(returncode))


class TimeoutExpired(SubprocessError):
    """Raised when a timeout expires while waiting for a child process."""
    def __init__(self, cmd, timeout, output=None, stderr=None):
        self.cmd = cmd
        self.timeout = timeout
        self.output = output
        self.stderr = stderr
        super().__init__("Command " + repr(cmd) + " timed out after " + str(timeout) + " seconds")


def run(argv, input=None, capture_output=False, timeout=None,
        check=False, env=None, shell=False,
        stdin=None, stdout=None, stderr=None):
    """Run argv, wait, return CompletedProcess.

    See module docstring for supported kwargs. `env` is currently a
    silent no-op (child inherits parent env). `shell=True` raises.
    """
    if shell:
        raise ValueError("shell=True is not supported")

    # Pass timeout as -1 to signal "no timeout" to the C layer.
    to = -1.0 if timeout is None else float(timeout)

    returncode, out_bytes, err_bytes, timed_out = _subprocess._spawn_and_wait(
        list(argv), input, to, env,
    )

    # Capture semantics: if capture_output=False, drop stdout/stderr
    # so CompletedProcess reports them as None (matches CPython).
    out = out_bytes if capture_output else None
    err = err_bytes if capture_output else None

    if timed_out:
        raise TimeoutExpired(argv, timeout, out, err)

    if check and returncode != 0:
        raise CalledProcessError(returncode, argv, out, err)

    return CompletedProcess(argv, returncode, out, err)


def check_output(argv, **kwargs):
    """Run argv, return stdout bytes. Raise CalledProcessError on non-zero exit."""
    kwargs["capture_output"] = True
    kwargs["check"] = True
    result = run(argv, **kwargs)
    return result.stdout


def call(argv, **kwargs):
    """Run argv, wait, return returncode."""
    return run(argv, **kwargs).returncode
