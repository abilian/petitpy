# GitLab CI Provider
# Monitors GitLab CI pipelines via API

import js
import json

from core_utils import proxy_url
from providers_base import create_build, create_obj



def process_gitlab_pipeline(pipeline, last_checked, identifier):
    """Process a single GitLab pipeline. Returns (is_failed, build_or_none)."""
    pipeline_time = js.get("Date").parse(pipeline.updated_at).to_int()
    pipeline_status = pipeline.status.to_str()

    if pipeline_status != "failed":
        return False, None

    # Check if newer than last check
    if last_checked and pipeline_time <= last_checked:
        return True, None

    pipeline_id = pipeline.id.to_str()
    ref = pipeline.ref.to_str()
    title = "Pipeline #" + pipeline_id + " (" + ref + ") - " + identifier
    web_url = pipeline.web_url.to_str()

    build = create_build(pipeline_id, title, web_url, "failed", pipeline_time, "")
    return True, build


def determine_gitlab_status(latest_status):
    """Determine repo status from latest pipeline status."""
    if latest_status == "failed":
        return "failed"
    if latest_status == "running" or latest_status == "pending":
        return "unknown"
    return "ok"


def process_gitlab_pipelines(pipelines, last_checked, identifier):
    """Process all GitLab pipelines. Returns (new_failures, total_failed, repo_entry)."""
    new_failures = []
    total_failed = 0

    pipelines_len = pipelines.length.to_int()
    if pipelines_len == 0:
        return new_failures, total_failed, None

    # Latest pipeline for repo status
    latest_pipeline = getattr(pipelines, "0")
    latest_time = js.get("Date").parse(latest_pipeline.updated_at).to_int()
    latest_status = latest_pipeline.status.to_str()
    latest_url = latest_pipeline.web_url.to_str()

    # Process all pipelines
    i = 0
    while i < pipelines_len:
        is_failed, build = process_gitlab_pipeline(
            getattr(pipelines, str(i)), last_checked, identifier
        )
        if is_failed:
            total_failed = total_failed + 1
            if build:
                new_failures.append(build)
        i = i + 1

    repo_status = determine_gitlab_status(latest_status)

    repo_entry = {
        "name": identifier,
        "status": repo_status,
        "timestamp": latest_time,
        "title": "Pipeline #" + latest_pipeline.id.to_str(),
        "url": latest_url,
        "provider": "gitlab",
        "identifier": identifier,
    }

    js.console.log(
        "[GitLab] Repo:",
        identifier,
        "Latest status:",
        repo_status,
        "Total failed pipelines:",
        total_failed,
        "New failures:",
        len(new_failures),
    )

    return new_failures, total_failed, repo_entry


class GitLabProvider:
    """GitLab CI provider using REST API."""

    name = "gitlab"

    def build_url(self, config):
        """Build the GitLab API URL for pipelines."""
        identifier = config.get("identifier", "")
        if not identifier:
            return ""
        encoded = js.get("encodeURIComponent")(identifier).to_str()
        return (
            "https://gitlab.com/api/v4/projects/" + encoded + "/pipelines?per_page=20"
        )

    def get_failed_builds(self, config):
        """Fetch pipelines from GitLab API. Returns a Promise with repo status."""
        url = self.build_url(config)
        if not url:
            return js.get("Promise").resolve([])

        last_checked = config.get("lastChecked", 0)
        token = config.get("token", "")

        if not token:
            js.console.warn("GitLab requires a personal access token")
            return js.get("Promise").resolve([])

        headers = create_obj()
        headers.set("PRIVATE-TOKEN", token)

        fetch_options = create_obj()
        fetch_options.set("headers", headers)

        identifier = config.get("identifier", "")

        def handle_response(response):
            if not response.ok:
                js.console.error("GitLab API error:", response.status)
                return js.get("Promise").resolve([])
            return response.json()

        def process_data(pipelines):
            new_failures, total_failed, repo_entry = process_gitlab_pipelines(
                pipelines, last_checked, identifier
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
            js.console.error("Error fetching GitLab API:", error)
            return []

        return (
            js.get("fetch")(proxy_url(url), fetch_options)
            .then(handle_response)
            .then(process_data)
            .catch(handle_error)
        )
