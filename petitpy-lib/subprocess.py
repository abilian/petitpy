"""petitpy — Python wrapper around the low-level `_subprocess`
built-in.

CPython-shaped surface. The low-level primitive lives in the C-side
`_subprocess` module (built via feature-subprocess); this wrapper
handles the kwargs surface, the CompletedProcess / CalledProcessError
/ TimeoutExpired classes, and the `capture_output` sugar.

run() takes CPython's arguments except `shell=True` and `preexec_fn`
and friends: `input`, `capture_output`, `timeout`, `check`, `env`, `cwd`,
`stdin`/`stdout`/`stderr` (PIPE, STDOUT, DEVNULL, a file descriptor or
a file object), and `text`/`universal_newlines`/`encoding`/`errors`.
A command that cannot be run returns 127 rather than raising.

Not supported: `Popen`.
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


INHERIT = -4  # _subprocess's mode for "same as the parent"


def _mode(stream):
    if stream is None:
        return INHERIT
    if isinstance(stream, int):
        return stream
    return stream.fileno()


def run(args, input=None, capture_output=False, timeout=None,
        check=False, env=None, shell=False, cwd=None,
        stdin=None, stdout=None, stderr=None,
        text=None, universal_newlines=None, encoding=None, errors=None):
    """Run args, wait, return CompletedProcess."""
    if shell:
        raise ValueError("shell=True is not supported")
    if capture_output:
        if stdout is not None or stderr is not None:
            raise ValueError("stdout and stderr arguments may not be used with capture_output.")
        stdout = stderr = PIPE
    text = text or universal_newlines or encoding is not None or errors is not None
    if input is not None:
        if text:
            input = input.encode(encoding or "utf-8", errors or "strict")
        stdin = PIPE
    if env is not None:
        env = [k + "=" + v for k, v in env.items()]
    if cwd is not None:
        cwd = str(cwd)

    # Pass timeout as -1 to signal "no timeout" to the C layer.
    to = -1.0 if timeout is None else float(timeout)

    returncode, out, err, timed_out = _subprocess._spawn_and_wait(
        [str(a) for a in args], input, to, env, cwd,
        _mode(stdin), _mode(stdout), _mode(stderr),
    )
    if text:
        out = _decode(out, encoding, errors)
        err = _decode(err, encoding, errors)

    if timed_out:
        raise TimeoutExpired(args, timeout, out, err)

    if check and returncode != 0:
        raise CalledProcessError(returncode, args, out, err)

    return CompletedProcess(args, returncode, out, err)


def _decode(data, encoding, errors):
    if data is None:
        return None
    return data.decode(encoding or "utf-8", errors or "strict").replace("\r\n", "\n").replace("\r", "\n")


def check_output(args, **kwargs):
    """Run args, return its stdout. Raise CalledProcessError on non-zero exit."""
    return run(args, stdout=PIPE, check=True, **kwargs).stdout


def call(args, **kwargs):
    """Run args, wait, return returncode."""
    return run(args, **kwargs).returncode
