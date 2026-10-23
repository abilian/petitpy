# CI Build Monitor - Options Page Logic
# Handles full settings and repo management

import js

from core_utils import create_obj, generate_id, proxy_url
from services_storage import get_all_storage
from ui_dom import get_element

# `js.JSON.parse` on a malformed document traps at the host level rather than
# raising into Python, which kills the wasm instance. Catch it on the JS side
# and hand back null; the bridge turns that into a 0 handle.
_json_parse_or_null = js.get("eval")(
    "(function(s){try{return JSON.parse(s);}catch(e){return null;}})"
)

# chrome is not pre-instantiated in petitpy-lib/js.py; fetch the global
# once at module load and reuse. See projects/ci-build-monitor/notes/PORTING.md.
chrome = js.get("chrome")

# `JsProxy.set(name, value)` is a Python method that shadows JS-side `.set`
# attribute lookup, so `chrome.storage.local.set(data)` calls the explicit
# Python setter (which takes two args) and trips "argument num/types
# mismatch". Route storage writes through a JS-side wrapper that calls the
# real chrome.storage.local.set. Same pattern for `get(null)` since Python
# `None` can't cross the bridge's _marshal.
_storage_set = js.get("eval")("(function(d){return chrome.storage.local.set(d);})")
# `js.get("Date")()` doesn't construct (bridge can't `new`), so the
# Date-instance method chain (`.toISOString()`) trips. Route through a
# JS-side wrapper that constructs the Date.
_iso_now = js.get("eval")("(function(){return new Date().toISOString();})")
_stringify_pretty = js.get("eval")("(function(o){return JSON.stringify(o,null,2);})")


# Provider configurations (plain Python dict; never crosses the bridge).
PROVIDER_CONFIG = {
    "sourcehut": {
        "label": "Username",
        "placeholder": "username",
        "help": "Your Sourcehut username (without ~). Monitors ALL builds for this user.",
        "needsToken": False,
        "tokenHelp": "",
    },
    "github": {
        "label": "Repository",
        "placeholder": "owner/repo",
        "help": "Repository in format owner/repo (e.g., torvalds/linux). Add multiple entries for multiple repos.",
        "needsToken": False,
        "tokenHelp": "Required for private repos",
    },
    "gitlab": {
        "label": "Project Path",
        "placeholder": "owner/project",
        "help": "Project path (e.g., gitlab-org/gitlab). Add multiple entries for multiple projects.",
        "needsToken": True,
        "tokenHelp": "Required - create at Settings > Access Tokens",
    },
}


def get_repos():
    """Get monitored repos from storage. Returns a Promise.

    Always resolves to a real JS array (JsProxy), never a Python list:
    callers do `.push()` on the result so the value lands on the JS side
    for chrome.storage.local.set. JsProxy(undefined) is truthy from
    Python's perspective (it has no `__bool__`), so `if not repos`
    misses the empty case — check the underlying handle instead.
    See pages_popup.py for the same pattern.
    """

    def handle_result(result):
        repos = result.repos
        # `repos._h == 0` flags a JsProxy wrapping null/undefined.
        if repos is None or repos._h == 0:
            return js.get("Array")()
        return repos

    return chrome.storage.local.get("repos").then(handle_result)


def save_repos(repos):
    """Save repos to storage. Returns a Promise."""
    data = create_obj()
    data.set("repos", repos)
    return _storage_set(data)


def get_settings():
    """Get general settings from storage. Returns a Promise."""

    def handle_result(result):
        settings = result.settings
        # JsProxy(undefined) is truthy from Python's perspective (no
        # __bool__), so `if not settings` misses the empty case — check
        # the underlying handle. Same pattern as get_repos().
        if settings is None or settings._h == 0:
            # Default settings
            defaults = create_obj()
            defaults.set("checkInterval", 5)
            return defaults
        return settings

    return chrome.storage.local.get("settings").then(handle_result)


def save_settings(settings):
    """Save settings to storage. Returns a Promise."""
    data = create_obj()
    data.set("settings", settings)
    return _storage_set(data)


def show_status(message, is_error):
    """Show status message."""
    status_el = get_element("status-message")
    status_el.set("textContent", message)
    status_el.set("className", "status-message")
    if is_error:
        status_el.classList.add("status-error")
    else:
        status_el.classList.add("status-success")
    status_el.style.set("display", "block")

    # Hide after 3 seconds. `js.setTimeout` is not a pre-instantiated global
    # in petitpy-lib/js.py and MICROPY_MODULE_GETATTR is disabled, so
    # attribute access raises AttributeError (silently swallowed by the
    # callback dispatcher). Route through js.get().
    def hide_status():
        status_el.style.set("display", "none")

    js.get("setTimeout")(hide_status, 3000)


def update_form_for_provider(provider):
    """Update form fields based on selected provider."""
    config = PROVIDER_CONFIG.get(provider, PROVIDER_CONFIG["sourcehut"])

    # Update identifier field
    label_el = get_element("identifier-label")
    identifier_el = get_element("identifier")
    help_el = get_element("identifier-help")

    label_el.set("textContent", config["label"])
    identifier_el.set("placeholder", config["placeholder"])
    help_el.set("textContent", config["help"])

    # Update token field visibility
    token_group = get_element("token-group")
    token_help = get_element("token-help")

    if config["needsToken"]:
        token_group.style.set("display", "block")
        token_help.set("textContent", config["tokenHelp"])
    else:
        # Show token group for github (optional) and gitlab (required)
        if provider == "github":
            token_group.style.set("display", "block")
            token_help.set("textContent", config["tokenHelp"])
        else:
            token_group.style.set("display", "none")


def create_repo_item(repo):
    """Create DOM element for a repo item.

    `repo` is a JsProxy (came from chrome.storage.local.get("repos")).
    Reads go through attribute access; writes on created DOM nodes go
    through `.set()`.
    """
    li = js.document.createElement("li")
    li.set("className", "repo-item")
    li.dataset.set("id", repo.id)

    # Repo info
    info_div = js.document.createElement("div")
    info_div.set("className", "repo-info")

    name_div = js.document.createElement("div")
    name_div.set("className", "repo-name")
    # repo.identifier may be undefined; fall back to the literal string.
    identifier = repo.identifier
    if identifier is None:
        identifier = "Unknown"
    name_div.set("textContent", identifier)
    info_div.appendChild(name_div)

    provider_div = js.document.createElement("div")
    provider_div.set("className", "repo-provider")
    provider_val = repo.provider
    if provider_val is None:
        provider_val = ""
    provider_div.set("textContent", provider_val)
    info_div.appendChild(provider_div)

    li.appendChild(info_div)

    # Actions
    actions_div = js.document.createElement("div")
    actions_div.set("className", "repo-actions")

    delete_btn = js.document.createElement("button")
    delete_btn.set("className", "btn btn-danger btn-sm")
    delete_btn.set("textContent", "Remove")

    # Capture the id as a Python string; JsProxy doesn't implement __eq__,
    # so JsProxy(id) != JsProxy(id) is True under default identity
    # comparison — which would defeat the equality check in delete_repo.
    repo_id_proxy = repo.id
    if repo_id_proxy is not None and repo_id_proxy._h != 0:
        repo_id = repo_id_proxy.to_str()
    else:
        repo_id = ""

    def on_delete(event):
        delete_repo(repo_id)

    delete_btn.addEventListener("click", on_delete)
    actions_div.appendChild(delete_btn)

    li.appendChild(actions_div)

    return li


def render_repos():
    """Render the list of monitored repos."""
    repo_list = get_element("repo-list")

    def handle_repos(repos):
        # Clear list
        repo_list.set("innerHTML", "")

        # `repos` is a JsProxy wrapping a JS array; `len()` is unsupported,
        # use `.length.to_int()` (same pattern as pages_status.py).
        repos_len = repos.length.to_int()
        if repos_len == 0:
            empty_li = js.document.createElement("li")
            empty_li.set("className", "empty-message")
            empty_li.set("textContent", "No repositories configured")
            repo_list.appendChild(empty_li)
            return

        # Add repo items. Subscripting (`repos[i]`) is unsupported on the
        # JS-array JsProxy — use `getattr(repos, str(i))` (same pattern as
        # providers_github.py).
        i = 0
        while i < repos_len:
            repo = getattr(repos, str(i))
            item = create_repo_item(repo)
            repo_list.appendChild(item)
            i = i + 1

    get_repos().then(handle_repos)


def add_repo():
    """Add a new repository."""
    provider_el = get_element("provider")
    identifier_el = get_element("identifier")
    token_el = get_element("token")

    provider = provider_el.value.to_str()
    identifier = identifier_el.value.to_str().strip()
    token = token_el.value.to_str().strip()

    if not identifier:
        show_status("Please enter a repository identifier", True)
        return

    # Validate based on provider
    if provider == "github":
        if "/" not in identifier:
            show_status("GitHub repository must be in format owner/repo", True)
            return

    if provider == "gitlab":
        if not token:
            show_status("GitLab requires a personal access token", True)
            return

    # Create repo object as a real JS object so it round-trips through
    # chrome.storage.local.set (which marshals via the bridge).
    repo = create_obj()
    repo.set("id", generate_id())
    repo.set("provider", provider)
    repo.set("identifier", identifier)
    repo.set("enabled", True)
    repo.set("lastChecked", 0)

    if token:
        repo.set("token", token)

    def handle_repos(repos):
        # `repos` is a JS array (JsProxy); use the JS `.push` rather than
        # Python `.append` so the value lands on the JS side.
        # Check for duplicates first — same (provider, identifier) pair
        # in the list is rejected with a visible error.
        n = repos.length.to_int()
        i = 0
        while i < n:
            existing = getattr(repos, str(i))
            ex_provider = existing.provider
            ex_identifier = existing.identifier
            if ex_provider is not None and ex_provider._h != 0:
                ex_provider_s = ex_provider.to_str()
            else:
                ex_provider_s = ""
            if ex_identifier is not None and ex_identifier._h != 0:
                ex_identifier_s = ex_identifier.to_str()
            else:
                ex_identifier_s = ""
            if ex_provider_s == provider and ex_identifier_s == identifier:
                show_status(
                    "Repository already exists: " + provider + " / " + identifier,
                    True,
                )
                return
            i = i + 1

        repos.push(repo)

        def after_save(result):
            # Clear form
            identifier_el.set("value", "")
            token_el.set("value", "")
            # Re-render
            render_repos()
            show_status("Repository added successfully", False)

        save_repos(repos).then(after_save)

    get_repos().then(handle_repos)


def delete_repo(repo_id):
    """Delete a repository."""

    def handle_repos(repos):
        # Filter out the repo. Build a fresh JS array so the result can
        # be stored back without dragging the removed entry along.
        new_repos = js.get("Array")()
        i = 0
        # `len()` on a JsProxy array is unsupported; use `.length.to_int()`.
        # Subscripting (`repos[i]`) likewise unsupported — use
        # `getattr(repos, str(i))` (same pattern as providers_github.py).
        repos_len = repos.length.to_int()
        while i < repos_len:
            repo = getattr(repos, str(i))
            # `repo.id` is a JsProxy; JsProxy has no __eq__, so direct
            # comparison against a Python string fails (identity-only).
            # Coerce via .to_str() before the comparison.
            this_id_proxy = repo.id
            if this_id_proxy is not None and this_id_proxy._h != 0:
                this_id = this_id_proxy.to_str()
            else:
                this_id = ""
            if this_id != repo_id:
                new_repos.push(repo)
            i = i + 1

        def after_save(result):
            render_repos()
            show_status("Repository removed", False)

        save_repos(new_repos).then(after_save)

    get_repos().then(handle_repos)


def test_connection():
    """Test connection to the selected provider."""
    provider_el = get_element("provider")
    identifier_el = get_element("identifier")
    token_el = get_element("token")

    provider = provider_el.value.to_str()
    identifier = identifier_el.value.to_str().strip()
    token = token_el.value.to_str().strip()

    if not identifier:
        show_status("Please enter a repository identifier", True)
        return

    show_status("Testing connection...", False)

    url = ""
    headers = create_obj()

    if provider == "sourcehut":
        url = "https://builds.sr.ht/~" + identifier + "/rss.xml"
    elif provider == "github":
        url = "https://api.github.com/repos/" + identifier + "/actions/runs?per_page=1"
        headers.set("Accept", "application/vnd.github.v3+json")
        if token:
            headers.set("Authorization", "Bearer " + token)
    elif provider == "gitlab":
        if not token:
            show_status("GitLab requires a token", True)
            return
        encoded = js.get("encodeURIComponent")(identifier).to_str()
        url = "https://gitlab.com/api/v4/projects/" + encoded + "/pipelines?per_page=1"
        headers.set("PRIVATE-TOKEN", token)

    fetch_options = create_obj()
    fetch_options.set("headers", headers)

    def handle_response(response):
        if response.ok:
            show_status("Connection successful!", False)
        else:
            show_status("Connection failed: " + response.status.to_str(), True)

    def handle_error(error):
        show_status("Connection error: " + error.to_str(), True)

    # `js.fetch` is not a pre-instantiated global in petitpy-lib/js.py and
    # MICROPY_MODULE_GETATTR is disabled, so attribute access raises
    # AttributeError (silently swallowed by the callback dispatcher). Route
    # through js.get() — same pattern as providers_sourcehut.py.
    js.get("fetch")(proxy_url(url), fetch_options).then(handle_response).catch(handle_error)



def save_general_settings():
    """Save general settings."""
    interval_el = get_element("check-interval")
    interval = interval_el.value.to_int()

    def handle_settings(settings):
        settings.set("checkInterval", interval)

        def after_save(result):
            # Send message to background script to update alarm
            # (options page doesn't have direct access to alarms API in Firefox)
            message = create_obj()
            message.set("action", "updateInterval")
            message.set("interval", interval)
            chrome.runtime.sendMessage(message)
            show_status("Settings saved", False)

        save_settings(settings).then(after_save)

    get_settings().then(handle_settings)


def load_settings():
    """Load and apply saved settings."""

    def handle_settings(settings):
        # settings may be a JsProxy (from storage) or a freshly-created JS
        # object (from get_settings's defaults branch). Either way, the
        # field lives as an attribute and a JS number round-trips as a
        # JsProxy that needs explicit `.to_int()`. JsProxy(undefined)
        # has _h == 0 — guard before `.to_int()` since `undefined | 0 = 0`
        # would silently produce 0 (not a valid <select> option value).
        interval_proxy = settings.checkInterval
        if interval_proxy is None or interval_proxy._h == 0:
            interval = 5
        else:
            interval = interval_proxy.to_int()
        interval_el = get_element("check-interval")
        interval_el.set("value", str(interval))

    get_settings().then(handle_settings)


def toggle_token_visibility():
    """Toggle token input visibility."""
    token_el = get_element("token")
    current_type = token_el.type.to_str()
    if current_type == "password":
        token_el.set("type", "text")
    else:
        token_el.set("type", "password")


def clear_build_data():
    """Clear build data while keeping repository configuration."""
    confirmed = js.get("confirm")(
        "This will clear all cached build data (repositories, history, failed builds). Your monitored sources configuration will be kept. Continue?"
    )
    if not confirmed:
        return

    # Clear build-related data but keep repos (sources) config
    data = create_obj()
    data.set("repositories", create_obj())
    data.set("failedBuilds", js.get("Array")())
    data.set("buildHistory", js.get("Array")())
    data.set("ignoredBuilds", js.get("Array")())

    def after_clear(result):
        show_status("Build data cleared successfully", False)

    _storage_set(data).then(after_clear)


def reset_all_config():
    """Reset all configuration and data."""
    confirmed = js.get("confirm")(
        "WARNING: This will delete ALL your settings, monitored repositories, and build data. This cannot be undone!\n\nAre you sure you want to continue?"
    )
    if not confirmed:
        return

    # Double confirm for dangerous action
    confirmed2 = js.get("confirm")("Final confirmation: Delete everything?")
    if not confirmed2:
        return

    def after_clear(result):
        show_status("All configuration has been reset", False)
        render_repos()
        load_settings()

    chrome.storage.local.clear().then(after_clear)


# ============================================================
# Export / Import
# ============================================================

# Current export format version
EXPORT_VERSION = "1.0"


def export_settings():
    """Export settings only (repos configuration and general settings)."""

    def handle_data(data):
        export_obj = create_obj()
        export_obj.set("version", EXPORT_VERSION)
        export_obj.set("type", "settings")
        export_obj.set("exportedAt", _iso_now())

        export_data = create_obj()

        # Include repos (source configurations)
        repos = data.repos
        if repos:
            export_data.set("repos", repos)
        else:
            export_data.set("repos", js.get("Array")())

        # Include settings
        settings = data.settings
        if settings:
            export_data.set("settings", settings)
        else:
            export_data.set("settings", create_obj())

        export_obj.set("data", export_data)

        # Trigger download
        download_json(export_obj, "ci-build-monitor-settings.json")
        show_status("Settings exported successfully", False)

    get_all_storage().then(handle_data)


def export_full():
    """Export full state including historical data."""

    def handle_data(data):
        export_obj = create_obj()
        export_obj.set("version", EXPORT_VERSION)
        export_obj.set("type", "full")
        export_obj.set("exportedAt", _iso_now())

        export_data = create_obj()

        # Include repos (source configurations)
        repos = data.repos
        if repos:
            export_data.set("repos", repos)
        else:
            export_data.set("repos", js.get("Array")())

        # Include settings
        settings = data.settings
        if settings:
            export_data.set("settings", settings)
        else:
            export_data.set("settings", create_obj())

        # Include repositories (build data)
        repositories = data.repositories
        if repositories:
            export_data.set("repositories", repositories)
        else:
            export_data.set("repositories", create_obj())

        # Include sleeping repos
        sleeping_repos = data.sleepingRepos
        if sleeping_repos:
            export_data.set("sleepingRepos", sleeping_repos)
        else:
            export_data.set("sleepingRepos", js.get("Array")())

        # Include failed builds
        failed_builds = data.failedBuilds
        if failed_builds:
            export_data.set("failedBuilds", failed_builds)
        else:
            export_data.set("failedBuilds", js.get("Array")())

        # Include ignored builds
        ignored_builds = data.ignoredBuilds
        if ignored_builds:
            export_data.set("ignoredBuilds", ignored_builds)
        else:
            export_data.set("ignoredBuilds", js.get("Array")())

        # Include build history
        build_history = data.buildHistory
        if build_history:
            export_data.set("buildHistory", build_history)
        else:
            export_data.set("buildHistory", js.get("Array")())

        export_obj.set("data", export_data)

        # Trigger download
        download_json(export_obj, "ci-build-monitor-full.json")
        show_status("Full backup exported successfully", False)

    get_all_storage().then(handle_data)


def download_json(obj, filename):
    """Trigger a JSON file download."""
    # Python `None` can't cross the js bridge (`_marshal` raises TypeError),
    # so `JSON.stringify(obj, None, 2)` is unreachable. Route through a
    # JS-side wrapper that passes the real `null` for the replacer.
    json_str = _stringify_pretty(obj)
    # `new Blob([json_str], {type: "application/json"})` — the bridge can't
    # `new`, so route through an `eval`-constructed factory.
    parts = js.get("Array")()
    parts.push(json_str)
    blob_opts = create_obj()
    blob_opts.set("type", "application/json")
    blob_factory = js.get("eval")("(function(p,o){return new Blob(p,o);})")
    blob = blob_factory(parts, blob_opts)
    url = js.get("URL").createObjectURL(blob).to_str()

    link = js.document.createElement("a")
    link.set("href", url)
    link.set("download", filename)
    js.document.body.appendChild(link)
    link.click()
    js.document.body.removeChild(link)
    js.get("URL").revokeObjectURL(url)


def trigger_import():
    """Open file picker for import."""
    file_input = get_element("import-file")
    file_input.click()


def handle_import_file(event):
    """Handle the selected import file."""
    files = event.target.files
    if not files or files.length.to_int() == 0:
        return

    file = files[0]
    # Construct `new FileReader()` via eval — the bridge can't `new`.
    reader = js.get("eval")("(new FileReader())")

    def on_load(load_event):
        content = load_event.target.result.to_str()
        import_data = _json_parse_or_null(content)
        if import_data._h == 0:
            show_status("Invalid JSON file", True)
            return
        process_import(import_data)

    reader.set("onload", on_load)
    reader.readAsText(file)

    # Clear the input so the same file can be selected again
    event.target.set("value", "")


def process_import(import_data):
    """Process and validate imported data."""
    # Check version. JSON.parse returns JsProxy values for strings; coerce.
    version = import_data.version
    if not version:
        show_status("Invalid export file: missing version", True)
        return
    version_str = version.to_str()

    # Check type
    export_type = import_data.type
    if not export_type:
        show_status("Invalid export file: missing type", True)
        return
    export_type_str = export_type.to_str()

    data = import_data.data
    if not data:
        show_status("Invalid export file: missing data", True)
        return

    # Apply migrations based on version
    migrated_data = migrate_data(version_str, data)
    if not migrated_data:
        show_status("Failed to migrate data from version " + version_str, True)
        return

    # Confirm import
    if export_type_str == "settings":
        msg = "This will replace your current settings and repository configuration. Continue?"
    else:
        msg = "This will replace ALL your data including settings, repositories, and build history. Continue?"

    confirmed = js.get("confirm")(msg)
    if not confirmed:
        return

    # Apply the import
    apply_import(export_type_str, migrated_data)


def migrate_data(version, data):
    """Migrate data from older versions to current format."""
    # Version 1.0 is the current version, no migration needed
    if version == "1.0":
        return data

    # Future versions: add migration logic here
    # Unknown version
    js.console.log("Unknown export version: " + version)
    return data  # Try to import anyway


def copy_import_field(save_data, data, field_name):
    """Copy a field from import data to save_data if it exists.

    `data` is a JsProxy (from JSON.parse on the imported file); use
    getattr to look up dynamic field names. `save_data` is a freshly
    created JS object — writes go through `.set()`.
    """
    value = getattr(data, field_name, None)
    if value:
        save_data.set(field_name, value)


def build_settings_import_data(data):
    """Build save_data for settings-only import."""
    save_data = create_obj()
    copy_import_field(save_data, data, "repos")
    copy_import_field(save_data, data, "settings")
    return save_data


def build_full_import_data(data):
    """Build save_data for full import."""
    save_data = create_obj()
    copy_import_field(save_data, data, "repos")
    copy_import_field(save_data, data, "settings")
    copy_import_field(save_data, data, "repositories")
    copy_import_field(save_data, data, "sleepingRepos")
    copy_import_field(save_data, data, "failedBuilds")
    copy_import_field(save_data, data, "ignoredBuilds")
    copy_import_field(save_data, data, "buildHistory")
    return save_data


def apply_import(export_type, data):
    """Apply imported data to storage."""
    if export_type == "settings":
        save_data = build_settings_import_data(data)
        message = "Settings imported successfully"
    else:
        save_data = build_full_import_data(data)
        message = "Full backup imported successfully"

    def on_saved(result):
        show_status(message, False)
        render_repos()
        load_settings()

    _storage_set(save_data).then(on_saved)


def on_provider_change(event=None):
    """Handle provider selection change.

    The js bridge drops args to Python callbacks, so we can't read
    `event.target.value`. Read
    the provider value off the DOM element directly.
    """
    provider = get_element("provider").value.to_str()
    update_form_for_provider(provider)


def setup_event_listeners():
    """Set up all event listeners for the options page."""
    get_element("provider").addEventListener("change", on_provider_change)
    get_element("add-btn").addEventListener("click", lambda e: add_repo())
    get_element("test-btn").addEventListener("click", lambda e: test_connection())
    get_element("save-settings-btn").addEventListener(
        "click", lambda e: save_general_settings()
    )
    get_element("token-toggle").addEventListener(
        "click", lambda e: toggle_token_visibility()
    )
    get_element("clear-data-btn").addEventListener(
        "click", lambda e: clear_build_data()
    )
    get_element("reset-all-btn").addEventListener("click", lambda e: reset_all_config())
    get_element("export-settings-btn").addEventListener(
        "click", lambda e: export_settings()
    )
    get_element("export-full-btn").addEventListener("click", lambda e: export_full())
    get_element("import-btn").addEventListener("click", lambda e: trigger_import())
    get_element("import-file").addEventListener("change", handle_import_file)


def init():
    """Initialize the options page."""
    setup_event_listeners()

    # Initial setup
    update_form_for_provider("sourcehut")
    render_repos()
    load_settings()


# Wait for DOM then initialize.
#
# The wasm/Python pipeline is async (wasm fetch + compile, then sources
# fetched, then interpreted), so by the time we get here DOMContentLoaded
# has almost certainly already fired. Check readyState and call init()
# directly if the DOM is already past "loading"; otherwise register the
# listener for the future-firing case. (Same pattern as pages_popup.py.)
if js.document.readyState.to_str() == "loading":
    js.document.addEventListener("DOMContentLoaded", init)
else:
    init()
