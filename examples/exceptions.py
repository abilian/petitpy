# Custom exceptions + try/except/finally chains.

class ParseError(Exception):
    def __init__(self, msg, pos):
        super().__init__(msg)
        self.pos = pos


def parse_int(s, base=10):
    if not s:
        raise ParseError("empty input", 0)
    for i, ch in enumerate(s):
        if not (ch.isdigit() or (i == 0 and ch in "+-")):
            raise ParseError(f"unexpected {ch!r}", i)
    return int(s, base)


for sample in ["42", "", "-7", "1a", "+99"]:
    try:
        n = parse_int(sample)
    except ParseError as e:
        print(f"ParseError at {e.pos}: {sample!r}")
    else:
        print(f"OK: {sample!r} → {n}")
    finally:
        pass  # would close a file etc.


# Chained re-raise.
def outer():
    try:
        parse_int("bad")
    except ParseError as e:
        # Re-raise unchanged.
        raise

try:
    outer()
except ParseError as e:
    print("outer caught:", type(e).__name__, "at", e.pos)
