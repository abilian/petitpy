# CI Build Monitor - Dashboard Page
# Shows repository status with actionable, glanceable information

import js

from core_utils import create_obj
from providers_github import GitHubProvider
from providers_gitlab import GitLabProvider
from providers_sourcehut import SourcehutProvider
from services_storage import get_all_storage
from ui_badges import create_provider_badge, create_status_dot
from ui_dom import get_element, get_prop, js_str_attr
from ui_formatters import format_relative_time
from ui_repo_helpers import get_full_repo_name, get_repo_url, is_repo_sleeping

# Provider registry — mirrors pages_popup.PROVIDERS so the dashboard
# can fetch directly in standalone-web mode where there is no
# background service worker to receive chrome.runtime.sendMessage.
PROVIDERS = {
    "sourcehut": SourcehutProvider,
    "github": GitHubProvider,
    "gitlab": GitLabProvider,
}

# JS-side helper to merge a per-source bucket into chrome.storage's
# "repositories" object. Same pattern as pages_popup.
_persist_repos = js.get("eval")(
    "(function(sourceId, bucket){"
    "  return chrome.storage.local.get('repositories').then(function(r){"
    "    var all = (r && r.repositories) ? r.repositories : {};"
    "    all[sourceId] = bucket;"
    "    return chrome.storage.local.set({repositories: all});"
    "  });"
    "})"
)

# chrome is not pre-instantiated in petitpy-lib/js.py; fetch the global
# once at module load and reuse. See projects/ci-build-monitor/notes/PORTING.md.
chrome = js.get("chrome")

# `chrome.storage.local.get(null)` returns every key, but Python `None`
# can't cross the js bridge (raises TypeError on _marshal). Route through
# a JS-side wrapper that passes the real `null`. Same pattern as
# pages_options.py.

# `JsProxy.set(name, value)` is a Python method that shadows JS-side
# `.set` attribute lookup, so `chrome.storage.local.set(data)` calls the
# explicit Python setter (which takes two args) and trips "argument
# num/types mismatch". Route storage writes through a JS-side wrapper.
# Same pattern as pages_options.py.
_storage_set = js.get("eval")("(function(d){return chrome.storage.local.set(d);})")

# Real-world epoch-ms timestamps (~1.7e12) exceed the nano smallint cap
# (~5.4e8 == 2^29-1), so a raw `JsProxy.to_int()` raises OverflowError.
# Sorting timestamps across repos / commits / builds only needs the
# relative order, not the absolute value. Project each ts onto a smaller
# domain JS-side (seconds since 2020-01-01) so the result always fits a
# 30-bit smallint. (2020 epoch in seconds is 1.577e9; subtracting that
# from current epoch-seconds gives values starting at zero and growing
# at 1 unit/second — fits the 5.4e8 cap for ~17 years.)
_safe_ts = js.get("eval")(
    "(function(ts){if(ts==null)return 0;"
    "var s=Math.floor(ts/1000)-1577836800;"
    "if(s<0)s=0;if(s>536870911)s=536870911;return s;})"
)


def safe_ts(ts):
    """Coerce a possibly-large epoch ms (JsProxy or int) into a Python int
    that fits the nano smallint floor while preserving sort order.

    Used wherever a timestamp crosses the bridge into Python arithmetic.
    """
    if ts is None:
        return 0
    return _safe_ts(ts).to_int()

# `JSON.stringify(o, None, 2)` can't be called from Python because the
# bridge's _marshal rejects None. Route through a JS-side wrapper that
# passes the real `null` for the replacer. Same pattern as
# pages_options.py.
_stringify_pretty = js.get("eval")("(function(o){return JSON.stringify(o,null,2);})")


# ============================================================
# Common Helper Functions
# ============================================================


def find_source_config(sources, source_id):
    """Find source config by ID. Returns (provider, identifier).

    `sources` may be either a Python list (empty fallback) or a JsProxy
    array (from chrome.storage). JsProxy has no __len__ or __getitem__,
    so probe length via the `length` property and index via getattr.
    """
    provider = "unknown"
    identifier = source_id
    if not sources:
        return provider, identifier

    # Detect JsProxy: has a `.length` attribute (returns JsProxy(number)).
    if hasattr(sources, "_h"):
        n = sources.length.to_int()
        idx = 0
        while idx < n:
            src = getattr(sources, str(idx))
            if coerce_str(get_prop(src, "id", "")) == source_id:
                provider = coerce_str(get_prop(src, "provider", "unknown"))
                identifier = coerce_str(get_prop(src, "identifier", source_id))
                break
            idx = idx + 1
    else:
        # Plain Python list path (empty fallback).
        idx = 0
        while idx < len(sources):
            src = sources[idx]
            if get_prop(src, "id", "") == source_id:
                provider = get_prop(src, "provider", "unknown")
                identifier = get_prop(src, "identifier", source_id)
                break
            idx = idx + 1
    return provider, identifier


def sort_by_timestamp_desc(items_list, key_fn):
    """Sort a list by timestamp descending (newest first) using bubble sort."""
    n = len(items_list)
    i = 0
    while i < n:
        j = 0
        while j < n - i - 1:
            ts1 = key_fn(items_list[j])
            ts2 = key_fn(items_list[j + 1])
            if ts1 < ts2:
                temp = items_list[j]
                items_list[j] = items_list[j + 1]
                items_list[j + 1] = temp
            j = j + 1
        i = i + 1


def coerce_str(value):
    """Coerce a value that may be JsProxy or native str/None to a Python str.

    Used when we need to do Python string ops (slicing, len, find) on a
    value that may have crossed the bridge as JsProxy.
    """
    if value is None:
        return ""
    if hasattr(value, "to_str"):
        return value.to_str()
    return value


def _is_jsproxy(v):
    """True if `v` is a JsProxy (has the bridge handle attr)."""
    return v is not None and hasattr(v, "_h")


def arr_len(arr):
    """Return length of either a Python list or a JsProxy array.

    JsProxy has no __len__; use `.length.to_int()`. Python lists go
    through built-in len().
    """
    if arr is None:
        return 0
    if _is_jsproxy(arr):
        # JsProxy(undefined/null) reports handle 0 — treat as empty.
        if arr._h == 0:
            return 0
        return arr.length.to_int()
    return len(arr)


def arr_get(arr, idx):
    """Return arr[idx] for either a Python list or a JsProxy array.

    JsProxy has no __getitem__; index via `getattr(arr, str(idx))`.
    """
    if _is_jsproxy(arr):
        return getattr(arr, str(idx))
    return arr[idx]


# ============================================================
# Overview Tab - Actionable summary
# ============================================================


def collect_repos_by_status(repositories, sources, sleeping_repos):
    """Collect repositories grouped by status."""
    failing_repos = []
    passing_repos = []

    if not repositories:
        return failing_repos, passing_repos

    source_ids = js.get("Object").keys(repositories)
    src_idx = 0
    while src_idx < source_ids.length.to_int():
        # JsProxy has no __getitem__; index via getattr with str(idx).
        source_id = getattr(source_ids, str(src_idx)).to_str()
        source_repos = getattr(repositories, source_id)
        result = find_source_config(sources, source_id)
        provider = result[0]
        identifier = result[1]

        if source_repos:
            repo_names = js.get("Object").keys(source_repos)
            rn_idx = 0
            while rn_idx < repo_names.length.to_int():
                repo_name = getattr(repo_names, str(rn_idx)).to_str()
                repo = getattr(source_repos, repo_name)
                status = coerce_str(get_prop(repo, "status", "unknown"))

                if not is_repo_sleeping(sleeping_repos, source_id, repo_name):
                    repo_info = {
                        "source_id": source_id,
                        "provider": provider,
                        "identifier": identifier,
                        "name": repo_name,
                        "repo": repo,
                        "status": status,
                    }

                    if status == "failed":
                        failing_repos.append(repo_info)
                    elif status == "ok":
                        passing_repos.append(repo_info)

                rn_idx = rn_idx + 1

        src_idx = src_idx + 1

    return failing_repos, passing_repos


def render_section_header(icon, text, css_class):
    """Create a section header element."""
    header = js.document.createElement("div")
    header.set("className", "section-header " + css_class)
    icon_span = js.document.createElement("span")
    icon_span.set("textContent", icon)
    header.appendChild(icon_span)
    text_node = js.document.createTextNode(text)
    header.appendChild(text_node)
    return header


def render_repo_section(repos_list, icon, label, css_class, container):
    """Render a section of repositories."""
    if len(repos_list) == 0:
        return

    section = js.document.createElement("div")
    section.set("className", "section")

    header_text = " " + label + " (" + str(len(repos_list)) + ")"
    header = render_section_header(icon, header_text, css_class)
    section.appendChild(header)

    content = js.document.createElement("div")
    content.set("className", "section-content")

    idx = 0
    while idx < len(repos_list):
        card = render_overview_repo_card(repos_list[idx])
        content.appendChild(card)
        idx = idx + 1

    section.appendChild(content)
    container.appendChild(section)


def render_overview(repositories, sources, sleeping_repos):
    """Render overview tab with failures and passing repos."""
    container = get_element("overview-container")
    container.set("innerHTML", "")

    if not repositories:
        container.set(
            "innerHTML",
            '<p class="empty">No build data yet. Add sources in Settings and click Refresh.</p>',
        )
        return

    result = collect_repos_by_status(repositories, sources, sleeping_repos)
    failing_repos = result[0]
    passing_repos = result[1]

    sort_by_timestamp_desc(failing_repos, get_latest_timestamp)
    sort_by_timestamp_desc(passing_repos, get_latest_timestamp)

    render_repo_section(
        failing_repos, "✗", "Needs Attention", "failures", container
    )
    render_repo_section(passing_repos, "✓", "All Clear", "passing", container)

    # Empty state
    if len(failing_repos) == 0 and len(passing_repos) == 0:
        container.set(
            "innerHTML", '<p class="empty">No repositories with build data yet.</p>'
        )


def get_latest_timestamp(repo_info):
    """Get timestamp of latest commit for sorting."""
    repo = repo_info["repo"]
    commits = get_prop(repo, "commits", [])
    if commits and arr_len(commits) > 0:
        latest = arr_get(commits, 0)
        ts = get_prop(latest, "timestamp", 0)
        # Real ts values exceed the smallint cap; project to a safe
        # sort-key via safe_ts().
        return safe_ts(ts)
    return 0


def get_last_success_timestamp(repo):
    """Find the timestamp of the last successful build.
    Returns 0 if no successful build found (meaning broken forever).

    The returned value may be a JsProxy (raw epoch ms) — don't call
    `.to_int()` here because real ts values overflow the smallint cap.
    Callers feed it to `format_relative_time`, which handles JsProxy.
    """
    commits = get_prop(repo, "commits", [])
    if not commits:
        return 0

    c_idx = 0
    n_commits = arr_len(commits)
    while c_idx < n_commits:
        commit = arr_get(commits, c_idx)
        builds = get_prop(commit, "builds", [])
        if builds:
            b_idx = 0
            n_builds = arr_len(builds)
            while b_idx < n_builds:
                build = arr_get(builds, b_idx)
                if coerce_str(get_prop(build, "status", "")) == "ok":
                    # Found a successful build
                    return get_prop(commit, "timestamp", 0)
                b_idx = b_idx + 1
        c_idx = c_idx + 1

    # No successful build found
    return 0


def create_name_span_with_link(full_name, repo_url):
    """Create a name span, optionally as a link."""
    name_span = js.document.createElement("span")
    name_span.style.set("marginLeft", "8px")
    if repo_url:
        link = js.document.createElement("a")
        link.set("href", repo_url)
        link.set("target", "_blank")
        link.set("textContent", full_name)
        name_span.appendChild(link)
    else:
        name_span.set("textContent", full_name)
    return name_span


def create_commit_meta_div(commit_hash, message):
    """Create the commit metadata div (hash + message)."""
    meta_div = js.document.createElement("div")
    meta_div.set("className", "repo-meta")

    commit_hash = coerce_str(commit_hash)
    message = coerce_str(message)

    if commit_hash:
        hash_span = js.document.createElement("span")
        hash_span.style.set("fontFamily", "monospace")
        hash_span.style.set("color", "#64b5f6")
        hash_span.set("textContent", commit_hash[:7])
        meta_div.appendChild(hash_span)

    if message:
        if len(message) > 50:
            message = message[:47] + "..."
        msg_span = js.document.createElement("span")
        msg_span.style.set("marginLeft", "8px")
        msg_span.style.set("color", "#aaa")
        msg_span.set("textContent", message)
        meta_div.appendChild(msg_span)

    return meta_div


def create_time_div(timestamp, status, repo):
    """Create the time div with optional broken duration."""
    time_div = js.document.createElement("div")
    time_div.set("className", "repo-meta")
    time_div.style.set("marginTop", "4px")

    if timestamp:
        date_span = js.document.createElement("span")
        date_span.style.set("color", "#888")
        date_span.set("textContent", format_relative_time(timestamp))
        time_div.appendChild(date_span)

    if status == "failed":
        last_success = get_last_success_timestamp(repo)
        broken_span = js.document.createElement("span")
        broken_span.style.set("marginLeft", "12px")
        broken_span.style.set("color", "#f44336")
        # `last_success` may be a JsProxy (epoch ms exceeds smallint cap);
        # use safe_ts to get a comparable Python int.
        if safe_ts(last_success) > 0:
            broken_span.set(
                "textContent",
                "Broken for " + format_relative_time(last_success).replace(" ago", ""),
            )
        else:
            broken_span.set("textContent", "Broken forever")
        time_div.appendChild(broken_span)

    return time_div


def create_build_icon(build):
    """Create a build status icon element."""
    icon = js.document.createElement("a")
    icon.set("className", "build-icon")

    b_status = coerce_str(get_prop(build, "status", "unknown"))
    b_url = coerce_str(get_prop(build, "url", ""))

    if b_url:
        icon.set("href", b_url)
        icon.set("target", "_blank")

    if b_status == "ok":
        icon.classList.add("ok")
        icon.set("textContent", "✓")
    elif b_status == "failed":
        icon.classList.add("failed")
        icon.set("textContent", "✗")
    elif b_status == "pending":
        icon.classList.add("pending")
        icon.set("textContent", "◐")
    else:
        icon.set("textContent", "?")

    return icon


def render_overview_repo_card(repo_info):
    """Render a detailed repo card for overview."""
    card = js.document.createElement("div")
    card.set("className", "repo-card")

    header = js.document.createElement("div")
    header.set("className", "repo-header")

    status = repo_info["status"]
    header.appendChild(create_status_dot(status))

    # Repo info container
    info_div = js.document.createElement("div")
    info_div.set("className", "repo-info")

    # First line: provider badge + full repo name
    name_line = js.document.createElement("div")
    name_line.set("className", "repo-name")
    name_line.appendChild(create_provider_badge(repo_info["provider"]))

    full_name = get_full_repo_name(
        repo_info["provider"], repo_info["identifier"], repo_info["name"]
    )
    repo_url = get_repo_url(
        repo_info["provider"], repo_info["identifier"], repo_info["name"]
    )
    name_line.appendChild(create_name_span_with_link(full_name, repo_url))
    info_div.appendChild(name_line)

    # Second line: commit info (hash, message, date)
    repo = repo_info["repo"]
    commits = get_prop(repo, "commits", [])
    n_commits = arr_len(commits)
    if n_commits > 0:
        latest = arr_get(commits, 0)
        commit_hash = get_prop(latest, "hash", "")
        message = get_prop(latest, "message", "")
        timestamp = get_prop(latest, "timestamp", 0)
        info_div.appendChild(create_commit_meta_div(commit_hash, message))
        info_div.appendChild(create_time_div(timestamp, status, repo))

    header.appendChild(info_div)

    # Build status icons for latest commit
    if n_commits > 0:
        latest = arr_get(commits, 0)
        builds = get_prop(latest, "builds", [])
        n_builds = arr_len(builds)
        if n_builds > 0:
            builds_div = js.document.createElement("div")
            builds_div.set("className", "repo-stats")

            b_idx = 0
            while b_idx < n_builds:
                builds_div.appendChild(create_build_icon(arr_get(builds, b_idx)))
                b_idx = b_idx + 1

            header.appendChild(builds_div)

    card.appendChild(header)
    return card


# ============================================================
# By Repository Tab - Flat list of all repos
# ============================================================


def collect_all_repos(repositories, sources):
    """Collect all repos from repositories structure into a flat list."""
    all_repos = []

    if not repositories:
        return all_repos

    source_ids = js.get("Object").keys(repositories)
    src_idx = 0
    n_src = source_ids.length.to_int()
    while src_idx < n_src:
        source_id = getattr(source_ids, str(src_idx)).to_str()
        source_repos = getattr(repositories, source_id)
        result = find_source_config(sources, source_id)
        provider = result[0]
        identifier = result[1]

        if source_repos:
            repo_names = js.get("Object").keys(source_repos)
            rn_idx = 0
            n_rn = repo_names.length.to_int()
            while rn_idx < n_rn:
                repo_name = getattr(repo_names, str(rn_idx)).to_str()
                repo = getattr(source_repos, repo_name)
                commits = get_prop(repo, "commits", [])
                timestamp = 0
                if arr_len(commits) > 0:
                    ts = get_prop(arr_get(commits, 0), "timestamp", 0)
                    # Real ts values overflow smallint; use safe_ts.
                    timestamp = safe_ts(ts)

                all_repos.append({
                    "provider": provider,
                    "identifier": identifier,
                    "name": repo_name,
                    "repo": repo,
                    "timestamp": timestamp,
                })
                rn_idx = rn_idx + 1

        src_idx = src_idx + 1

    return all_repos


def render_repos_tab(repositories, sources):
    """Render a flat list of all repositories."""
    container = get_element("repos-container")
    container.set("innerHTML", "")

    if not repositories:
        container.set("innerHTML", '<p class="empty">No repositories configured</p>')
        return

    all_repos = collect_all_repos(repositories, sources)

    def get_ts(repo_data):
        return repo_data["timestamp"]

    sort_by_timestamp_desc(all_repos, get_ts)

    # Render all repos
    idx = 0
    while idx < len(all_repos):
        repo_data = all_repos[idx]
        card = render_repo_detail_card(
            repo_data["provider"],
            repo_data["identifier"],
            repo_data["name"],
            repo_data["repo"],
        )
        container.appendChild(card)
        idx = idx + 1


def render_repo_detail_card(provider, identifier, repo_name, repo):
    """Render a clean summary card for a repository."""
    card = js.document.createElement("div")
    card.set("className", "repo-card")

    header = js.document.createElement("div")
    header.set("className", "repo-header")

    status = coerce_str(get_prop(repo, "status", "unknown"))
    header.appendChild(create_status_dot(status))

    info_div = js.document.createElement("div")
    info_div.set("className", "repo-info")

    # Line 1: Provider badge + Full repo name with link
    name_div = js.document.createElement("div")
    name_div.set("className", "repo-name")
    name_div.appendChild(create_provider_badge(provider))

    full_name = get_full_repo_name(provider, identifier, repo_name)
    repo_url = get_repo_url(provider, identifier, repo_name)
    name_div.appendChild(create_name_span_with_link(full_name, repo_url))
    info_div.appendChild(name_div)

    # Line 2: Latest commit info
    commits = get_prop(repo, "commits", [])
    n_commits = arr_len(commits)
    if n_commits > 0:
        latest = arr_get(commits, 0)
        commit_hash = get_prop(latest, "hash", "")
        message = get_prop(latest, "message", "")
        timestamp = get_prop(latest, "timestamp", 0)

        info_div.appendChild(create_commit_meta_div(commit_hash, message))

        if timestamp:
            time_div = js.document.createElement("div")
            time_div.set("className", "repo-meta")
            time_div.style.set("color", "#666")
            time_div.set("textContent", format_relative_time(timestamp))
            info_div.appendChild(time_div)

    header.appendChild(info_div)

    # Build status icons for latest commit
    if n_commits > 0:
        latest = arr_get(commits, 0)
        builds = get_prop(latest, "builds", [])
        n_builds = arr_len(builds)
        if n_builds > 0:
            builds_div = js.document.createElement("div")
            builds_div.set("className", "repo-stats")

            b_idx = 0
            while b_idx < n_builds:
                builds_div.appendChild(create_build_icon(arr_get(builds, b_idx)))
                b_idx = b_idx + 1

            header.appendChild(builds_div)

    card.appendChild(header)
    return card


# ============================================================
# Timeline Tab
# ============================================================


def collect_timeline_events(repositories, sources):
    """Collect all builds as timeline events."""
    events = []

    if not repositories:
        return events

    source_ids = js.get("Object").keys(repositories)
    src_idx = 0
    n_src = source_ids.length.to_int()
    while src_idx < n_src:
        source_id = getattr(source_ids, str(src_idx)).to_str()
        source_repos = getattr(repositories, source_id)
        result = find_source_config(sources, source_id)
        provider = result[0]
        identifier = result[1]

        if source_repos:
            repo_names = js.get("Object").keys(source_repos)
            rn_idx = 0
            n_rn = repo_names.length.to_int()
            while rn_idx < n_rn:
                repo_name = getattr(repo_names, str(rn_idx)).to_str()
                repo = getattr(source_repos, repo_name)
                commits = get_prop(repo, "commits", [])

                c_idx = 0
                n_commits = arr_len(commits)
                while c_idx < n_commits:
                    commit = arr_get(commits, c_idx)
                    builds = get_prop(commit, "builds", [])
                    commit_ts = get_prop(commit, "timestamp", 0)

                    b_idx = 0
                    n_builds = arr_len(builds)
                    while b_idx < n_builds:
                        build = arr_get(builds, b_idx)
                        build_ts = get_prop(build, "timestamp", 0)
                        # JsProxy(undefined) is truthy in Python; check
                        # the bridge handle instead so we fall back to
                        # the commit timestamp when build.timestamp is
                        # absent.
                        if _is_undefined(build_ts):
                            ts = commit_ts
                        else:
                            ts = build_ts

                        event = {
                            "provider": provider,
                            "identifier": identifier,
                            "repo": repo_name,
                            "commit_hash": coerce_str(get_prop(commit, "hash", "")),
                            "message": coerce_str(get_prop(commit, "message", "")),
                            "status": coerce_str(get_prop(build, "status", "unknown")),
                            "url": coerce_str(get_prop(build, "url", "")),
                            # Keep `timestamp` raw (JsProxy/int) for
                            # format_relative_time; project to a safe int
                            # for sorting via `sort_key`.
                            "timestamp": ts,
                            "sort_key": safe_ts(ts),
                        }
                        events.append(event)
                        b_idx = b_idx + 1

                    c_idx = c_idx + 1

                rn_idx = rn_idx + 1

        src_idx = src_idx + 1

    return events


def render_timeline(history, repositories, sources):
    """Render timeline of recent events."""
    container = get_element("timeline-container")
    container.set("innerHTML", "")

    events = collect_timeline_events(repositories, sources)

    if len(events) == 0:
        container.set("innerHTML", '<p class="empty">No build events yet.</p>')
        return

    def get_ts(e):
        return e["sort_key"]

    sort_by_timestamp_desc(events, get_ts)

    max_events = 50
    idx = 0
    while idx < len(events) and idx < max_events:
        container.appendChild(render_timeline_event(events[idx]))
        idx = idx + 1


def create_timeline_status_dot(status):
    """Create a timeline status dot element."""
    status_dot = js.document.createElement("span")
    status_dot.set("className", "timeline-status")
    if status == "ok":
        status_dot.classList.add("status-ok")
    elif status == "failed":
        status_dot.classList.add("status-failed")
    else:
        status_dot.classList.add("status-unknown")
    return status_dot


def create_commit_hash_span(commit_hash):
    """Create a commit hash span element."""
    if not commit_hash:
        return None
    hash_span = js.document.createElement("span")
    hash_span.style.set("fontFamily", "monospace")
    hash_span.style.set("marginLeft", "8px")
    hash_span.style.set("color", "#64b5f6")
    hash_span.set("textContent", commit_hash[:7])
    return hash_span


def render_timeline_event(event):
    """Render a single timeline event with full details."""
    div = js.document.createElement("div")
    div.set("className", "timeline-event")

    div.appendChild(create_timeline_status_dot(event["status"]))

    info_div = js.document.createElement("div")
    info_div.set("className", "timeline-info")

    # Line 1: Provider badge + Full repo name + commit hash + time
    title_div = js.document.createElement("div")
    title_div.set("className", "timeline-title")

    provider = event["provider"]
    title_div.appendChild(create_provider_badge(provider))

    identifier = event["identifier"]
    repo_name = event["repo"]
    full_name = get_full_repo_name(provider, identifier, repo_name)
    title_div.appendChild(create_name_span_with_link(full_name, event["url"]))

    hash_span = create_commit_hash_span(event["commit_hash"])
    if hash_span:
        title_div.appendChild(hash_span)

    # Timestamp inline
    timestamp = event["timestamp"]
    if timestamp:
        time_span = js.document.createElement("span")
        time_span.set("className", "timeline-time")
        time_span.set("textContent", format_relative_time(timestamp))
        title_div.appendChild(time_span)

    info_div.appendChild(title_div)

    # Line 2: Commit message
    message = event["message"]
    if message:
        detail_div = js.document.createElement("div")
        detail_div.set("className", "timeline-detail")
        if len(message) > 80:
            message = message[:77] + "..."
        detail_div.set("textContent", message)
        info_div.appendChild(detail_div)

    div.appendChild(info_div)

    return div


# ============================================================
# Admin Tab - Repository Management
# ============================================================

# Global to store sleeping repos list for checking
g_sleeping_repos = []


def _is_repo_sleeping_admin(source_id, repo_name):
    """Check if a repository is in the sleeping list (uses global)."""
    return is_repo_sleeping(g_sleeping_repos, source_id, repo_name)


def collect_admin_repos(repositories, sources):
    """Collect repos categorized for admin tab."""
    sleeping_list = []
    failing_list = []
    passing_list = []

    if not repositories:
        return sleeping_list, failing_list, passing_list

    source_ids = js.get("Object").keys(repositories)
    src_idx = 0
    n_src = source_ids.length.to_int()
    while src_idx < n_src:
        source_id = getattr(source_ids, str(src_idx)).to_str()
        source_repos = getattr(repositories, source_id)
        result = find_source_config(sources, source_id)
        provider = result[0]
        identifier = result[1]

        if source_repos:
            repo_names = js.get("Object").keys(source_repos)
            rn_idx = 0
            n_rn = repo_names.length.to_int()
            while rn_idx < n_rn:
                repo_name = getattr(repo_names, str(rn_idx)).to_str()
                repo = getattr(source_repos, repo_name)
                status = coerce_str(get_prop(repo, "status", "unknown"))

                repo_info = {
                    "source_id": source_id,
                    "provider": provider,
                    "identifier": identifier,
                    "repo_name": repo_name,
                    "repo": repo,
                    "status": status,
                }

                if _is_repo_sleeping_admin(source_id, repo_name):
                    sleeping_list.append(repo_info)
                elif status == "failed":
                    failing_list.append(repo_info)
                elif status == "ok":
                    passing_list.append(repo_info)

                rn_idx = rn_idx + 1

        src_idx = src_idx + 1

    return sleeping_list, failing_list, passing_list


def render_admin_tab(sources, repositories, sleeping_repos):
    """Render admin tab with repository management."""
    global g_sleeping_repos
    g_sleeping_repos = sleeping_repos if sleeping_repos else []

    result = collect_admin_repos(repositories, sources)
    sleeping_list = result[0]
    failing_list = result[1]
    passing_list = result[2]

    render_admin_repo_list("sleeping-repos-list", sleeping_list, "sleeping")
    render_admin_repo_list("failing-repos-list", failing_list, "failing")
    render_admin_repo_list("passing-repos-list", passing_list, "passing")


def render_admin_repo_list(container_id, repos, list_type):
    """Render a list of repository cards."""
    container = get_element(container_id)
    container.set("innerHTML", "")

    if len(repos) == 0:
        empty_msg = js.document.createElement("p")
        empty_msg.set("className", "empty")
        if list_type == "sleeping":
            empty_msg.set("textContent", "No sleeping repositories")
        elif list_type == "failing":
            empty_msg.set("textContent", "No failing repositories")
        else:
            empty_msg.set("textContent", "No passing repositories")
        container.appendChild(empty_msg)
        return

    idx = 0
    while idx < len(repos):
        repo_info = repos[idx]
        card = render_admin_repo_card(repo_info, list_type)
        container.appendChild(card)
        idx = idx + 1


def get_admin_status_info(list_type, status):
    """Get status text and color for admin cards."""
    if list_type == "sleeping":
        return "Sleeping", "#888"
    if status == "failed":
        return "Failed", "#f44336"
    if status == "ok":
        return "Passing", "#4caf50"
    return "Unknown", "#888"


def create_admin_meta_div(repo_info, list_type):
    """Create the meta div for admin repo card."""
    meta_div = js.document.createElement("div")
    meta_div.set("className", "source-meta")

    status = repo_info["status"]
    status_text, color = get_admin_status_info(list_type, status)
    meta_div.style.set("color", color)

    repo = repo_info["repo"]
    commits = get_prop(repo, "commits", [])
    if arr_len(commits) > 0:
        latest = arr_get(commits, 0)
        timestamp = get_prop(latest, "timestamp", 0)
        if timestamp:
            meta_div.set(
                "textContent",
                status_text + " • " + format_relative_time(timestamp),
            )
            return meta_div

    meta_div.set("textContent", status_text)
    return meta_div


def render_admin_repo_card(repo_info, list_type):
    """Render an individual repository card with sleep/wake button."""
    card = js.document.createElement("div")
    card.set("className", "source-card")

    info_div = js.document.createElement("div")
    info_div.set("className", "source-info")

    # Name line with badge
    name_div = js.document.createElement("div")
    name_div.set("className", "source-name")

    provider = repo_info["provider"]
    name_div.appendChild(create_provider_badge(provider))

    full_name = get_full_repo_name(
        provider, repo_info["identifier"], repo_info["repo_name"]
    )
    name_span = js.document.createElement("span")
    name_span.set("textContent", full_name)
    name_div.appendChild(name_span)

    info_div.appendChild(name_div)
    info_div.appendChild(create_admin_meta_div(repo_info, list_type))
    card.appendChild(info_div)

    # Sleep/Wake button
    source_id = repo_info["source_id"]
    repo_name = repo_info["repo_name"]
    btn = js.document.createElement("button")

    if list_type == "sleeping":
        btn.set("className", "btn btn-sm btn-primary")
        btn.set("textContent", "Wake")

        def make_wake_handler(sid, rname):
            def handler(event):
                wake_repo(sid, rname)

            return handler

        btn.addEventListener("click", make_wake_handler(source_id, repo_name))
    else:
        btn.set("className", "btn btn-sm btn-secondary")
        btn.set("textContent", "Sleep")

        def make_sleep_handler(sid, rname):
            def handler(event):
                sleep_repo(sid, rname)

            return handler

        btn.addEventListener("click", make_sleep_handler(source_id, repo_name))

    card.appendChild(btn)

    return card


def sleep_repo(source_id, repo_name):
    """Add a repository to the sleeping list."""
    js.console.log("Sleeping repo: " + source_id + "/" + repo_name)

    def handle_data(data):
        # Convert JS array from storage to Python list
        sleeping_repos = []
        stored = data.sleepingRepos
        if not _is_undefined(stored):
            idx = 0
            n = stored.length.to_int()
            while idx < n:
                # JsProxy has no __getitem__; index via getattr(arr, str(idx)).
                sleeping_repos.append(getattr(stored, str(idx)))
                idx = idx + 1

        # Check if already sleeping
        already = False
        idx = 0
        while idx < len(sleeping_repos):
            item = sleeping_repos[idx]
            # `item` came back from storage as a JsProxy; use attribute reads.
            stored_sid = coerce_str(get_prop(item, "sourceId", ""))
            stored_rname = coerce_str(get_prop(item, "repoName", ""))
            if stored_sid == source_id and stored_rname == repo_name:
                already = True
                break
            idx = idx + 1

        if not already:
            new_item = create_obj()
            new_item.set("sourceId", source_id)
            new_item.set("repoName", repo_name)
            sleeping_repos.append(new_item)

        # Save back as a JS array so the bridge marshal preserves order.
        out = js.get("Array")()
        idx = 0
        while idx < len(sleeping_repos):
            out.push(sleeping_repos[idx])
            idx = idx + 1

        save_data = create_obj()
        save_data.set("sleepingRepos", out)

        def on_saved(result):
            load_data()

        _storage_set(save_data).then(on_saved)

    get_all_storage().then(handle_data)


def wake_repo(source_id, repo_name):
    """Remove a repository from the sleeping list."""
    js.console.log("Waking repo: " + source_id + "/" + repo_name)

    def handle_data(data):
        # Convert JS array from storage to Python list
        sleeping_repos = []
        stored = data.sleepingRepos
        if not _is_undefined(stored):
            idx = 0
            n = stored.length.to_int()
            while idx < n:
                sleeping_repos.append(getattr(stored, str(idx)))
                idx = idx + 1

        # Remove from list
        new_list = js.get("Array")()
        idx = 0
        while idx < len(sleeping_repos):
            item = sleeping_repos[idx]
            stored_sid = coerce_str(get_prop(item, "sourceId", ""))
            stored_rname = coerce_str(get_prop(item, "repoName", ""))
            if not (stored_sid == source_id and stored_rname == repo_name):
                new_list.push(item)
            idx = idx + 1

        save_data = create_obj()
        save_data.set("sleepingRepos", new_list)

        def on_saved(result):
            load_data()

        _storage_set(save_data).then(on_saved)

    get_all_storage().then(handle_data)


# ============================================================
# Raw Data Tab
# ============================================================


def render_storage(data):
    """Render raw storage data for debugging."""
    output = get_element("storage-output")
    output.set("textContent", _stringify_pretty(data).to_str())


# ============================================================
# Tab Management
# ============================================================


def switch_tab(tab_name):
    """Switch to a different tab."""
    tabs = js.document.querySelectorAll(".tab")
    i = 0
    while i < tabs.length.to_int():
        tab = tabs.item(i)
        if tab.dataset.tab.to_str() == tab_name:
            tab.classList.add("active")
        else:
            tab.classList.remove("active")
        i = i + 1

    contents = js.document.querySelectorAll(".tab-content")
    j = 0
    while j < contents.length.to_int():
        content = contents.item(j)
        if content.id.to_str() == "tab-" + tab_name:
            content.classList.add("active")
        else:
            content.classList.remove("active")
        j = j + 1


def setup_tabs():
    """Set up tab click handlers."""
    tabs = js.document.querySelectorAll(".tab")

    def make_tab_handler(tab_name):
        def handler(event):
            switch_tab(tab_name)

        return handler

    i = 0
    while i < tabs.length.to_int():
        tab = tabs.item(i)
        tab_name = tab.dataset.tab.to_str()
        handler = make_tab_handler(tab_name)
        tab.addEventListener("click", handler)
        i = i + 1


# ============================================================
# Main Functions
# ============================================================


def _is_undefined(proxy):
    """True if a JsProxy wraps null/undefined.

    Python truthiness on JsProxy defaults to True (no __bool__), so a
    `not proxy` check misses the empty case. The bridge tags
    null/undefined with handle 0; check that directly.
    """
    if proxy is None:
        return True
    return proxy._h == 0


def load_data():
    """Load and display all data."""

    def handle_data(data):
        sources = data.repos
        if _is_undefined(sources):
            sources = []

        repositories = data.repositories
        if _is_undefined(repositories):
            repositories = None  # collect_* helpers treat falsy as empty

        history = data.buildHistory
        if _is_undefined(history):
            history = []

        # Convert JS array from storage to Python list
        sleeping_repos = []
        stored_sleeping = data.sleepingRepos
        if not _is_undefined(stored_sleeping):
            idx = 0
            n = stored_sleeping.length.to_int()
            while idx < n:
                # JsProxy has no __getitem__; getattr with str(idx).
                sleeping_repos.append(getattr(stored_sleeping, str(idx)))
                idx = idx + 1

        # Render all tabs
        render_overview(repositories, sources, sleeping_repos)
        render_repos_tab(repositories, sources)
        render_timeline(history, repositories, sources)
        render_admin_tab(sources, repositories, sleeping_repos)
        render_storage(data)

    get_all_storage().then(handle_data)


def _source_to_dict(source):
    """JsProxy source → Python dict. Providers expect dict-style access."""
    return {
        "id": js_str_attr(source, "id"),
        "provider": js_str_attr(source, "provider"),
        "identifier": js_str_attr(source, "identifier"),
        "token": js_str_attr(source, "token"),
    }


def _fetch_one_source(source):
    """Fetch builds for one source + persist. Returns a Promise."""
    config = _source_to_dict(source)
    provider_name = config["provider"]
    provider_cls = PROVIDERS.get(provider_name)
    if provider_cls is None:
        return js.get("Promise").resolve(None)

    provider = provider_cls()
    source_id = config["id"]

    def on_fetched(result):
        # JsProxy.__getattr__ never raises — a missing key comes back as a
        # null handle, so that (not an exception) is what to check for.
        repos_bucket = getattr(result, "repos")
        if repos_bucket._h == 0:
            return None
        return _persist_repos(source_id, repos_bucket)

    def on_err(err):
        js.console.error("[refresh] source", source_id, "error:", err)
        return None

    return provider.get_failed_builds(config).then(on_fetched).catch(on_err)


def refresh_now():
    """Trigger immediate check.

    In standalone-web mode (served by serve.py) chrome.runtime.sendMessage
    is a no-op — there's no background service worker listening. So run
    the fetch + persist loop here directly, then reload the dashboard.
    The sendMessage call is kept for the real-extension case.
    """
    js.console.log("Triggering manual refresh...")

    # Visible feedback so the user sees the click did something.
    refresh_btn = get_element("refresh-btn")
    if refresh_btn:
        refresh_btn.set("textContent", "Refreshing…")
        refresh_btn.set("disabled", True)

    message = create_obj()
    message.set("action", "checkNow")
    chrome.runtime.sendMessage(message)

    def restore_btn():
        if refresh_btn:
            refresh_btn.set("textContent", "Refresh Now")
            refresh_btn.set("disabled", False)

    def on_repos(result):
        sources = None
        if result is not None and not (hasattr(result, "_h") and result._h == 0):
            sources = getattr(result, "repos")

        if sources is None or (hasattr(sources, "_h") and sources._h == 0):
            restore_btn()
            load_data()
            return

        # .to_int() on a null handle returns 0 (probed), so the existing
        # zero-length branch below is the whole guard.
        sources_len = sources.length.to_int()

        if sources_len == 0:
            restore_btn()
            load_data()
            return

        arr = js.get("Array")()
        i = 0
        while i < sources_len:
            source = getattr(sources, str(i))
            enabled = get_prop(source, "enabled", True)
            if enabled:
                arr.push(_fetch_one_source(source))
            i = i + 1

        def after_all(r):
            restore_btn()
            load_data()

        def after_err(e):
            js.console.error("[refresh] aggregate error:", e)
            restore_btn()
            load_data()

        js.get("Promise").all(arr).then(after_all).catch(after_err)

    chrome.storage.local.get("repos").then(on_repos)


def init():
    """Initialize the dashboard."""
    refresh_btn = get_element("refresh-btn")

    def on_refresh(event):
        refresh_now()

    refresh_btn.addEventListener("click", on_refresh)

    setup_tabs()
    load_data()


# Wait for DOM then initialize.
#
# The wasm/Python pipeline is async (wasm fetch + compile, then sources
# fetched, then interpreted), so by the time we get here DOMContentLoaded
# has almost certainly already fired. Check readyState and call init()
# directly if the DOM is already past "loading"; otherwise register the
# listener for the future-firing case. (Same pattern as pages_popup.py
# and pages_options.py.)
if js.document.readyState.to_str() == "loading":
    js.document.addEventListener("DOMContentLoaded", init)
else:
    init()
