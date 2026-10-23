# CI Build Monitor - Background Service Worker
# Polls CI providers and sends notifications for failed builds

import js

from core_utils import count_dict_keys, create_obj
from providers_github import GitHubProvider
from providers_gitlab import GitLabProvider
from providers_sourcehut import SourcehutProvider
from services_notifications import on_notification_clicked, show_notification
from services_storage import (
    get_ignored_builds,
    get_monitored_repos,
    ignore_build,
    record_build_event,
    save_repositories,
    unignore_build,
    update_source_status,
)
from ui_dom import get_prop

# chrome is not pre-instantiated in petitpy-lib/js.py; fetch the global
# once at module load and reuse. See projects/ci-build-monitor/notes/PORTING.md.
chrome = js.get("chrome")

# =============================================================================
# Constants and Configuration
# =============================================================================

CHECK_INTERVAL = 5  # minutes
ALARM_NAME = "checkBuilds"

# Provider registry
PROVIDERS = {
    "sourcehut": SourcehutProvider,
    "github": GitHubProvider,
    "gitlab": GitLabProvider,
}


# =============================================================================
# Source Checking Functions
# =============================================================================


def notify_failures(new_failures):
    """Show notifications for new build failures."""
    if new_failures and len(new_failures) > 0:
        j = 0
        while j < len(new_failures):
            build = new_failures[j]
            show_notification(build)
            j = j + 1


def process_check_result(result, source_id, identifier, provider_name):
    """Process the result from a provider check."""
    current_time = js.get("Date").now()

    new_failures = []
    failed_count = 0
    repos_data = {}

    if result:
        # result is a Python dict returned from provider Promise chain.
        new_failures = result.get("newFailures", [])
        failed_count = result.get("failedCount", 0)
        repos_data = result.get("repos", {})

    repos_count = count_dict_keys(repos_data)

    js.console.log(
        "[check_source] Results for",
        identifier,
        "- repos:",
        repos_count,
        "- failed:",
        failed_count,
        "- new failures:",
        len(new_failures),
    )

    status = "ok"
    if failed_count > 0:
        status = "failed"

    notify_failures(new_failures)

    if repos_count > 0:
        save_repositories(source_id, repos_data)

    record_build_event(source_id, identifier, provider_name, status, failed_count)
    return update_source_status(source_id, current_time, status, failed_count)


def process_check_error(error, source_id, identifier, provider_name):
    """Process an error from a provider check."""
    js.console.error("[check_source] Error:", identifier, error)
    current_time = js.get("Date").now()
    record_build_event(source_id, identifier, provider_name, "error", 0)
    return update_source_status(source_id, current_time, "error", 0)


def check_source(source):
    """Check a monitored source for builds. Returns a Promise."""
    js.console.log(
        "[check_source] Checking:",
        get_prop(source, "identifier", ""),
        "provider:",
        get_prop(source, "provider", ""),
    )

    provider_name = get_prop(source, "provider", "")
    if not provider_name:
        js.console.log("[check_source] No provider configured")
        return js.get("Promise").resolve(None)

    ProviderClass = PROVIDERS.get(provider_name, None)
    if not ProviderClass:
        js.console.error("[check_source] Unknown provider:", provider_name)
        return js.get("Promise").resolve(None)

    provider = ProviderClass()
    source_id = source.id
    identifier = get_prop(source, "identifier", "")

    def handle_result(result):
        return process_check_result(result, source_id, identifier, provider_name)

    def handle_error(error):
        return process_check_error(error, source_id, identifier, provider_name)

    return provider.get_failed_builds(source).then(handle_result).catch(handle_error)


def update_badge():
    """Update extension badge based on repo statuses."""

    def handle_repos(repos):
        if not repos:
            # No repos - clear badge
            badge_opts = create_obj()
            badge_opts.set("text", "")
            chrome.action.setBadgeText(badge_opts)
            return

        # Count repos with failed status
        failed_count = 0
        i = 0
        while i < len(repos):
            repo = repos[i]
            status = get_prop(repo, "status", "")
            if status == "failed":
                failed_count = failed_count + 1
            i = i + 1

        js.console.log("[Badge] Failed repos:", failed_count)

        if failed_count > 0:
            # Show red badge with count
            badge_text = str(failed_count)
            if failed_count > 99:
                badge_text = "99+"
            badge_opts = create_obj()
            badge_opts.set("text", badge_text)
            chrome.action.setBadgeText(badge_opts)
            color_opts = create_obj()
            color_opts.set("color", "#f44336")  # Red
            chrome.action.setBadgeBackgroundColor(color_opts)
        else:
            # Clear badge when no failures
            badge_opts = create_obj()
            badge_opts.set("text", "")
            chrome.action.setBadgeText(badge_opts)

    get_monitored_repos().then(handle_repos)


def check_all_sources():
    """Check all monitored sources for builds."""
    js.console.log("Checking all monitored sources...")

    def process_sources(sources):
        if not sources:
            js.console.log("No sources configured")
            update_badge()
            return

        promise = js.get("Promise").resolve(None)

        def make_check_fn(s):
            def do_check(result):
                enabled = get_prop(s, "enabled", True)
                if not enabled:
                    return None
                return check_source(s)

            return do_check

        sources_len = len(sources)
        i = 0
        while i < sources_len:
            source = sources[i]
            check_fn = make_check_fn(source)
            promise = promise.then(check_fn)
            i = i + 1

        def finish(result):
            js.console.log("Finished checking all sources")
            update_badge()

        promise.then(finish)

    get_monitored_repos().then(process_sources)


# =============================================================================
# Event Handlers
# =============================================================================


def on_alarm(alarm):
    """Handle alarm events."""
    if alarm.name == ALARM_NAME:
        check_all_sources()


def on_storage_changed(changes, area):
    """Handle storage changes."""
    if area == "local":
        if changes.repos:
            js.console.log("Repos configuration changed")
            update_badge()


def on_message(message, sender, send_response):
    """Handle messages from popup/options."""
    action = message.action
    if action == "checkNow":
        check_all_sources()
    elif action == "updateInterval":
        # Update the alarm interval
        interval = message.interval
        js.console.log("Updating check interval to", interval, "minutes")
        chrome.alarms.clear(ALARM_NAME)
        alarm_info = create_obj()
        alarm_info.set("periodInMinutes", interval)
        chrome.alarms.create(ALARM_NAME, alarm_info)
    elif action == "ignoreBuild":
        # Add a build to the ignore list
        build_id = message.buildId
        build_title = message.buildTitle
        js.console.log("[Message] Ignoring build:", build_id)
        ignore_build(build_id, build_title)
    elif action == "unignoreBuild":
        # Remove a build from the ignore list
        build_id = message.buildId
        js.console.log("[Message] Un-ignoring build:", build_id)
        unignore_build(build_id)
    elif action == "getIgnoredBuilds":
        # Return list of ignored builds
        def send_ignored(ignored):
            response = create_obj()
            response.set("ignored", ignored)
            send_response(response)

        get_ignored_builds().then(send_ignored)
        return True  # Indicates async response
    return False


# =============================================================================
# Initialization
# =============================================================================


def init():
    """Initialize the background service worker."""
    js.console.log("CI Build Monitor initializing...")

    alarm_info = create_obj()
    alarm_info.set("periodInMinutes", CHECK_INTERVAL)
    chrome.alarms.create(ALARM_NAME, alarm_info)

    chrome.alarms.onAlarm.addListener(on_alarm)
    chrome.notifications.onClicked.addListener(on_notification_clicked)
    chrome.storage.onChanged.addListener(on_storage_changed)
    chrome.runtime.onMessage.addListener(on_message)

    check_all_sources()

    js.console.log("CI Build Monitor initialized")


# Run initialization
init()
