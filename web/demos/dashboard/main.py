"""Dashboard demo — Python-dominant via persistent wasm + js bridge.

One wasm instance is started by ``app.js`` on page load. Python:
  - owns the sales data (embedded inline below — no fetch),
  - aggregates per region / per month / top performers,
  - draws every chart by calling ``ctx.fillRect`` / ``beginPath`` /
    ``moveTo`` / ``lineTo`` / ``stroke`` / ``fillText`` through the
    ADR-006 ``js`` bridge,
  - writes KPI text and table rows back into the DOM,
  - wires the region filter buttons via ``addEventListener("click", py_fn)``.

After ``main.py`` returns, the bridge JS keeps ``wasmExports`` alive so
the registered Python click handlers keep firing for the page's lifetime.
"""

import js

# ============================================================================
# Data (embedded — was data.json in the prior design)
# ============================================================================

DATA = [
    {"region": "North", "month": "Jan", "sales": 12500, "units": 150},
    {"region": "North", "month": "Feb", "sales": 14200, "units": 168},
    {"region": "North", "month": "Mar", "sales": 13800, "units": 162},
    {"region": "North", "month": "Apr", "sales": 15600, "units": 185},
    {"region": "North", "month": "May", "sales": 16800, "units": 198},
    {"region": "North", "month": "Jun", "sales": 18200, "units": 215},
    {"region": "South", "month": "Jan", "sales": 9800, "units": 112},
    {"region": "South", "month": "Feb", "sales": 11200, "units": 128},
    {"region": "South", "month": "Mar", "sales": 10500, "units": 120},
    {"region": "South", "month": "Apr", "sales": 12800, "units": 145},
    {"region": "South", "month": "May", "sales": 14200, "units": 162},
    {"region": "South", "month": "Jun", "sales": 15800, "units": 180},
    {"region": "East", "month": "Jan", "sales": 8500, "units": 95},
    {"region": "East", "month": "Feb", "sales": 9200, "units": 102},
    {"region": "East", "month": "Mar", "sales": 10100, "units": 115},
    {"region": "East", "month": "Apr", "sales": 11500, "units": 130},
    {"region": "East", "month": "May", "sales": 12800, "units": 145},
    {"region": "East", "month": "Jun", "sales": 14200, "units": 162},
    {"region": "West", "month": "Jan", "sales": 11200, "units": 125},
    {"region": "West", "month": "Feb", "sales": 12500, "units": 140},
    {"region": "West", "month": "Mar", "sales": 11800, "units": 132},
    {"region": "West", "month": "Apr", "sales": 13200, "units": 148},
    {"region": "West", "month": "May", "sales": 14800, "units": 165},
    {"region": "West", "month": "Jun", "sales": 16500, "units": 185},
]

MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
REGIONS = ["North", "South", "East", "West"]
FILTER_OPTIONS = ["all"] + REGIONS

COLORS = ["#7aa2f7", "#9ece6a", "#e0af68", "#f7768e", "#bb9af7", "#7dcfff"]
BG = "#1e293b"
FG = "#e2e8f0"
FG_DIM = "#94a3b8"
GRID = "#334155"


# ============================================================================
# Aggregation
# ============================================================================


def filter_rows(rows, region):
    if region == "all":
        return rows
    return [r for r in rows if r["region"] == region]


def sales_by_region(rows):
    totals = {}
    for r in rows:
        totals[r["region"]] = totals.get(r["region"], 0) + r["sales"]
    return [(reg, totals.get(reg, 0)) for reg in REGIONS if reg in totals]


def sales_by_month(rows):
    totals = {}
    for r in rows:
        totals[r["month"]] = totals.get(r["month"], 0) + r["sales"]
    return [(m, totals.get(m, 0)) for m in MONTHS if m in totals]


def monthly_trend(rows, region):
    """Return list of 6 ints (Jan..Jun sales) for the given region."""
    out = [0] * len(MONTHS)
    for r in rows:
        if r["region"] != region:
            continue
        i = MONTHS.index(r["month"])
        out[i] += r["sales"]
    return out


def top_performers(rows, n=10):
    return sorted(rows, key=lambda x: x["sales"], reverse=True)[:n]


def compute_kpis(rows):
    total_sales = sum(r["sales"] for r in rows)
    total_units = sum(r["units"] for r in rows)
    if total_units > 0:
        avg_cents = (total_sales * 100) // total_units
        avg_order = f"{avg_cents // 100}.{avg_cents % 100:02d}"
    else:
        avg_order = "0.00"
    best_month = 0
    for _, v in sales_by_month(rows):
        if v > best_month:
            best_month = v
    return total_sales, total_units, avg_order, best_month


# ============================================================================
# Canvas helpers — drive the 2D context through the js bridge
# ============================================================================


def get_ctx(canvas_id):
    canvas = js.document.getElementById(canvas_id)
    ctx = canvas.getContext("2d")
    w = canvas.width.to_int()
    h = canvas.height.to_int()
    return ctx, w, h


def clear(ctx, w, h):
    ctx.fillStyle = BG
    ctx.fillRect(0, 0, w, h)


def title(ctx, text):
    ctx.fillStyle = FG
    ctx.font = "bold 14px system-ui"
    ctx.textAlign = "left"
    ctx.fillText(text, 16, 22)


def format_money(n):
    """Insert thousands separators: 12500 -> '12,500'."""
    s = str(n)
    out = []
    for i, c in enumerate(reversed(s)):
        if i and i % 3 == 0:
            out.append(",")
        out.append(c)
    return "".join(reversed(out))


# ============================================================================
# Chart drawers
# ============================================================================


def draw_bar(canvas_id, data, heading):
    """Horizontal bar chart: [(label, value), ...]."""
    ctx, w, h = get_ctx(canvas_id)
    clear(ctx, w, h)
    title(ctx, heading)

    if not data:
        return
    max_val = max(v for _, v in data) or 1
    pad_x = 80
    pad_y = 40
    chart_w = w - pad_x - 80
    gap = 10
    bar_h = (h - pad_y - 10 - gap * len(data)) // len(data)
    if bar_h > 30:
        bar_h = 30

    ctx.font = "12px system-ui"
    for i, (label, val) in enumerate(data):
        y = pad_y + i * (bar_h + gap)
        bw = (val * chart_w) // max_val
        ctx.fillStyle = COLORS[i % len(COLORS)]
        ctx.fillRect(pad_x, y, bw, bar_h)

        ctx.fillStyle = FG_DIM
        ctx.textAlign = "right"
        ctx.fillText(label, pad_x - 8, y + bar_h // 2 + 4)

        ctx.fillStyle = FG
        ctx.textAlign = "left"
        ctx.fillText("$" + format_money(val), pad_x + bw + 8, y + bar_h // 2 + 4)


def draw_stacked(canvas_id, data, heading):
    """Single horizontal stacked bar: [(label, value), ...] -> shares of total.

    Uses fillRect-only — no arcs, no transcendentals — so it works on the
    nano build whether or not floats are present.
    """
    ctx, w, h = get_ctx(canvas_id)
    clear(ctx, w, h)
    title(ctx, heading)

    total = sum(v for _, v in data)
    if total <= 0:
        return

    pad_x = 24
    bar_y = 60
    bar_h = 36
    chart_w = w - pad_x * 2
    x = pad_x
    for i, (_, val) in enumerate(data):
        seg = (val * chart_w) // total
        # Make sure the last segment fills any rounding remainder.
        if i == len(data) - 1:
            seg = pad_x + chart_w - x
        ctx.fillStyle = COLORS[i % len(COLORS)]
        ctx.fillRect(x, bar_y, seg, bar_h)
        x += seg

    # Legend: two columns of "swatch label (pct%)" rows.
    ctx.font = "12px system-ui"
    ctx.textAlign = "left"
    leg_y = bar_y + bar_h + 28
    col_w = (w - pad_x * 2) // 2
    for i, (label, val) in enumerate(data):
        col = i % 2
        row = i // 2
        sx = pad_x + col * col_w
        sy = leg_y + row * 22
        ctx.fillStyle = COLORS[i % len(COLORS)]
        ctx.fillRect(sx, sy - 10, 12, 12)
        pct = (val * 100) // total
        ctx.fillStyle = FG
        ctx.fillText(f"{label} ({pct}%)", sx + 20, sy)


def draw_lines(canvas_id, series, heading):
    """Multi-line chart: series = [(label, [v0..v5]), ...]."""
    ctx, w, h = get_ctx(canvas_id)
    clear(ctx, w, h)
    title(ctx, heading)

    pad_x = 50
    pad_y = 40
    chart_w = w - pad_x - 20
    chart_h = h - pad_y - 40
    n_pts = len(MONTHS)

    max_val = 1
    for _, vals in series:
        for v in vals:
            if v > max_val:
                max_val = v

    def xpos(i):
        return pad_x + (i * chart_w) // (n_pts - 1)

    def ypos(v):
        return pad_y + chart_h - (v * chart_h) // max_val

    # Grid lines.
    ctx.strokeStyle = GRID
    ctx.lineWidth = 1
    for i in range(5):
        y = pad_y + (i * chart_h) // 4
        ctx.beginPath()
        ctx.moveTo(pad_x, y)
        ctx.lineTo(w - 20, y)
        ctx.stroke()

    # X-axis labels.
    ctx.fillStyle = FG_DIM
    ctx.font = "11px system-ui"
    ctx.textAlign = "center"
    for i, m in enumerate(MONTHS):
        ctx.fillText(m, xpos(i), h - 15)

    # Lines + point dots — using moveTo/lineTo only (no arcs).
    for idx, (_, vals) in enumerate(series):
        color = COLORS[idx % len(COLORS)]
        ctx.strokeStyle = color
        ctx.lineWidth = 2
        ctx.beginPath()
        for i, v in enumerate(vals):
            x = xpos(i)
            y = ypos(v)
            if i == 0:
                ctx.moveTo(x, y)
            else:
                ctx.lineTo(x, y)
        ctx.stroke()

        # Point markers as tiny filled rects (avoids arc()).
        ctx.fillStyle = color
        for i, v in enumerate(vals):
            x = xpos(i)
            y = ypos(v)
            ctx.fillRect(x - 3, y - 3, 6, 6)

    # Legend.
    ctx.font = "11px system-ui"
    ctx.textAlign = "left"
    for idx, (label, _) in enumerate(series):
        y = 45 + idx * 18
        ctx.fillStyle = COLORS[idx % len(COLORS)]
        ctx.fillRect(w - 100, y - 10, 12, 12)
        ctx.fillStyle = FG
        ctx.fillText(label, w - 82, y)


# ============================================================================
# KPI + table rendering
# ============================================================================


def set_text(el_id, text):
    el = js.document.getElementById(el_id)
    el.textContent = text


def render_kpis(total_sales, total_units, avg_order, best_month):
    set_text("kpi-total-sales", "$" + format_money(total_sales))
    set_text("kpi-total-units", format_money(total_units))
    set_text("kpi-avg-order", "$" + avg_order)
    set_text("kpi-best-month", "$" + format_money(best_month))


def render_table(rows):
    tbody = js.document.getElementById("data-table-body")
    tbody.innerHTML = ""
    for r in rows:
        tr = js.document.createElement("tr")
        td_region = js.document.createElement("td")
        td_region.textContent = r["region"]
        td_month = js.document.createElement("td")
        td_month.textContent = r["month"]
        td_sales = js.document.createElement("td")
        td_sales.textContent = "$" + format_money(r["sales"])
        td_units = js.document.createElement("td")
        td_units.textContent = str(r["units"])
        tr.appendChild(td_region)
        tr.appendChild(td_month)
        tr.appendChild(td_sales)
        tr.appendChild(td_units)
        tbody.appendChild(tr)


# ============================================================================
# Refresh / filter wiring
# ============================================================================

_current_filter = "all"


def refresh():
    rows = filter_rows(DATA, _current_filter)
    total_sales, total_units, avg_order, best_month = compute_kpis(rows)
    render_kpis(total_sales, total_units, avg_order, best_month)
    draw_bar("chart-region", sales_by_region(rows), "Sales by region")
    draw_stacked("chart-month", sales_by_month(rows), "Sales by month")

    if _current_filter == "all":
        series = [(r, monthly_trend(rows, r)) for r in REGIONS]
    else:
        series = [(_current_filter, monthly_trend(rows, _current_filter))]
    draw_lines("chart-trend", series, "Monthly trend")

    render_table(top_performers(rows, 10))

    status = js.document.getElementById("status")
    status.textContent = f"Done. Filter: {_current_filter}."
    status.classList.add("ok")
    status.classList.remove("err")


def make_filter_handler(region):
    """Closure factory — capture the region for each filter button."""

    def handler(event=None):
        global _current_filter
        _current_filter = region
        # Update .active class on all filter buttons.
        buttons = js.document.querySelectorAll(".filter-btn")
        n = buttons.length.to_int()
        for i in range(n):
            btn = buttons.item(i)
            if btn.dataset.region.to_str() == region:
                btn.classList.add("active")
            else:
                btn.classList.remove("active")
        refresh()

    return handler


def build_filters():
    filters = js.document.getElementById("filters")
    for region in FILTER_OPTIONS:
        btn = js.document.createElement("button")
        btn.type = "button"
        btn.textContent = "All regions" if region == "all" else region
        btn.set(
            "className", "secondary filter-btn" + (" active" if region == "all" else "")
        )
        btn.dataset.region = region
        btn.addEventListener("click", make_filter_handler(region))
        filters.appendChild(btn)


# ============================================================================
# Entry — wire filters once, draw the initial view.
# ============================================================================

build_filters()
refresh()
