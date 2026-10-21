# GitHub Actions CI Provider
# Monitors GitHub Actions workflow runs via API

import js
import json

from core_utils import proxy_url
from providers_base import create_build, create_obj



def process_github_run(run, last_checked):
    """Process a single GitHub workflow run. Returns (is_failed, build_or_none)."""
    run_time = js.get("Date").parse(run.updated_at).to_int()
    conclusion = run.conclusion.to_str()

    if conclusion != "failure":
        return False, None

    # Check if newer than last check
    if last_checked and run_time <= last_checked:
        return True, None

    run_id = run.id.to_str()
    name = run.name.to_str()
    repo_name = run.repository.full_name.to_str()
    title = name + " - " + repo_name
    html_url = run.html_url.to_str()

    actor = ""
    if run.actor:
        actor = run.actor.login.to_str()

    build = create_build(run_id, title, html_url, "failed", run_time, actor)
    return True, build


def process_github_runs(runs, last_checked, identifier):
    """Process all GitHub workflow runs. Returns (new_failures, total_failed, repo_entry)."""
    new_failures = []
    total_failed = 0

    runs_len = runs.length.to_int()
    if runs_len == 0:
        return new_failures, total_failed, None

    # Find latest run to determine repo status
    latest_run = getattr(runs, "0")
    latest_time = js.get("Date").parse(latest_run.updated_at).to_int()
    latest_conclusion = latest_run.conclusion.to_str()
    latest_url = latest_run.html_url.to_str()

    # Process all runs
    i = 0
    while i < runs_len:
        is_failed, build = process_github_run(getattr(runs, str(i)), last_checked)
        if is_failed:
            total_failed = total_failed + 1
            if build:
                new_failures.append(build)
        i = i + 1

    repo_status = "failed" if latest_conclusion == "failure" else "ok"

    repo_entry = {
        "name": identifier,
        "status": repo_status,
        "timestamp": latest_time,
        "title": latest_run.name.to_str(),
        "url": latest_url,
        "provider": "github",
        "identifier": identifier,
    }

    js.console.log(
        "[GitHub] Repo:",
        identifier,
        "Latest status:",
        repo_status,
        "Total failed runs:",
        total_failed,
        "New failures:",
        len(new_failures),
    )

    return new_failures, total_failed, repo_entry


class GitHubProvider:
    """GitHub Actions CI provider using REST API."""

    name = "github"

    def build_url(self, config):
        """Build the GitHub API URL for workflow runs."""
        identifier = config.get("identifier", "")
        if not identifier:
            return ""
        return (
            "https://api.github.com/repos/"
            + identifier
            + "/actions/runs?status=completed&per_page=20"
        )

    def get_failed_builds(self, config):
        """Fetch builds from GitHub Actions API. Returns a Promise with repo status."""
        url = self.build_url(config)
        if not url:
            return js.get("Promise").resolve([])

        last_checked = config.get("lastChecked", 0)
        token = config.get("token", "")
        identifier = config.get("identifier", "")

        headers = create_obj()
        headers.set("Accept", "application/vnd.github.v3+json")
        if token:
            headers.set("Authorization", "Bearer " + token)

        fetch_options = create_obj()
        fetch_options.set("headers", headers)

        def handle_response(response):
            if not response.ok:
                js.console.error("GitHub API error:", response.status)
                return js.get("Promise").resolve([])
            return response.json()

        def process_data(data):
            new_failures, _total_failed, repo_entry = process_github_runs(
                data.workflow_runs, last_checked, identifier
            )

            # JSON round-trip + Build-flattening — see providers_sourcehut
            # for full notes. Build class instances can't be json.dumps'd,
            # so flatten each to a dict first.
            failures_serializable = [
                {
                    "id": b.id, "title": b.title, "url": b.url,
                    "status": b.status, "timestamp": b.timestamp, "author": b.author,
                }
                for b in new_failures
            ]
            result = {
                "newFailures": failures_serializable,
                "totalFailedCount": (
                    1 if repo_entry and repo_entry["status"] == "failed" else 0
                ),
                "repos": [repo_entry] if repo_entry else [],
            }
            return js.get("JSON").parse(json.dumps(result))

        def handle_error(error):
            js.console.error("Error fetching GitHub API:", error)
            return []

        return (
            js.get("fetch")(proxy_url(url), fetch_options)
            .then(handle_response)
            .then(process_data)
            .catch(handle_error)
        )
