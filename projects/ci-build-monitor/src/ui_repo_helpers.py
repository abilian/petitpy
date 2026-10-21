# Repository Helpers
# Common repository-related utility functions

from ui_dom import get_prop


def is_repo_sleeping(sleeping_repos, source_id, repo_name):
    """Check if a repo is in the sleeping list."""
    idx = 0
    while idx < len(sleeping_repos):
        item = sleeping_repos[idx]
        if item.sourceId == source_id and item.repoName == repo_name:
            return True
        idx = idx + 1
    return False


def get_repo_url(provider, identifier, repo_name):
    """Build URL for a repository."""
    if provider == "sourcehut":
        # identifier is username, repo_name is the repo
        return "https://git.sr.ht/~" + identifier + "/" + repo_name
    elif provider == "github":
        return "https://github.com/" + identifier
    elif provider == "gitlab":
        return "https://gitlab.com/" + identifier
    return ""


def get_full_repo_name(provider, identifier, repo_name):
    """Get full repository name including owner/org."""
    if provider == "sourcehut":
        return "~" + identifier + "/" + repo_name
    elif provider == "github" or provider == "gitlab":
        # For GitHub/GitLab, identifier is already owner/repo
        return identifier
    return repo_name


def get_latest_commit_info(repo):
    """Get info from the latest commit (message, url, hash, timestamp)."""
    commits = get_prop(repo, "commits", [])
    if not commits or len(commits) == 0:
        return None

    latest = commits[0]
    message = get_prop(latest, "message", "")
    commit_hash = get_prop(latest, "hash", "")
    timestamp = get_prop(latest, "timestamp", 0)

    # Get URL from first build if available
    builds = get_prop(latest, "builds", [])
    url = ""
    if builds and len(builds) > 0:
        url = get_prop(builds[0], "url", "")

    return {
        "message": message,
        "hash": commit_hash,
        "timestamp": timestamp,
        "url": url,
    }
