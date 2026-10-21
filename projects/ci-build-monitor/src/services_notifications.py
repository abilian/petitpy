# Notification Functions
# Desktop notification handling with batching support

import js
from providers_base import create_obj

# chrome is not pre-instantiated in nanopython-lib/js.py; fetch the global
# once at module load and reuse. See projects/ci-build-monitor/notes/PORTING.md.
chrome = js.get("chrome")

# Constants
NOTIFICATION_FLUSH_DELAY = 3000  # 3 seconds in milliseconds

# Notification batching state
notification_buffer = []
notification_timeout_id = None
notification_urls = {}  # Maps notification_id to URL for click handling


# =============================================================================
# Notification Batching
# =============================================================================


def queue_notification(build):
    """Add a notification to the buffer. Will be flushed after delay."""
    global notification_timeout_id
    notification_buffer.append(build)
    js.console.log(
        "[Notifications] Queued:", build.title, "Buffer size:", len(notification_buffer)
    )

    # If no flush is scheduled, schedule one
    if notification_timeout_id is None:

        def do_flush():
            flush_notifications()

        notification_timeout_id = js.get("setTimeout")(do_flush, NOTIFICATION_FLUSH_DELAY)
        js.console.log(
            "[Notifications] Scheduled flush in", NOTIFICATION_FLUSH_DELAY, "ms"
        )


def flush_notifications():
    """Flush all buffered notifications."""
    global notification_timeout_id
    notification_timeout_id = None

    buffer_len = len(notification_buffer)
    js.console.log("[Notifications] Flushing", buffer_len, "notifications")

    if buffer_len == 0:
        return

    if buffer_len == 1:
        # Single notification - show as before
        build = notification_buffer[0]
        show_single_notification(build)
    else:
        # Multiple notifications - show combined
        show_combined_notification()

    # Clear the buffer (can't use .clear() due to Prescrypt)
    while len(notification_buffer) > 0:
        notification_buffer.pop()


# =============================================================================
# Notification Display
# =============================================================================


def show_single_notification(build):
    """Display a single desktop notification for a failed build."""
    notification_id = "build-" + build.id.to_str()

    # Store URL for click handling
    if build.url:
        notification_urls[notification_id] = build.url

    options = create_obj()
    options.set("type", "basic")
    options.set("iconUrl", "icons/icon48.png")
    options.set("title", "Build Failed")
    options.set("message", build.title.to_str())

    if build.url:
        options.set("message", build.title.to_str() + "\nClick to view")

    chrome.notifications.create(notification_id, options)
    js.console.log("[Notifications] Shown single:", build.title)


def show_combined_notification():
    """Display a combined notification for multiple failed builds."""
    count = len(notification_buffer)

    # Get first URL for click handling
    first_url = None
    i = 0
    while i < count:
        build = notification_buffer[i]
        if build.url:
            first_url = build.url
            break
        i = i + 1

    # Build message with first few titles
    titles_shown = 0
    message = ""
    j = 0
    while j < count and titles_shown < 3:
        build = notification_buffer[j]
        if titles_shown > 0:
            message = message + ", "
        message = message + build.title.to_str()
        titles_shown = titles_shown + 1
        j = j + 1

    if count > 3:
        remaining = count - 3
        message = message + " and " + str(remaining) + " more"

    # Date.now() returns ms-since-epoch (~1.7e12), which overflows nano's
    # 30-bit smallint cap; route through to_str() to keep the value JS-side.
    notification_id = "batch-" + js.get("Date").now().to_str()

    # Store first URL for click handling
    if first_url:
        notification_urls[notification_id] = first_url

    options = create_obj()
    options.set("type", "basic")
    options.set("iconUrl", "icons/icon48.png")
    options.set("title", str(count) + " Builds Failed")
    options.set("message", message + "\nClick to view first")

    chrome.notifications.create(notification_id, options)
    js.console.log("[Notifications] Shown combined:", count, "builds")


def show_notification(build):
    """Display a desktop notification for a failed build (batched)."""
    queue_notification(build)


# =============================================================================
# Notification Click Handler
# =============================================================================


def on_notification_clicked(notification_id):
    """Handle notification click - open the build URL."""
    js.console.log("[Notifications] Clicked:", notification_id)

    url = notification_urls.get(notification_id, None)
    if url:
        js.console.log("[Notifications] Opening URL:", url)
        tab_opts = create_obj()
        tab_opts.set("url", url)
        chrome.tabs.create(tab_opts)
        # Clean up the stored URL
        del notification_urls[notification_id]
    else:
        js.console.log("[Notifications] No URL stored for:", notification_id)

    # Clear the notification
    chrome.notifications.clear(notification_id)
