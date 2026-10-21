"""The `.mpy` side: bytecode, the container format, and the buffers that
build them.

Nothing here imports `ast`. This half knows what MicroPython consumes and
nothing about the language that produced it, which is what lets it be
tested — and reused — on its own. `tests/test_layering.py` enforces it.
"""
