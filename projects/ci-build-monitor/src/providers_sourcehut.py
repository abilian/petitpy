# Sourcehut CI Provider
# Monitors builds via RSS feed

import js
import json

from core_utils import proxy_url
from providers_base import create_build

# JS-side JSON.parse — wrapped so the Python dict can be marshaled across
# the bridge as a JSON string and rehydrated as a real JS object on the
# other side. Direct Python-dict-to-JS-attr assignment marshals to null
# (one-way only).
_js_parse = js.get("JSON").parse

# Real epoch-ms values (~1.7e12) overflow the nano 30-bit smallint cap.
# Project onto seconds-since-2020 so the result fits. Same shape as
# pages_status._safe_ts; lifted here so providers can use it without an
# import cycle.
_safe_ts_ms = js.get("eval")(
    "(function(ts){if(ts==null||isNaN(ts))return 0;"
    "var s=Math.floor(ts/1000)-1577836800;"
    "if(s<0)s=0;if(s>536870911)s=536870911;return s;})"
)



def parse_sourcehut_description(description):
    """Parse Sourcehut RSS description to extract commit info.

    Description format:
    [63d4e82][0] — [Stefane Fermigier][1]

        chore: CI config

    [0]: https://git.sr.ht/~sfermigier/hop3/commit/63d4e82e9c638ae51308b3d10ef907fed0b98b43
    [1]: mailto:sf@abilian.com

    Returns: {repo: "hop3", commit_hash: "63d4e82", message: "chore: CI config"}
    """
    result = {"repo": "unknown", "commit_hash": "unknown", "message": ""}

    if not description:
        return result

    # Extract commit hash from the first line [hash][0]
    bracket_idx = description.find("[")
    if bracket_idx >= 0:
        end_bracket = description.find("]", bracket_idx)
        if end_bracket > bracket_idx:
            result["commit_hash"] = description[bracket_idx + 1 : end_bracket]

    # Extract repo name from git.sr.ht URL
    # Look for: https://git.sr.ht/~username/repo/commit/
    git_marker = "git.sr.ht/~"
    git_idx = description.find(git_marker)
    if git_idx >= 0:
        # Find the repo name after ~username/
        after_marker = description[git_idx + len(git_marker) :]
        # Format: username/repo/commit/hash
        slash1 = after_marker.find("/")
        if slash1 > 0:
            after_username = after_marker[slash1 + 1 :]
            slash2 = after_username.find("/")
            if slash2 > 0:
                result["repo"] = after_username[:slash2]

    # Extract commit message (text between the header and the URLs)
    # Look for text after " — " and before "[0]:"
    dash_marker = " — "
    dash_idx = description.find(dash_marker)
    url_marker = "[0]:"
    url_idx = description.find(url_marker)

    if dash_idx >= 0 and url_idx > dash_idx:
        # Find end of first line (after author name)
        newline_idx = description.find("\n", dash_idx)
        if newline_idx > 0 and newline_idx < url_idx:
            # Message is between first newline and URL marker
            message_part = description[newline_idx:url_idx].strip()
            # Clean up the message
            result["message"] = message_part

    return result


def parse_sourcehut_job_id(title):
    """Extract job ID from Sourcehut build title.

    Title format: '#1659471 (failed)'
    Returns the job ID or 'unknown'.
    """
    if not title.startswith("#"):
        return "unknown"

    space_idx = title.find(" ")
    if space_idx > 1:
        return title[1:space_idx]

    return "unknown"


def get_build_status_from_title(title):
    """Determine build status from Sourcehut title."""
    if title.endswith("(failed)"):
        return "failed"
    if title.endswith("(running)") or title.endswith("(pending)"):
        return "pending"
    return "ok"


def parse_rss_item(item):
    """Parse a single RSS item. Returns parsed build info dict."""
    pub_date_el = item.querySelector("pubDate")
    pub_date = 0
    if pub_date_el:
        # Date.parse returns epoch-ms (~1.7e12) which overflows the nano
        # 30-bit smallint when crossing .to_int(). Project to seconds-since-2020,
        # then .to_int() to get a Python int for downstream arithmetic.
        pub_date = _safe_ts_ms(js.get("Date").parse(pub_date_el.textContent)).to_int()

    title_el = item.querySelector("title")
    title = title_el.textContent.to_str() if title_el else ""

    link_el = item.querySelector("link")
    link = link_el.textContent.to_str() if link_el else ""

    guid_el = item.querySelector("guid")
    guid = guid_el.textContent.to_str() if guid_el else ""

    desc_el = item.querySelector("description")
    description = desc_el.textContent.to_str() if desc_el else ""

    author_el = item.querySelector("author")
    author = author_el.textContent.to_str() if author_el else ""

    commit_info = parse_sourcehut_description(description)
    job_id = parse_sourcehut_job_id(title)
    build_status = get_build_status_from_title(title)

    return {
        "pub_date": pub_date,
        "title": title,
        "link": link,
        "guid": guid,
        "author": author,
        "repo_name": commit_info["repo"],
        "commit_hash": commit_info["commit_hash"],
        "commit_message": commit_info["message"],
        "job_id": job_id,
        "build_status": build_status,
    }


def calculate_commit_status(builds):
    """Calculate commit status from its builds."""
    commit_failed = False
    commit_pending = False
    b_idx = 0
    while b_idx < len(builds):
        b_status = builds[b_idx]["status"]
        if b_status == "failed":
            commit_failed = True
        elif b_status == "pending":
            commit_pending = True
        b_idx = b_idx + 1

    if commit_failed:
        return "failed"
    if commit_pending:
        return "pending"
    return "ok"


def sort_commits_by_timestamp(commits_list):
    """Sort commits by timestamp descending (newest first) using bubble sort."""
    n = len(commits_list)
    ci = 0
    while ci < n:
        cj = 0
        while cj < n - ci - 1:
            if commits_list[cj]["timestamp"] < commits_list[cj + 1]["timestamp"]:
                temp = commits_list[cj]
                commits_list[cj] = commits_list[cj + 1]
                commits_list[cj + 1] = temp
            cj = cj + 1
        ci = ci + 1
    return commits_list


def build_repo_result(repo, commits_list):
    """Build final repo result structure."""
    repo_status = "ok"
    if len(commits_list) > 0:
        repo_status = commits_list[0]["status"]

    return {
        "name": repo["name"],
        "owner": repo["owner"],
        "provider": "sourcehut",
        "sourceId": repo["sourceId"],
        "url": repo["url"],
        "status": repo_status,
        "commits": commits_list,
    }


def finalize_repos(repos):
    """Convert intermediate repos structure to final result."""
    repos_result = {}

    for repo_name in repos:
        repo = repos[repo_name]
        repo_commits = repo["commits"]

        # Convert commits dict to list with calculated status
        commits_list = []
        for commit_hash in repo_commits:
            commit = repo_commits[commit_hash]
            builds = commit["builds"]
            commit_status = calculate_commit_status(builds)

            commits_list.append({
                "hash": commit["hash"],
                "message": commit["message"],
                "timestamp": commit["timestamp"],
                "status": commit_status,
                "builds": builds,
            })

        # Sort and limit
        commits_list = sort_commits_by_timestamp(commits_list)
        if len(commits_list) > 10:
            commits_list = commits_list[:10]

        repos_result[repo_name] = build_repo_result(repo, commits_list)

    return repos_result


def count_failed_repos(repos_result):
    """Count repos with failed status."""
    failed_count = 0
    for rn in repos_result:
        if repos_result[rn]["status"] == "failed":
            failed_count = failed_count + 1
    return failed_count


def add_build_to_repos(repos, parsed, username, source_id):
    """Add a parsed build to the repos structure."""
    repo_name = parsed["repo_name"]
    commit_hash = parsed["commit_hash"]
    pub_date = parsed["pub_date"]

    build_entry = {
        "id": parsed["job_id"],
        "status": parsed["build_status"],
        "url": parsed["link"],
        "timestamp": pub_date,
    }

    if repo_name not in repos:
        repos[repo_name] = {
            "name": repo_name,
            "owner": username,
            "provider": "sourcehut",
            "sourceId": source_id,
            "url": "https://git.sr.ht/~" + username + "/" + repo_name,
            "commits": {},
        }

    repo_commits = repos[repo_name]["commits"]
    if commit_hash not in repo_commits:
        repo_commits[commit_hash] = {
            "hash": commit_hash,
            "message": parsed["commit_message"],
            "timestamp": pub_date,
            "builds": [],
        }

    repo_commits[commit_hash]["builds"].append(build_entry)

    if pub_date > repo_commits[commit_hash]["timestamp"]:
        repo_commits[commit_hash]["timestamp"] = pub_date


class SourcehutProvider:
    """Sourcehut CI provider using RSS feed."""

    name = "sourcehut"

    def build_url(self, config):
        """Build the RSS feed URL."""
        username = config.get("identifier", "")
        if not username:
            return ""
        return "https://builds.sr.ht/~" + username + "/rss.xml"

    def get_failed_builds(self, config):
        """Fetch builds from RSS feed. Returns repo-centric data.

        Returns: {
            repos: {
                "hop3": {
                    name: "hop3",
                    status: "failed",  # aggregate
                    commits: [
                        {hash, message, timestamp, status, builds: [{id, status, url}]}
                    ]
                }
            },
            newFailures: [Build objects for notifications],
            failedCount: number
        }
        """
        url = self.build_url(config)
        js.console.log("[Sourcehut] Fetching RSS from:", url)
        if not url:
            js.console.log("[Sourcehut] No URL configured")
            return js.get("Promise").resolve({"repos": {}, "newFailures": []})

        last_checked = config.get("lastChecked", 0)
        username = config.get("identifier", "")
        source_id = config.get("id", "")
        js.console.log("[Sourcehut] Last checked timestamp:", last_checked)

        def handle_response(response):
            js.console.log("[Sourcehut] Response status:", response.status)
            return response.text()

        def parse_rss(text):
            js.console.log("[Sourcehut] Parsing RSS, length:", text.length.to_int())

            repos = {}
            new_failures = []

            # JsProxy.__call__ uses plain call (no `new`); construct DOMParser
            # via eval so we get a real DOMParser instance back. See PORTING.md
            # — the same gap blocks `js.newDate(...)` and any other JS class
            # that requires `new` to construct.
            parser = js.get("eval")("new DOMParser()")
            xml_doc = parser.parseFromString(text, "application/xml")

            items = xml_doc.querySelectorAll("item")
            items_len = items.length.to_int()
            js.console.log("[Sourcehut] Found", items_len, "items in RSS feed")

            # Adaptive iteration. RSS is time-sorted descending. We want to
            # surface every active repo with its most-recent build status,
            # but we can't afford to parse all 4000+ items (each parse_rss_item
            # is ~6 bridge calls — sub-ms each but adds up).
            #
            # Strategy: scan items while tracking unique repo names seen.
            # If we go NO_NEW_REPO_THRESHOLD items without discovering a
            # new repo, we've covered the active set — stop. Hard ceiling
            # at HARD_CAP as a backstop.
            seen_repos = {}
            no_new_streak = 0
            NO_NEW_REPO_THRESHOLD = 200
            HARD_CAP = 2000
            cap_len = items_len
            if cap_len > HARD_CAP:
                cap_len = HARD_CAP
            i = 0

            while i < cap_len:
                item = items.item(i)
                parsed = parse_rss_item(item)

                if parsed["repo_name"] == "unknown":
                    i = i + 1
                    continue

                if parsed["repo_name"] in seen_repos:
                    no_new_streak = no_new_streak + 1
                else:
                    seen_repos[parsed["repo_name"]] = True
                    no_new_streak = 0

                if no_new_streak >= NO_NEW_REPO_THRESHOLD:
                    js.console.log(
                        "[Sourcehut] No new repos for",
                        NO_NEW_REPO_THRESHOLD,
                        "items, stopping at i=", i,
                        "with", len(seen_repos), "repos",
                    )
                    break

                add_build_to_repos(repos, parsed, username, source_id)

                # Track new failures for notifications
                if parsed["build_status"] == "failed":
                    if not last_checked or parsed["pub_date"] > last_checked:
                        notif_title = (
                            parsed["repo_name"]
                            + " ["
                            + parsed["commit_hash"]
                            + "] build failed"
                        )
                        build = create_build(
                            parsed["guid"],
                            notif_title,
                            parsed["link"],
                            "failed",
                            parsed["pub_date"],
                            parsed["author"],
                        )
                        new_failures.append(build)

                i = i + 1

            repos_result = finalize_repos(repos)
            failed_count = count_failed_repos(repos_result)

            js.console.log(
                "[Sourcehut] Repos:",
                len(repos_result),
                "Failed:",
                failed_count,
                "New failures:",
                len(new_failures),
            )

            # JSON round-trip: Python dict → string → JS object via JSON.parse.
            # Direct Python-dict-to-JS marshaling drops to null; JSON.parse
            # rehydrates real JS objects on the bridge's far side. This also
            # ensures the Promise chain's .then() fires (returning a Python
            # dict directly hangs it).
            #
            # new_failures holds Build CLASS INSTANCES — the nano json shim
            # can't serialize those (only dict/list/str/int/bool/None).
            # Flatten each Build to a dict before dumping. Without this,
            # json.dumps raises, the bridge surfaces it as null, and
            # JSON.parse(null) trips "can't convert null to object".
            failures_serializable = [
                {
                    "id": b.id, "title": b.title, "url": b.url,
                    "status": b.status, "timestamp": b.timestamp, "author": b.author,
                }
                for b in new_failures
            ]
            result_dict = {
                "repos": repos_result,
                "newFailures": failures_serializable,
                "failedCount": failed_count,
            }
            return _js_parse(json.dumps(result_dict))

        def handle_error(error):
            js.console.error("[Sourcehut] Error fetching RSS:", error)
            return []

        return js.get("fetch")(proxy_url(url)).then(handle_response).then(parse_rss).catch(handle_error)
