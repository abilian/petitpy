# Memory match — kid-style. 4x4 grid of cards. Click to flip; find pairs.
# Uses the new nanopy library APIs from Tier 1 #1-3:
#   - on_click(x, y)        (mouse)
#   - beep(freq, ms)        (sound)
#   - point_in_rect(...)    (collision)
#   - Score                 (reactive widget)
#
# No real-time loop — strictly event-driven. nanopy.run() with no
# update/draw fps still installs the click listener.

import nanopy

# ---- geometry ----
COLS = 4
ROWS = 4
CELL = 90
GAP = 8
PAD = 14
W = COLS * CELL + (COLS + 1) * GAP - 2 * GAP + 2 * PAD

# ---- color palette: 8 distinct colors, each appearing twice ----
COLORS = (
    "red",
    "orange",
    "yellow",
    "green",
    "blue",
    "purple",
    "pink",
    "white",
)

screen = nanopy.canvas("board")

# ---- state ----
deck = []  # 16 ints; same value = matching pair
revealed = [False] * 16  # True if card is face-up (or matched)
matched = [False] * 16  # True if pair is permanently revealed
first_pick = None  # index of the first-flipped card (or None)
score = nanopy.Score("score", storage_key="memory_kid_best", best_id="best")
moves = 0
won = False
# Cooldown after a non-match: temporarily lock input until the player has
# had a moment to look at the mismatch.
_lock_until_tick = 0
_tick_counter = 0


def shuffle_deck():
    # Build [0,0,1,1,2,2,...,7,7] then Fisher-Yates with our 16-bit LCG.
    out = []
    for c in range(8):
        out.append(c)
        out.append(c)
    for i in range(len(out) - 1, 0, -1):
        j = nanopy.randrange(i + 1)
        out[i], out[j] = out[j], out[i]
    return out


def reset():
    global deck, revealed, matched, first_pick, moves, won, _lock_until_tick
    deck = shuffle_deck()
    revealed = [False] * 16
    matched = [False] * 16
    first_pick = None
    moves = 0
    won = False
    _lock_until_tick = 0
    nanopy.set_text("moves", 0)
    score.reset()
    nanopy.status("Click a card to flip it. Find all pairs.", "ok")
    draw()


def card_rect(i):
    """Return the (x, y, w, h) rectangle of card index i (0..15)."""
    r = i // COLS
    c = i % COLS
    x = PAD + c * (CELL + GAP)
    y = PAD + r * (CELL + GAP)
    return (x, y, CELL, CELL)


def card_face(i):
    """The color shown when card i is face-up."""
    return COLORS[deck[i]]


def draw():
    screen.fill("dark")
    for i in range(COLS * ROWS):
        x, y, w, h = card_rect(i)
        if matched[i]:
            # Pair found — show face dimmed.
            screen.rounded_rect(x, y, w, h, 6, card_face(i))
            screen.text(
                "✓",
                x + w // 2,
                y + h // 2,
                "dark",
                size=36,
                align="center",
                baseline="middle",
                bold=True,
            )
        elif revealed[i]:
            # Currently face-up (just flipped, or first of a peek).
            screen.rounded_rect(x, y, w, h, 6, card_face(i))
        else:
            # Face-down.
            screen.rounded_rect(x, y, w, h, 6, "#334155")
            screen.text(
                "?",
                x + w // 2,
                y + h // 2,
                "gray",
                size=32,
                align="center",
                baseline="middle",
                bold=True,
            )
    if won:
        screen.rect(0, W // 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)")
        screen.text(
            "You win!",
            W // 2,
            W // 2 - 10,
            "yellow",
            size=28,
            align="center",
            baseline="middle",
            bold=True,
        )
        screen.text(
            "In " + str(moves) + " moves — click to play again",
            W // 2,
            W // 2 + 18,
            "gray",
            size=14,
            align="center",
            baseline="middle",
        )


def on_click(x, y):
    global first_pick, moves, won, _lock_until_tick
    if won:
        # Click anywhere after winning starts a new round.
        reset()
        return
    if _lock_until_tick > 0:
        return

    # Find which card was clicked (if any).
    for i in range(COLS * ROWS):
        if nanopy.point_in_rect(x, y, card_rect(i)):
            if matched[i] or revealed[i]:
                return
            # Flip this card.
            revealed[i] = True
            nanopy.beep(440, ms=40)
            draw()

            if first_pick is None:
                first_pick = i
                return

            # Second pick.
            moves += 1
            nanopy.set_text("moves", moves)
            if deck[first_pick] == deck[i]:
                # Match — keep both face-up forever, reward the player.
                matched[first_pick] = True
                matched[i] = True
                first_pick = None
                score.add(1)
                nanopy.tone([523, 659, 784], ms_per=80)  # C-E-G arpeggio
                if all(matched):
                    won = True
                    nanopy.status("All pairs found in " + str(moves) + " moves!", "ok")
                    nanopy.tone([523, 659, 784, 1047], ms_per=120)
            else:
                # Mismatch — lock briefly, then re-hide.
                _lock_until_tick = 18
                nanopy.beep(220, ms=120, kind="square")
            draw()
            return


def _tick_handler():
    """Used only for the mismatch-hide cooldown. Decrements every frame
    even when no game logic runs."""
    global _tick_counter, _lock_until_tick, first_pick
    _tick_counter += 1
    if _lock_until_tick > 0:
        _lock_until_tick -= 1
        if _lock_until_tick == 0 and first_pick is not None:
            # Hide the un-matched pair.
            for i in range(COLS * ROWS):
                if revealed[i] and not matched[i]:
                    revealed[i] = False
            first_pick = None
            draw()


# ---- wire-up ----
reset()
nanopy.run(update=_tick_handler, on_click=on_click, fps=30)
