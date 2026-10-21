# Badges
# Provider badges and status indicators

import js


def get_provider_badge_text(provider):
    """Get badge text for a provider."""
    if provider == "sourcehut":
        return "sr.ht"
    if provider == "github":
        return "GH"
    if provider == "gitlab":
        return "GL"
    return provider


def get_provider_class(provider):
    """Get CSS class for provider badge."""
    if provider == "sourcehut":
        return "badge-sourcehut"
    elif provider == "github":
        return "badge-github"
    elif provider == "gitlab":
        return "badge-gitlab"
    return ""


def create_provider_badge(provider):
    """Create a provider badge element."""
    badge = js.document.createElement("span")
    badge.set("className", "badge " + get_provider_class(provider))
    badge.set("textContent", get_provider_badge_text(provider))
    return badge


def create_status_dot(status):
    """Create a status dot element."""
    status_dot = js.document.createElement("span")
    status_dot.set("className", "status-dot")
    if status == "ok":
        status_dot.classList.add("status-ok")
    elif status == "failed":
        status_dot.classList.add("status-failed")
    else:
        status_dot.classList.add("status-unknown")
    return status_dot


def get_status_class(status):
    """Get CSS class for a status."""
    if status == "ok":
        return "status-ok"
    elif status == "failed":
        return "status-failed"
    return "status-unknown"
