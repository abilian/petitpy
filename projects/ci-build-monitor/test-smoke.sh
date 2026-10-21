#!/usr/bin/env bash
# test-smoke.sh — TDD smoke suite for user-reported issues.
#
# Drives the headless-Chromium smoke harness against the ci-build-monitor
# pages, one test per user-reported issue. Each test prints a single
# `[T<n>] PASS|FAIL` line with a short assertion and the relevant slice
# of actual output, then the suite tallies pass/fail.
#
# Seeding strategy: each Playwright invocation gets a FRESH browser
# context (localStorage does NOT persist across `python3
# browser-smoke.py` calls). So tests that need pre-seeded storage must
# do BOTH the seed AND the observation inside the SAME invocation:
#
#   1. Load .smoke-seed.html (a tiny same-origin warm-up page).
#   2. --eval to write `localStorage["ci-build-monitor-storage"]`.
#   3. --eval to set window.location.href to the page under test
#      (popup.html, options.html, status.html).
#   4. --sleep long enough for the wasm/Python bootstrap to settle.
#   5. --eval / --click to observe behaviour. The chrome-shim reads
#      the seeded key on bootstrap.

set -u  # NB: intentionally NOT -e — every test must run even after a failure.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
SMOKE="${REPO_ROOT}/tools/browser-smoke.py"

# Long-lived static server: we don't need it for cross-invocation state
# (Playwright wipes that anyway), but it does mean every test can use a
# stable BASE URL without re-spinning the harness's --serve.
#
# We run serve.py (not http.server) so the /proxy/ endpoint is available
# for T3's Test Connection check — without it, builds.sr.ht / GitHub /
# GitLab CORS-block the localhost fetch and we'd never see a real result.
pick_port() {
    python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()"
}
PORT=$(pick_port)
( cd "${SCRIPT_DIR}" && python3 serve.py "${PORT}" >/dev/null 2>&1 ) &
SERVER_PID=$!

# A tiny same-origin seed page so each test can set localStorage before
# navigating to the page under test (same-origin requirement).
SEED_PAGE="${SCRIPT_DIR}/.smoke-seed.html"
printf '<!doctype html><html><body>seed</body></html>\n' > "${SEED_PAGE}"

trap 'kill ${SERVER_PID} 2>/dev/null || true; rm -f "${SEED_PAGE}"' EXIT

# Wait for the server to come up (up to ~5s).
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf "http://127.0.0.1:${PORT}/popup.html" -o /dev/null; then break; fi
    sleep 0.5
done

BASE="http://127.0.0.1:${PORT}"
PASS=0
FAIL=0

# Helper: report a test result.
#   $1 = test id (T1..T8)
#   $2 = "PASS" or "FAIL"
#   $3 = assertion summary
#   $4 = (optional) actual evidence
report() {
    local tid="$1" status="$2" assertion="$3" actual="${4:-}"
    if [[ "${status}" == "PASS" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
    printf '[%s] %s — %s\n' "${tid}" "${status}" "${assertion}"
    if [[ -n "${actual}" ]]; then
        printf '        actual: %s\n' "${actual}" | head -c 2000
        printf '\n'
    fi
}

# Helper: run smoke harness and capture combined output.
run_smoke() { python3 "${SMOKE}" "$@" 2>&1; }

# Helper: tail [eval] lines and pick the Nth-from-last (default last).
#   $1 = output blob, $2 = optional 1-based-from-end position (default 1)
last_eval() {
    local out="$1" pos="${2:-1}"
    printf '%s\n' "${out}" | grep -E '^\[eval\]' | tail -"${pos}" | head -1
}

# Helper: dump body lines from an OUT blob.
body_text() {
    printf '%s\n' "$1" | grep -E '^\[body\]' | sed 's/^\[body\]  //'
}

# Helper: emit step-flags that seed localStorage then navigate. The
# JSON payload is passed as one shell arg so the caller controls quoting.
#   $1 = JSON storage object as JS string (e.g. '\''{"repos":[...]}'\'' literal)
#   $2 = target page (popup.html, options.html, status.html)
# Prints space-separated --eval args ready to splice into a run_smoke call.

# ============================================================
# T1. POPUP: Open Dashboard button navigates to status.html
# ============================================================
# Seed one repo so the popup shows main-content (otherwise Open Dashboard
# is hidden behind #empty-state).
OUT=$(run_smoke "${BASE}/.smoke-seed.html" \
    --eval "localStorage.setItem('ci-build-monitor-storage', '{\"repos\":[{\"id\":\"r1\",\"provider\":\"sourcehut\",\"identifier\":\"sfermigier\",\"enabled\":true,\"lastChecked\":0}]}')" \
    --eval "window.location.href='/popup.html'" \
    --sleep 5000 \
    --click "#dashboard-btn" \
    --sleep 1500 \
    --eval "window.location.pathname")
EVAL_LINE=$(last_eval "${OUT}")
if printf '%s' "${EVAL_LINE}" | grep -q 'status.html'; then
    report T1 PASS "Open Dashboard navigates to status.html" "${EVAL_LINE}"
else
    report T1 FAIL "Open Dashboard should navigate to status.html" "${EVAL_LINE:-<no [eval] output>}"
fi

# ============================================================
# T2. POPUP: Refresh button produces VISIBLE feedback
# ============================================================
# The user-visible symptom was "click Refresh, nothing happens". A
# no-error smoke is insufficient: the click handler must mutate
# something the user can see. We capture the status-summary text
# BEFORE the click (expected: "All repos passing" for the seeded ok
# repo) and IMMEDIATELY after, and assert it changed to the
# "Refreshing..." state. We also still guard against pageerrors and
# verify the button is still in the DOM.
OUT=$(run_smoke "${BASE}/.smoke-seed.html" \
    --eval "localStorage.setItem('ci-build-monitor-storage', '{\"repos\":[{\"id\":\"r1\",\"provider\":\"sourcehut\",\"identifier\":\"sfermigier\",\"enabled\":true,\"lastChecked\":0}],\"repositories\":{\"r1\":{\"build-monitor\":{\"name\":\"build-monitor\",\"owner\":\"sfermigier\",\"provider\":\"sourcehut\",\"status\":\"ok\",\"commits\":[],\"url\":\"https://example.com/sfermigier/build-monitor\"}}}}')" \
    --eval "window.location.href='/popup.html'" \
    --sleep 5000 \
    --eval "document.querySelector('#status-summary .status-text').textContent" \
    --click "#refresh-btn" \
    --eval "document.querySelector('#status-summary .status-text').textContent" \
    --eval "!!document.getElementById('refresh-btn')")
PAGEERR=$(printf '%s\n' "${OUT}" | grep -E '^\[pageerror\]' | head -1)
# Three [eval] lines: pre-click status, post-click status, button-presence.
BEFORE=$(last_eval "${OUT}" 3)
AFTER=$(last_eval "${OUT}" 2)
BTN=$(last_eval "${OUT}" 1)
if [[ -n "${PAGEERR}" ]]; then
    report T2 FAIL "Refresh click triggered a pageerror" "${PAGEERR}"
elif ! printf '%s' "${BTN}" | grep -qE '(True|true)'; then
    report T2 FAIL "Refresh-btn missing after click" "${BTN:-<no [eval]>}"
elif printf '%s' "${AFTER}" | grep -qi 'Refreshing'; then
    report T2 PASS "Refresh click changed status text to 'Refreshing...'" "before=${BEFORE} after=${AFTER}"
elif [[ "${BEFORE}" != "${AFTER}" ]]; then
    report T2 PASS "Refresh click changed visible status text" "before=${BEFORE} after=${AFTER}"
else
    report T2 FAIL "Refresh click produced no visible state change" "before=${BEFORE} after=${AFTER}"
fi

# ============================================================
# T3. OPTIONS: Test Connection — Connection successful end-to-end
# ============================================================
# With serve.py providing the /proxy/ tunnel, the page-side fetch to
# builds.sr.ht actually completes. We expect the success branch,
# not a CORS NetworkError. Identifier "sfermigier" is a long-lived
# upstream account with a stable RSS feed (no auth needed).
OUT=$(run_smoke "${BASE}/.smoke-seed.html" \
    --eval "localStorage.removeItem('ci-build-monitor-storage')" \
    --eval "window.location.href='/options.html'" \
    --sleep 5000 \
    --type "#identifier=sfermigier" \
    --click "#test-btn" \
    --sleep 6000 \
    --eval "document.getElementById('status-message').textContent")
EVAL_LINE=$(last_eval "${OUT}")
if printf '%s' "${EVAL_LINE}" | grep -q 'Connection successful'; then
    report T3 PASS "Test Connection succeeded end-to-end via /proxy/" "${EVAL_LINE}"
else
    report T3 FAIL "Test Connection should report 'Connection successful'" "${EVAL_LINE:-<no message>}"
fi

# ============================================================
# T4. OPTIONS: Adding the same repo twice triggers a duplicate error
# ============================================================
OUT=$(run_smoke "${BASE}/.smoke-seed.html" \
    --eval "localStorage.removeItem('ci-build-monitor-storage')" \
    --eval "window.location.href='/options.html'" \
    --sleep 5000 \
    --type "#identifier=dup-victim" \
    --click "#add-btn" \
    --sleep 1500 \
    --type "#identifier=dup-victim" \
    --click "#add-btn" \
    --sleep 1500 \
    --eval "document.getElementById('status-message').textContent")
EVAL_LINE=$(last_eval "${OUT}")
if printf '%s' "${EVAL_LINE}" | grep -qiE '(already|duplicate|exists)'; then
    report T4 PASS "Adding same repo twice shows duplicate error" "${EVAL_LINE}"
else
    report T4 FAIL "Duplicate repo should trigger error" "${EVAL_LINE:-<no message>}"
fi

# ============================================================
# T5. OPTIONS: Delete button removes the repo
# ============================================================
OUT=$(run_smoke "${BASE}/.smoke-seed.html" \
    --eval "localStorage.setItem('ci-build-monitor-storage', '{\"repos\":[{\"id\":\"victim1\",\"provider\":\"sourcehut\",\"identifier\":\"victim/repo\",\"enabled\":true,\"lastChecked\":0}]}')" \
    --eval "window.location.href='/options.html'" \
    --sleep 5000 \
    --click "#repo-list .repo-item .btn-danger" \
    --sleep 2000 \
    --eval "document.getElementById('repo-list').textContent")
EVAL_LINE=$(last_eval "${OUT}")
if printf '%s' "${EVAL_LINE}" | grep -q 'victim/repo'; then
    report T5 FAIL "Delete should remove 'victim/repo' from repo list" "${EVAL_LINE}"
else
    report T5 PASS "Delete removed 'victim/repo' from repo list" "${EVAL_LINE}"
fi

# ============================================================
# T6. OPTIONS: Check interval has a default value (5)
# ============================================================
OUT=$(run_smoke "${BASE}/.smoke-seed.html" \
    --eval "localStorage.removeItem('ci-build-monitor-storage')" \
    --eval "window.location.href='/options.html'" \
    --sleep 5000 \
    --eval "document.getElementById('check-interval').value")
EVAL_LINE=$(last_eval "${OUT}")
# The eval result line looks like: "[eval]  5"
if printf '%s' "${EVAL_LINE}" | grep -qE '^\[eval\][[:space:]]+5$'; then
    report T6 PASS "Default check interval is 5" "${EVAL_LINE}"
else
    report T6 FAIL "Default check interval should be 5" "${EVAL_LINE:-<no value>}"
fi

# ============================================================
# T7. OPTIONS: Change check interval, reload, value persists
# ============================================================
# Same-invocation: set to 15, save, navigate again, observe.
OUT=$(run_smoke "${BASE}/.smoke-seed.html" \
    --eval "localStorage.removeItem('ci-build-monitor-storage')" \
    --eval "window.location.href='/options.html'" \
    --sleep 5000 \
    --select "#check-interval=15" \
    --click "#save-settings-btn" \
    --sleep 2000 \
    --eval "window.location.href='/options.html'" \
    --sleep 5000 \
    --eval "document.getElementById('check-interval').value")
EVAL_LINE=$(last_eval "${OUT}")
if printf '%s' "${EVAL_LINE}" | grep -qE '^\[eval\][[:space:]]+15$'; then
    report T7 PASS "Check interval (15) persists across reload" "${EVAL_LINE}"
else
    report T7 FAIL "Check interval should persist as 15 across reload" "${EVAL_LINE:-<no value>}"
fi

# ============================================================
# T8. STATUS: Dashboard shows seeded repos, NOT "No build data yet"
# ============================================================
# Seed `repos` AND `repositories` so the dashboard has source config AND
# a representative repo. The body should mention "sfermigier" and must
# NOT show the empty-state strings.
OUT=$(run_smoke "${BASE}/.smoke-seed.html" \
    --eval "localStorage.setItem('ci-build-monitor-storage', '{\"repos\":[{\"id\":\"src1\",\"provider\":\"sourcehut\",\"identifier\":\"sfermigier\",\"enabled\":true,\"lastChecked\":0}],\"repositories\":{\"src1\":{\"build-monitor\":{\"name\":\"build-monitor\",\"owner\":\"sfermigier\",\"provider\":\"sourcehut\",\"status\":\"ok\",\"commits\":[],\"url\":\"https://example.com/sfermigier/build-monitor\"}}}}')" \
    --eval "window.location.href='/status.html'" \
    --sleep 6000 \
    --eval "document.body.textContent")
EVAL_LINE=$(last_eval "${OUT}")
HAS_REPO=0
HAS_EMPTY=0
if printf '%s' "${EVAL_LINE}" | grep -q 'sfermigier'; then HAS_REPO=1; fi
if printf '%s' "${EVAL_LINE}" | grep -qE '(No build data yet|No repositories)'; then HAS_EMPTY=1; fi
if [[ "${HAS_REPO}" == "1" && "${HAS_EMPTY}" == "0" ]]; then
    report T8 PASS "Dashboard shows seeded repo, not empty state" "${EVAL_LINE}"
else
    report T8 FAIL "Dashboard should show 'sfermigier' and NOT 'No build data yet'" "${EVAL_LINE}"
fi

# ============================================================
# T9. POPUP: Refresh actually fetches CI data in standalone mode
# ============================================================
# Regression guard for the chrome.runtime.sendMessage no-op bug.
# Pre-fix, clicking Refresh dispatched a chrome.runtime.sendMessage
# that the standalone-web shim ignores — no background worker exists
# to receive the message — so no fetch ever happened and the popup
# silently re-rendered with the same (empty) state. The fix runs the
# provider fetch + persist loop in the popup itself.
#
# We assert two ground-truth signals: the provider's "Fetching RSS"
# log line confirms an outbound request was made on click, and the
# post-settle status-text must show real CI data — "passing",
# "failing", or "need attention" — proving the re-render reflects
# whatever storage we wrote. 12s covers the /proxy/ fetch, RSS
# parse, storage write, and re-render.
OUT=$(run_smoke "${BASE}/.smoke-seed.html" \
    --eval "localStorage.setItem('ci-build-monitor-storage', '{\"repos\":[{\"id\":\"r1\",\"provider\":\"sourcehut\",\"identifier\":\"sfermigier\",\"enabled\":true,\"lastChecked\":0}]}')" \
    --eval "window.location.href='/popup.html'" \
    --sleep 5000 \
    --click "#refresh-btn" \
    --sleep 15000 \
    --eval "JSON.stringify(JSON.parse(localStorage.getItem('ci-build-monitor-storage') || '{}')).indexOf('\"repositories\"') > -1 ? 'PERSISTED' : 'NOT_PERSISTED'")
EVAL_LINE=$(last_eval "${OUT}" 1)
FETCH_LOG=$(printf '%s\n' "${OUT}" | grep -E '\[log\].*Fetching RSS' | head -1)
# Strict assertion: provider made the call AND fetched data was actually
# persisted under the "repositories" key. Loose body-grep was passing
# even when the Promise.then never fired because the seeded repo name
# was already in the rendered body.
if [[ -z "${FETCH_LOG}" ]]; then
    report T9 FAIL "Refresh should trigger a provider fetch (no 'Fetching RSS' log)" "eval=${EVAL_LINE}"
elif printf '%s' "${EVAL_LINE}" | grep -q 'PERSISTED'; then
    report T9 PASS "Popup Refresh fetched and persisted real CI data to storage" "fetch=${FETCH_LOG}"
else
    report T9 FAIL "Refresh fetched but did not persist 'repositories' to storage" "fetch=${FETCH_LOG} eval=${EVAL_LINE}"
fi

# ============================================================
# T10. DASHBOARD: Refresh Now actually fetches CI data
# ============================================================
# Same family as T9, but for status.html's "Refresh Now" button.
# User reported clicking it logged "Triggering manual refresh..."
# but the dashboard never updated. Pre-fix, refresh_now() in
# pages_status.py only sent chrome.runtime.sendMessage (no listener
# in standalone). The fix runs the provider fetch + persist loop in
# the dashboard too, then calls load_data() to re-render.
OUT=$(run_smoke "${BASE}/.smoke-seed.html" \
    --eval "localStorage.setItem('ci-build-monitor-storage', '{\"repos\":[{\"id\":\"r1\",\"provider\":\"sourcehut\",\"identifier\":\"sfermigier\",\"enabled\":true,\"lastChecked\":0}]}')" \
    --eval "window.location.href='/status.html'" \
    --sleep 5000 \
    --click "#refresh-btn" \
    --sleep 15000 \
    --eval "JSON.stringify(JSON.parse(localStorage.getItem('ci-build-monitor-storage') || '{}')).indexOf('\"repositories\"') > -1 ? 'PERSISTED' : 'NOT_PERSISTED'")
EVAL_LINE=$(last_eval "${OUT}" 1)
FETCH_LOG=$(printf '%s\n' "${OUT}" | grep -E '\[log\].*Fetching RSS' | head -1)
# Strict assertion: provider made the call AND new data was actually
# persisted to storage under the "repositories" key (not just that the
# seeded repo name appears somewhere — the loose check that masked the
# Python-dict-to-JS-attr marshaling bug for several sessions).
if [[ -z "${FETCH_LOG}" ]]; then
    report T10 FAIL "Refresh Now should trigger a provider fetch (no 'Fetching RSS' log)" "eval=${EVAL_LINE}"
elif printf '%s' "${EVAL_LINE}" | grep -q 'PERSISTED'; then
    report T10 PASS "Dashboard Refresh fetched and persisted real CI data to storage" "fetch=${FETCH_LOG}"
else
    report T10 FAIL "Refresh fetched but did not persist 'repositories' to storage" "fetch=${FETCH_LOG} eval=${EVAL_LINE}"
fi

# ============================================================
# Tally
# ============================================================
TOTAL=$((PASS+FAIL))
printf '\n=== smoke summary: %d passed, %d failed (of %d) ===\n' "${PASS}" "${FAIL}" "${TOTAL}"
if [[ "${FAIL}" -gt 0 ]]; then exit 1; fi
exit 0
