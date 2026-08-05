#!/usr/bin/env python3
"""Fail-closed approval gate for agent-authored pull requests."""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


CHECK_NAME = "agent-approval-check"
COMMENT_MARKER = "<!-- agent-approval-check -->"
API_VERSION = "2022-11-28"
WRITE_PERMISSIONS = {"admin", "maintain", "push", "write"}
APPROVE_RE = re.compile(r"^/approve\s+([a-f0-9]{12,40})\s*$", re.IGNORECASE)
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class APIError(RuntimeError):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class Config:
    required_approvals: int
    agent_emails: frozenset[str]
    agent_logins: frozenset[str]
    excluded_approvers: frozenset[str]
    protected_bases: tuple[str, ...]

    @classmethod
    def from_env(cls) -> "Config":
        try:
            required = int(os.environ.get("REQUIRED_APPROVALS", "2"))
        except ValueError as exc:
            raise ValueError("required_approvals must be an integer") from exc
        if required < 1:
            raise ValueError("required_approvals must be at least 1")
        emails = frozenset(value.lower() for value in csv("AGENT_EMAILS"))
        logins = frozenset(value.lower() for value in csv("AGENT_LOGINS"))
        if not emails and not logins:
            raise ValueError("at least one agent email or login is required")
        return cls(
            required_approvals=required,
            agent_emails=emails,
            agent_logins=logins,
            excluded_approvers=frozenset(
                value.lower() for value in csv("EXCLUDED_APPROVERS")
            ),
            protected_bases=tuple(csv("PROTECTED_BASES")),
        )


def csv(name: str) -> list[str]:
    return [part.strip() for part in os.environ.get(name, "").split(",") if part.strip()]


def user_login(item: dict[str, Any]) -> str:
    user = item.get("user") or {}
    return str(user.get("login") or "")


def is_bot(item: dict[str, Any]) -> bool:
    user = item.get("user") or {}
    return str(user.get("type") or "").lower() == "bot"


def parse_approve(body: str | None) -> str | None:
    lines = (body or "").lstrip().splitlines()
    first = lines[0].strip() if lines else ""
    match = APPROVE_RE.fullmatch(first)
    return match.group(1).lower() if match else None


def sha_matches(prefix: str, sha: str) -> bool:
    return sha.lower().startswith(prefix.lower())


def resolve_pr_number(event_name: str, event: dict[str, Any]) -> int | None:
    if event_name == "pull_request_target":
        return int(event["pull_request"]["number"])
    if event_name == "issue_comment":
        issue = event.get("issue") or {}
        if issue.get("pull_request"):
            return int(issue["number"])
        return None
    raise ValueError(f"unsupported event: {event_name}")


def protected_bases(config: Config, default_branch: str) -> tuple[str, ...]:
    return config.protected_bases or (default_branch,)


def commit_email(commit: dict[str, Any], role: str) -> str:
    identity = ((commit.get("commit") or {}).get(role) or {})
    return str(identity.get("email") or "").lower()


def detect_agent_activity(
    pr: dict[str, Any],
    commits: list[dict[str, Any]],
    commits_incomplete: bool,
    reviews: list[dict[str, Any]],
    config: Config,
) -> tuple[bool, str]:
    if commits_incomplete:
        return True, "Pull request has more than 100 commits"

    for commit in commits:
        for role in ("author", "committer"):
            email = commit_email(commit, role)
            if email and email in config.agent_emails:
                short_sha = str(commit.get("sha") or "")[:12]
                return True, f"Commit {short_sha} has agent {role} email ({email})"

    login = user_login(pr)
    if login.lower() in config.agent_logins:
        return True, f"Pull request was created by {login}"

    for review in reviews:
        login = user_login(review)
        if review.get("state") == "APPROVED" and login.lower() in config.agent_logins:
            return True, f"Pull request has an approving review from {login}"

    return False, "No agent activity"


def latest_reviews(reviews: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    latest: dict[str, dict[str, Any]] = {}
    ordered = sorted(
        reviews,
        key=lambda review: (
            str(review.get("submitted_at") or ""),
            int(review.get("id") or 0),
        ),
    )
    for review in ordered:
        login = user_login(review).lower()
        if login and review.get("state") != "COMMENTED":
            latest[login] = review
    return latest


def approval_candidates(
    head_sha: str,
    reviews: list[dict[str, Any]],
    comments: list[dict[str, Any]],
    config: Config,
) -> tuple[set[str], dict[str, str]]:
    candidates: set[str] = set()
    stale: dict[str, str] = {}

    for login, review in latest_reviews(reviews).items():
        if review.get("state") != "APPROVED" or is_bot(review):
            continue
        if login in config.agent_logins or login in config.excluded_approvers:
            continue
        candidates.add(login)

    for comment in comments:
        login = user_login(comment).lower()
        approved_sha = parse_approve(comment.get("body"))
        if not login or not approved_sha or is_bot(comment):
            continue
        if login in config.agent_logins or login in config.excluded_approvers:
            continue
        if sha_matches(approved_sha, head_sha):
            candidates.add(login)
        else:
            stale[login] = approved_sha

    return candidates, stale


class GitHubAPI:
    def __init__(self, token: str, repository: str):
        if not token:
            raise ValueError("github token is required")
        if not REPO_RE.fullmatch(repository):
            raise ValueError("GITHUB_REPOSITORY is invalid")
        self.token = token
        self.repository = repository
        self.base_url = "https://api.github.com"
        self._permission_cache: dict[str, bool] = {}

    def request(
        self,
        method: str,
        path_or_url: str,
        payload: dict[str, Any] | None = None,
    ) -> tuple[Any, dict[str, str]]:
        if path_or_url.startswith("https://"):
            if not path_or_url.startswith(f"{self.base_url}/"):
                raise APIError("refusing pagination URL outside api.github.com")
            url = path_or_url
        else:
            url = f"{self.base_url}{path_or_url}"

        body = json.dumps(payload).encode() if payload is not None else None
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "User-Agent": "ethereum-optimism-agent-approval-check",
            "X-GitHub-Api-Version": API_VERSION,
        }
        if body is not None:
            headers["Content-Type"] = "application/json"

        for attempt in range(3):
            request = urllib.request.Request(url, data=body, headers=headers, method=method)
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    raw = response.read()
                    data = json.loads(raw) if raw else None
                    return data, {
                        key.lower(): value for key, value in response.headers.items()
                    }
            except urllib.error.HTTPError as exc:
                error_body = exc.read().decode(errors="replace")[:500]
                if exc.code >= 500 and attempt < 2:
                    time.sleep(2**attempt)
                    continue
                raise APIError(
                    f"GitHub API {method} {urllib.parse.urlsplit(url).path} "
                    f"returned {exc.code}: {error_body}",
                    status=exc.code,
                ) from exc
            except urllib.error.URLError as exc:
                if attempt < 2:
                    time.sleep(2**attempt)
                    continue
                raise APIError(f"GitHub API request failed: {exc.reason}") from exc
        raise APIError("GitHub API request failed after retries")

    def get(self, path: str) -> Any:
        data, _ = self.request("GET", path)
        return data

    def paginate(
        self, path: str, maximum: int
    ) -> tuple[list[dict[str, Any]], bool]:
        items: list[dict[str, Any]] = []
        next_url: str | None = path
        while next_url:
            page, headers = self.request("GET", next_url)
            if not isinstance(page, list):
                raise APIError("paginated GitHub response was not a list")
            items.extend(page)
            next_url = next_link(headers.get("link", ""))
            if len(items) >= maximum and next_url:
                return items[:maximum], True
        return items, False

    def has_write_permission(self, login: str) -> bool:
        login_lower = login.lower()
        if login_lower in self._permission_cache:
            return self._permission_cache[login_lower]
        quoted_login = urllib.parse.quote(login, safe="")
        try:
            result = self.get(
                f"/repos/{self.repository}/collaborators/{quoted_login}/permission"
            )
            allowed = str((result or {}).get("permission") or "").lower() in WRITE_PERMISSIONS
        except APIError as exc:
            if exc.status != 404:
                raise
            allowed = False
        self._permission_cache[login_lower] = allowed
        return allowed

    def post_status(self, sha: str, state: str, description: str) -> None:
        suffix = f" [{sha[:12]}]"
        message = description
        if len(message) + len(suffix) > 140:
            message = message[: 139 - len(suffix)] + "…"
        payload: dict[str, Any] = {
            "state": state,
            "context": CHECK_NAME,
            "description": f"{message}{suffix}",
        }
        run_id = os.environ.get("GITHUB_RUN_ID")
        if run_id:
            payload["target_url"] = (
                f"https://github.com/{self.repository}/actions/runs/{run_id}"
            )
        self.request("POST", f"/repos/{self.repository}/statuses/{sha}", payload)

    def upsert_comment(self, comments: list[dict[str, Any]], body: str) -> None:
        existing = next(
            (
                comment
                for comment in comments
                if COMMENT_MARKER in str(comment.get("body") or "")
                and user_login(comment).lower() == "github-actions[bot]"
            ),
            None,
        )
        if existing:
            self.request(
                "PATCH",
                f"/repos/{self.repository}/issues/comments/{int(existing['id'])}",
                {"body": body},
            )
        else:
            pr_number = int(os.environ["AGENT_APPROVAL_PR_NUMBER"])
            self.request(
                "POST",
                f"/repos/{self.repository}/issues/{pr_number}/comments",
                {"body": body},
            )


def next_link(header: str) -> str | None:
    for part in header.split(","):
        match = re.match(r'\s*<([^>]+)>;\s*rel="([^"]+)"', part)
        if match and match.group(2) == "next":
            return match.group(1)
    return None


def status_comment(
    reason: str,
    head_sha: str,
    approvers: set[str],
    stale: dict[str, str],
    required: int,
    siblings: list[int],
    sibling_list_incomplete: bool,
) -> str:
    lines = [
        COMMENT_MARKER,
        "## Agent approval check",
        "",
        reason,
        "",
        f"Current head: `{head_sha}`",
        f"Human approvals: **{len(approvers)}/{required}**",
    ]
    if approvers:
        lines.append("Approvers: " + ", ".join(f"@{login}" for login in sorted(approvers)))
    if stale:
        stale_text = ", ".join(
            f"@{login} (`{sha}`)" for login, sha in sorted(stale.items())
        )
        lines.append(f"Stale SHA-bound approvals: {stale_text}")
    if siblings:
        lines.append(
            "Blocked because another protected-base pull request shares this head: "
            + ", ".join(f"#{number}" for number in siblings)
        )
    elif sibling_list_incomplete:
        lines.append("Blocked because pull requests sharing this head could not be fully listed.")
    if len(approvers) < required:
        lines.extend(
            [
                "",
                "A write-capable human can approve by submitting a native review or by commenting:",
                "",
                f"`/approve {head_sha}`",
            ]
        )
    return "\n".join(lines)


def process(client: GitHubAPI, config: Config, pr_number: int) -> None:
    repo = client.get(f"/repos/{client.repository}")
    default_branch = str(repo.get("default_branch") or "")
    if not default_branch:
        raise APIError("repository default branch is unavailable")
    bases = protected_bases(config, default_branch)

    pr = client.get(f"/repos/{client.repository}/pulls/{pr_number}")
    base = str(((pr.get("base") or {}).get("ref")) or "")
    if base not in bases:
        print(f"PR #{pr_number} targets unprotected base {base!r}; no status posted")
        return
    head_sha = str(((pr.get("head") or {}).get("sha")) or "")
    if not re.fullmatch(r"[a-f0-9]{40}", head_sha, re.IGNORECASE):
        raise APIError("pull-request head SHA is invalid")

    client.post_status(head_sha, "pending", "Evaluation in progress")

    commits, commits_incomplete = client.paginate(
        f"/repos/{client.repository}/pulls/{pr_number}/commits?per_page=100", 100
    )
    reviews, reviews_incomplete = client.paginate(
        f"/repos/{client.repository}/pulls/{pr_number}/reviews?per_page=100", 1000
    )
    comments, comments_incomplete = client.paginate(
        f"/repos/{client.repository}/issues/{pr_number}/comments?per_page=100", 1000
    )
    if reviews_incomplete or comments_incomplete:
        raise APIError("review or comment history exceeds the safe pagination limit")

    associated, sibling_list_incomplete = client.paginate(
        f"/repos/{client.repository}/commits/{head_sha}/pulls?per_page=100", 100
    )
    siblings = sorted(
        int(other["number"])
        for other in associated
        if int(other.get("number") or 0) != pr_number
        and other.get("state") == "open"
        and str(((other.get("head") or {}).get("sha")) or "") == head_sha
        and str(((other.get("base") or {}).get("ref")) or "") in bases
    )

    agent_activity, reason = detect_agent_activity(
        pr, commits, commits_incomplete, reviews, config
    )
    if not agent_activity:
        if siblings or sibling_list_incomplete:
            body = status_comment(
                reason,
                head_sha,
                set(),
                {},
                config.required_approvals,
                siblings,
                sibling_list_incomplete,
            )
            client.upsert_comment(comments, body)
            client.post_status(head_sha, "pending", "Another protected PR shares this head")
            return
        client.post_status(head_sha, "success", "No agent activity")
        return

    candidates, stale = approval_candidates(head_sha, reviews, comments, config)
    approvers = {login for login in candidates if client.has_write_permission(login)}

    body = status_comment(
        reason,
        head_sha,
        approvers,
        stale,
        config.required_approvals,
        siblings,
        sibling_list_incomplete,
    )
    client.upsert_comment(comments, body)

    current_pr = client.get(f"/repos/{client.repository}/pulls/{pr_number}")
    current_head = str(((current_pr.get("head") or {}).get("sha")) or "")
    if current_head != head_sha:
        raise APIError("pull-request head changed during evaluation")

    if siblings or sibling_list_incomplete:
        client.post_status(head_sha, "pending", "Another protected PR shares this head")
    elif len(approvers) >= config.required_approvals:
        client.post_status(
            head_sha,
            "success",
            f"{len(approvers)}/{config.required_approvals} human approvals",
        )
    else:
        client.post_status(
            head_sha,
            "pending",
            f"Need {config.required_approvals} approvals (have {len(approvers)})",
        )


def main() -> int:
    try:
        config = Config.from_env()
        repository = os.environ.get("GITHUB_REPOSITORY", "")
        event_name = os.environ.get("GITHUB_EVENT_NAME", "")
        event_path = os.environ.get("GITHUB_EVENT_PATH", "")
        if not event_path:
            raise ValueError("GITHUB_EVENT_PATH is required")
        event = json.loads(Path(event_path).read_text())
        pr_number = resolve_pr_number(event_name, event)
        if pr_number is None:
            print("Event is not associated with a pull request")
            return 0
        os.environ["AGENT_APPROVAL_PR_NUMBER"] = str(pr_number)
        client = GitHubAPI(os.environ.get("GH_TOKEN", ""), repository)
        process(client, config, pr_number)
        return 0
    except Exception as exc:
        print(f"agent-approval-check failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
