# Storage Functions
# Chrome storage operations for repos, builds, history, and ignored builds

import js
from providers_base import create_obj

# chrome is not pre-instantiated in petitpy-lib/js.py; fetch the global
# once at module load and reuse. See projects/ci-build-monitor/notes/PORTING.md.
chrome = js.get("chrome")


# =============================================================================
# Repo Storage
# =============================================================================


def get_monitored_repos():
    """Get list of monitored repos from storage. Returns a Promise."""

    def handle_result(result):
        repos = result.repos
        if not repos:
            return []
        return repos

    return chrome.storage.local.get("repos").then(handle_result)


def save_monitored_repos(repos):
    """Save list of monitored repos to storage. Returns a Promise."""
    data = create_obj()
    data.set("repos", repos)
    return chrome.storage.local.set(data)


def update_source_status(source_id, timestamp, status, failed_count):
    """Update monitored source status."""

    def handle_sources(sources):
        i = 0
        while i < len(sources):
            source = sources[i]
            if source.id == source_id:
                source.set("lastChecked", timestamp)
                source.set("status", status)
                source.set("failedCount", failed_count)
                break
            i = i + 1
        return save_monitored_repos(sources)

    return get_monitored_repos().then(handle_sources)


def save_repositories(source_id, repos_dict):
    """Save repository data to storage.

    repos_dict is keyed by repo name, each containing:
    - name, owner, provider, status, commits[], url

    Storage structure:
    repositories = {
        source_id: {
            repo_name: {...},
            repo_name2: {...}
        }
    }
    """

    def handle_result(result):
        all_repos = result.repositories
        if not all_repos:
            all_repos = create_obj()

        # NOTE: dynamic-key read on a JsProxy (all_repos[source_id]) is an
        # open question in notes/PORTING.md. We overwrite the per-source
        # bucket wholesale instead of merging into an existing one. Repos
        # under OTHER source_ids on all_repos are preserved (we never read
        # them); only the bucket for THIS source_id is replaced. Loss is
        # bounded to repo entries that pre-existed for THIS source and
        # weren't included in the new repos_dict.
        source_bucket = create_obj()
        for repo_name in repos_dict:
            repo_data = repos_dict[repo_name]
            source_bucket.set(repo_name, repo_data)

        all_repos.set(source_id, source_bucket)

        data = create_obj()
        data.set("repositories", all_repos)
        return chrome.storage.local.set(data)

    return chrome.storage.local.get("repositories").then(handle_result)


def save_failed_builds(repo_id, new_builds, provider, identifier):
    """Save failed builds to storage."""

    def handle_result(result):
        all_builds = result.failedBuilds
        if not all_builds:
            all_builds = []

        # Add new builds with repo_id and provider info
        i = 0
        while i < len(new_builds):
            build = new_builds[i]
            build_obj = create_obj()
            build_obj.set("id", build.id)
            build_obj.set("title", build.title)
            build_obj.set("url", build.url)
            build_obj.set("status", build.status)
            build_obj.set("timestamp", build.timestamp)
            build_obj.set("author", build.author)
            build_obj.set("repoId", repo_id)
            build_obj.set("provider", provider)
            build_obj.set("identifier", identifier)
            all_builds.append(build_obj)
            i = i + 1

        # Keep only last 50 builds
        if len(all_builds) > 50:
            all_builds = all_builds[-50:]

        data = create_obj()
        data.set("failedBuilds", all_builds)
        return chrome.storage.local.set(data)

    return chrome.storage.local.get("failedBuilds").then(handle_result)


# =============================================================================
# Ignore Functionality
# =============================================================================


def get_ignored_builds():
    """Get list of ignored build IDs from storage. Returns a Promise."""

    def handle_result(result):
        ignored = result.ignoredBuilds
        if not ignored:
            return []
        return ignored

    return chrome.storage.local.get("ignoredBuilds").then(handle_result)


def ignore_build(build_id, build_title):
    """Add a build to the ignore list."""

    def handle_result(result):
        ignored = result.ignoredBuilds
        if not ignored:
            ignored = []

        # Check if already ignored
        i = 0
        while i < len(ignored):
            if ignored[i].id == build_id:
                js.console.log("[Ignore] Build already ignored:", build_id)
                return js.get("Promise").resolve(None)
            i = i + 1

        # Add to ignore list
        entry = create_obj()
        entry.set("id", build_id)
        entry.set("title", build_title)
        entry.set("ignoredAt", js.get("Date").now())
        ignored.append(entry)

        js.console.log("[Ignore] Added build to ignore list:", build_id)

        data = create_obj()
        data.set("ignoredBuilds", ignored)
        return chrome.storage.local.set(data)

    return chrome.storage.local.get("ignoredBuilds").then(handle_result)


def unignore_build(build_id):
    """Remove a build from the ignore list."""

    def handle_result(result):
        ignored = result.ignoredBuilds
        if not ignored:
            return js.get("Promise").resolve(None)

        # Find and remove
        new_ignored = []
        i = 0
        while i < len(ignored):
            if ignored[i].id != build_id:
                new_ignored.append(ignored[i])
            i = i + 1

        js.console.log("[Ignore] Removed build from ignore list:", build_id)

        data = create_obj()
        data.set("ignoredBuilds", new_ignored)
        return chrome.storage.local.set(data)

    return chrome.storage.local.get("ignoredBuilds").then(handle_result)


def is_build_ignored(build_id, ignored_list):
    """Check if a build ID is in the ignored list."""
    i = 0
    while i < len(ignored_list):
        if ignored_list[i].id == build_id:
            return True
        i = i + 1
    return False


# =============================================================================
# Build History / Timeline
# =============================================================================


def record_build_event(repo_id, identifier, provider, status, failed_count):
    """Record a build check event for timeline history."""

    def handle_result(result):
        history = result.buildHistory
        if not history:
            history = []

        # Create event entry
        event = create_obj()
        event.set("timestamp", js.get("Date").now())
        event.set("repoId", repo_id)
        event.set("identifier", identifier)
        event.set("provider", provider)
        event.set("status", status)
        event.set("failedCount", failed_count)

        history.append(event)

        # Keep only last 500 events (about 1 week at 5-min intervals for 10 repos)
        if len(history) > 500:
            history = history[-500:]

        data = create_obj()
        data.set("buildHistory", history)
        return chrome.storage.local.set(data)

    return chrome.storage.local.get("buildHistory").then(handle_result)


# =============================================================================
# Whole-store read
# =============================================================================

# `chrome.storage.local.get(null)` returns every key, but Python `None` can't
# cross the js bridge (raises TypeError on marshal). Route through a JS-side
# wrapper that passes the real `null`.
_storage_get_all = js.get("eval")("(function(){return chrome.storage.local.get(null);})")


def get_all_storage():
    """Get all storage data. Returns a Promise."""
    return _storage_get_all()
