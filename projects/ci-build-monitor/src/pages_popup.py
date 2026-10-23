# CI Build Monitor - Popup UI Logic
# Simple, glanceable status view

import js
from providers_base import create_obj
from providers_github import GitHubProvider
from providers_gitlab import GitLabProvider
from providers_sourcehut import SourcehutProvider
from ui_dom import get_element, get_prop, js_str_attr
from ui_repo_helpers import is_repo_sleeping

# Provider registry — mirrors pages_background.PROVIDERS so the popup
# can fetch directly in standalone-web mode where there is no
# background service worker to receive chrome.runtime.sendMessage.
PROVIDERS = {
    "sourcehut": SourcehutProvider,
    "github": GitHubProvider,
    "gitlab": GitLabProvider,
}

# JS-side helper to merge a per-source bucket into chrome.storage's
# "repositories" object. The provider's parse_rss result crosses the
# JS Promise boundary back into our callback as a JsProxy of a JS
# object (the Python dict has been auto-marshalled), so we can stash
# it directly without converting key-by-key on the Python side.
# services_storage.save_repositories does the same write but iterates
# the bucket as a Python dict (`for k in d`), which trips on the
# JsProxy.
_persist_repos = js.get("eval")(
    "(function(sourceId, bucket){"
    "  return chrome.storage.local.get('repositories').then(function(r){"
    "    var all = (r && r.repositories) ? r.repositories : {};"
    "    all[sourceId] = bucket;"
    "    return chrome.storage.local.set({repositories: all});"
    "  });"
    "})"
)


def persist_source_repos_from_jsproxy(source_id, repos_bucket):
    """Persist a JsProxy repo bucket to chrome.storage.local under
    repositories[source_id]."""
    return _persist_repos(source_id, repos_bucket)

# chrome is not pre-instantiated in petitpy-lib/js.py; fetch the global
# once at module load and reuse. See projects/ci-build-monitor/notes/PORTING.md.
chrome = js.get("chrome")


def get_repositories():
    """Get all repositories from storage. Returns a Promise."""

    def handle_result(result):
        repos = result.repositories
        # JsProxy(undefined) is truthy from Python's perspective (no
        # __bool__) so `if not repos` misses the empty case — check the
        # underlying handle. Same pattern as get_repos() / get_settings().
        if repos is None or repos._h == 0:
            return create_obj()
        return repos

    return chrome.storage.local.get("repositories").then(handle_result)


def get_monitored_sources():
    """Get monitored sources from storage. Returns a Promise."""

    def handle_result(result):
        # Return the JsProxy directly (real JS array, or proxy-of-undefined
        # when the key is missing). Don't convert to a Python list: the js
        # bridge's `_marshal` doesn't support lists, and the dispatch would
        # raise TypeError into a silent swallow — the Promise.all chain
        # would hang and the popup would never get past the spinner.
        return result.repos

    return chrome.storage.local.get("repos").then(handle_result)


def get_sleeping_repos():
    """Get sleeping repos from storage. Returns a Promise."""

    def handle_result(result):
        # See `get_monitored_sources` for why we keep the JsProxy as-is.
        return result.sleepingRepos

    return chrome.storage.local.get("sleepingRepos").then(handle_result)


def open_options():
    """Open the options page."""
    chrome.runtime.openOptionsPage()


def open_dashboard():
    """Open the status dashboard."""
    tab_opts = create_obj()
    tab_opts.set("url", "status.html")
    chrome.tabs.create(tab_opts)


def _js_int_attr(obj, key, default=0):
    """Read attr from JsProxy and materialize to a Python int."""
    val = getattr(obj, key)
    if val is None:
        return default
    if val._h == 0:
        return default
    return val.to_int()


def source_to_dict(source):
    """Convert a JsProxy source object to a Python dict.

    The provider classes (providers_sourcehut etc.) treat their `config`
    arg as a Python dict (config.get("identifier"), config["id"]). The
    sources we load from chrome.storage.local are JsProxy, which has no
    Python-side .get() — calling it trips "js_call: handle 0 is not a
    function". Materialize to a plain dict before dispatch.
    """
    return {
        "id": js_str_attr(source, "id"),
        "provider": js_str_attr(source, "provider"),
        "identifier": js_str_attr(source, "identifier"),
        "token": js_str_attr(source, "token"),
        "lastChecked": _js_int_attr(source, "lastChecked", 0),
    }


def fetch_one_source(source):
    """Fetch builds for a single source and persist them. Returns a Promise.

    Mirrors pages_background.check_source: dispatch to the provider,
    pull the {repos, newFailures, failedCount} payload, write the repos
    bucket to chrome.storage.local under the "repositories" key. Errors
    are swallowed (logged) so one bad source doesn't tank the others.
    """
    config = source_to_dict(source)
    provider_name = config["provider"]
    if not provider_name:
        return js.get("Promise").resolve(None)

    ProviderClass = PROVIDERS.get(provider_name, None)
    if not ProviderClass:
        js.console.error("[refresh_now] Unknown provider:", provider_name)
        return js.get("Promise").resolve(None)

    source_id = config["id"]
    provider = ProviderClass()

    def handle_result(result):
        if not result:
            return None
        # Provider's parse_rss returns a Python dict; once it crosses the
        # JS Promise.then() boundary into our callback it has been
        # marshalled to a JsProxy of a JS object. Read via attribute,
        # not subscript (`result["repos"]` trips on JsProxy). On
        # provider error (network / parse) the .catch in get_failed_builds
        # returns an empty JsProxy with no `repos` attribute — `_h == 0`
        # below detects that path.
        repos_proxy = getattr(result, "repos", None)
        if repos_proxy is None or repos_proxy._h == 0:
            return None
        return persist_source_repos_from_jsproxy(source_id, repos_proxy)

    def handle_error(error):
        js.console.error("[refresh_now] Provider error:", provider_name, error)
        return None

    return provider.get_failed_builds(config).then(handle_result).catch(handle_error)


def refresh_now():
    """Trigger immediate check.

    In a real extension, chrome.runtime.sendMessage reaches the background
    service worker which runs check_all_sources. In standalone-web mode
    (served by serve.py) sendMessage is a no-op shim, so we ALSO run the
    fetch + persist loop here. The message dispatch is kept for the real-
    extension case where both contexts may benefit.
    """
    js.console.log("Triggering manual refresh...")

    # Immediate visible feedback: flip the status summary to a
    # "Refreshing..." state so the user sees that the click did
    # something. Without this, the message dispatch + delayed render
    # are both invisible and the user reports "nothing happens".
    summary = get_element("status-summary")
    if summary:
        status_icon = summary.querySelector(".status-icon")
        status_text = summary.querySelector(".status-text")
        summary.set("className", "status-summary refreshing")
        if status_icon:
            status_icon.set("textContent", "↻")
        if status_text:
            status_text.set("textContent", "Refreshing...")

    message = create_obj()
    message.set("action", "checkNow")
    chrome.runtime.sendMessage(message)

    def run_fetches(sources):
        # `sources` is the JsProxy returned by get_monitored_sources.
        # Empty / undefined case: just re-render.
        if sources is None or sources._h == 0:
            render()
            return
        sources_len = sources.length.to_int()
        if sources_len == 0:
            render()
            return

        # Build a real JS Array of fetch Promises so Promise.all can
        # consume it (the js bridge's _marshal does not handle Python
        # lists — same constraint as in load_all()).
        arr = js.get("Array")()
        i = 0
        while i < sources_len:
            source = getattr(sources, str(i))
            enabled = get_prop(source, "enabled", True)
            if enabled:
                arr.push(fetch_one_source(source))
            i = i + 1

        def after_all(result):
            render()

        def after_err(error):
            js.console.error("[refresh_now] Aggregate error:", error)
            render()

        js.get("Promise").all(arr).then(after_all).catch(after_err)

    get_monitored_sources().then(run_fetches)


def make_repo_click_handler(url):
    """Create a click handler to open repo URL."""

    def handler(event):
        if url:
            tab_opts = create_obj()
            tab_opts.set("url", url)
            chrome.tabs.create(tab_opts)

    return handler


def collect_repos_by_status(repositories, sleeping_repos):
    """Collect repositories grouped by status, excluding sleeping repos."""
    failing_repos = []
    passing_count = 0

    if not repositories:
        return failing_repos, passing_count

    source_ids = js.get("Object").keys(repositories)
    src_idx = 0
    source_ids_len = source_ids.length.to_int()
    while src_idx < source_ids_len:
        source_id = getattr(source_ids, str(src_idx)).to_str()
        # Dynamic-key read on a JsProxy — route through getattr.
        source_repos = getattr(repositories, source_id)
        if source_repos:
            repo_names = js.get("Object").keys(source_repos)
            rn_idx = 0
            repo_names_len = repo_names.length.to_int()
            while rn_idx < repo_names_len:
                repo_name = getattr(repo_names, str(rn_idx)).to_str()
                repo = getattr(source_repos, repo_name)

                # Skip sleeping repos
                if not is_repo_sleeping(sleeping_repos, source_id, repo_name):
                    status = get_prop(repo, "status", "unknown")
                    if status == "failed":
                        failing_repos.append(repo)
                    elif status == "ok":
                        passing_count = passing_count + 1
                rn_idx = rn_idx + 1
        src_idx = src_idx + 1

    return failing_repos, passing_count


def render_status_summary(failed_count):
    """Render the status summary section."""
    summary = get_element("status-summary")
    status_icon = summary.querySelector(".status-icon")
    status_text = summary.querySelector(".status-text")

    if failed_count > 0:
        summary.set("className", "status-summary has-failures")
        status_icon.set("textContent", "✗")
        if failed_count == 1:
            status_text.set("textContent", "1 repo needs attention")
        else:
            status_text.set("textContent", str(failed_count) + " repos need attention")
    else:
        summary.set("className", "status-summary all-ok")
        status_icon.set("textContent", "✓")
        status_text.set("textContent", "All repos passing")


def create_failure_item(repo):
    """Create a failure item element for a repo."""
    item = js.document.createElement("div")
    item.set("className", "failure-item")

    # Get latest commit info
    commits = get_prop(repo, "commits", [])
    latest_commit_msg = ""
    repo_url = get_prop(repo, "url", "")

    if commits and commits.length.to_int() > 0:
        latest = getattr(commits, "0")
        latest_commit_msg = get_prop(latest, "message", "")
        builds = get_prop(latest, "builds", [])
        if builds and builds.length.to_int() > 0:
            repo_url = get_prop(getattr(builds, "0"), "url", repo_url)

    # Icon
    icon = js.document.createElement("span")
    icon.set("className", "failure-icon")
    icon.set("textContent", "✗")
    item.appendChild(icon)

    # Info
    info = js.document.createElement("div")
    info.set("className", "failure-info")

    name_div = js.document.createElement("div")
    name_div.set("className", "failure-name")
    name_div.set("textContent", get_prop(repo, "name", "Unknown"))
    info.appendChild(name_div)

    if latest_commit_msg:
        detail_div = js.document.createElement("div")
        detail_div.set("className", "failure-detail")
        msg = latest_commit_msg
        if len(msg) > 40:
            msg = msg[:37] + "..."
        detail_div.set("textContent", msg)
        info.appendChild(detail_div)

    item.appendChild(info)

    if repo_url:
        item.addEventListener("click", make_repo_click_handler(repo_url))

    return item


def render_failures_section(failing_repos):
    """Render the failures section."""
    failures_section = get_element("failures-section")
    failures_list = get_element("failures-list")
    failed_count = len(failing_repos)

    if failed_count == 0:
        failures_section.style.set("display", "none")
        return

    failures_section.style.set("display", "block")
    failures_list.set("innerHTML", "")

    # Show up to 5 failing repos
    shown = 0
    idx = 0
    while idx < failed_count and shown < 5:
        item = create_failure_item(failing_repos[idx])
        failures_list.appendChild(item)
        shown = shown + 1
        idx = idx + 1

    # Show "and X more" if needed
    if failed_count > 5:
        more = js.document.createElement("div")
        more.style.set("padding", "8px")
        more.style.set("textAlign", "center")
        more.style.set("color", "#888")
        more.style.set("fontSize", "11px")
        more.set("textContent", "and " + str(failed_count - 5) + " more...")
        failures_list.appendChild(more)


def render_passing_section(passing_count):
    """Render the passing repos section."""
    passing_section = get_element("passing-section")
    if passing_count > 0:
        passing_section.style.set("display", "flex")
        passing_text = get_element("passing-text")
        if passing_count == 1:
            passing_text.set("textContent", "1 repo passing")
        else:
            passing_text.set("textContent", str(passing_count) + " repos passing")
    else:
        passing_section.style.set("display", "none")


def render():
    """Render the popup based on current state."""
    loading = get_element("loading")
    empty_state = get_element("empty-state")
    main_content = get_element("main-content")

    def handle_data(data):
        # data is a JsProxy array from Promise.all
        sources = getattr(data, "0")
        repositories = getattr(data, "1")
        sleeping_repos = getattr(data, "2")

        loading.style.set("display", "none")

        # `sources` is a JsProxy. We can't use Python truthiness or len()
        # here — JsProxy has no __bool__ / __len__. Detect the empty case
        # via the JS handle (0 == null/undefined) or via JS-side length.
        sources_empty = (sources._h == 0)
        if not sources_empty:
            # A non-array / missing handle reports length 0 (probed), so
            # this covers the not-array-shaped case too.
            if sources.length.to_int() == 0:
                sources_empty = True

        if sources_empty:
            empty_state.style.set("display", "block")
            main_content.style.set("display", "none")
            return

        empty_state.style.set("display", "none")
        main_content.style.set("display", "block")

        result = collect_repos_by_status(repositories, sleeping_repos)
        failing_repos = result[0]
        passing_count = result[1]

        render_status_summary(len(failing_repos))
        render_failures_section(failing_repos)
        render_passing_section(passing_count)

    def load_all():
        sources_promise = get_monitored_sources()
        repos_promise = get_repositories()
        sleeping_promise = get_sleeping_repos()
        # The js bridge's _marshal does not handle Python lists; hand
        # Promise.all a real JS Array. (Same pattern used throughout
        # pages_options.py / pages_status.py.)
        arr = js.get("Array")()
        arr.push(sources_promise)
        arr.push(repos_promise)
        arr.push(sleeping_promise)
        return js.get("Promise").all(arr)

    load_all().then(handle_data)


def init():
    """Initialize the popup."""
    # Set up button handlers
    refresh_btn = get_element("refresh-btn")
    dashboard_btn = get_element("dashboard-btn")
    settings_btn = get_element("settings-btn")
    add_repo_btn = get_element("add-repo-btn")

    def on_refresh(event):
        refresh_now()

    def on_dashboard(event):
        open_dashboard()

    def on_settings(event):
        open_options()

    def on_add_repo(event):
        open_options()

    refresh_btn.addEventListener("click", on_refresh)
    dashboard_btn.addEventListener("click", on_dashboard)
    settings_btn.addEventListener("click", on_settings)
    add_repo_btn.addEventListener("click", on_add_repo)

    # Initial render
    render()


# Wait for DOM then initialize.
#
# The wasm/Python pipeline is async (wasm fetch + compile, then sources
# fetched, then interpreted), so by the time we get here DOMContentLoaded
# has almost certainly already fired. Check readyState and call init()
# directly if the DOM is already past "loading"; otherwise register the
# listener for the future-firing case.
if js.document.readyState.to_str() == "loading":
    js.document.addEventListener("DOMContentLoaded", init)
else:
    init()
