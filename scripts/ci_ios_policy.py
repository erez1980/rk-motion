#!/usr/bin/env python3
"""Decide whether a feature-branch push should wait before the macOS iOS job.

Pushing a ``codex/**`` branch that already has an open pull request also
triggers ``pull_request``. Both events share one concurrency group, and the
later run cancels the earlier one. Waiting on Ubuntu gives that cancellation
time to arrive before a macOS runner is requested.

The macOS job is still named ``build``. This script does not skip it. A
skipped ``build`` check is reported as success and can satisfy a required
check of that same name. If the sibling pull request never cancels this run,
the macOS build proceeds.

Actions artifact retention is unrelated to the Actions cache (``type=gha``)
and to GitHub Release assets.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

ATTEMPTS = 6
INTERVAL_SECONDS = 4
RETENTION_DAYS = 7


def concurrency_group(head_ref: str, ref_name: str) -> str:
    """Match ``ios-${{ github.head_ref || github.ref_name }}``."""
    return f"ios-{head_ref or ref_name}"


def build_job_runs(prepare_result: str) -> bool:
    """Whether the workflow should start the job named ``build``.

    ``cancelled`` is excluded so a run cancelled during the Ubuntu wait does
    not take the success path. Failure still runs the tests (fail open).
    """
    return prepare_result in {"skipped", "success", "failure"}


def release_job_runs(event: str, ref: str, build_result: str) -> bool:
    """Durable GitHub Release publishing. Unchanged from the workflow condition."""
    return (
        build_result == "success"
        and ref == "refs/heads/main"
        and event != "pull_request"
    )


def upload_xcresult(step_failed: bool, job_cancelled: bool) -> bool:
    """Full bundle only after a failed step or a cancelled job."""
    return step_failed or job_cancelled


def gate_reason(event: str, ref: str, sha: str, fetcher, sleep, attempts=ATTEMPTS, interval=INTERVAL_SECONDS) -> str:
    """Return why this run will continue to the macOS job if it is still alive.

    Only a non-main ``push`` waits. ``pull_request``, ``workflow_dispatch`` and
    ``push`` to ``main`` return immediately.
    """
    if event != "push" or ref == "refs/heads/main":
        return "run-immediately"
    saw_covering_pr = False
    api_error = False
    for attempt in range(attempts):
        try:
            ok, heads = fetcher()
        except Exception:
            ok, heads = False, []
        if not ok:
            api_error = True
        elif sha and sha in heads:
            saw_covering_pr = True
        if attempt + 1 < attempts:
            sleep(interval)
    if saw_covering_pr:
        return "covering-pr-did-not-cancel"
    if api_error:
        return "api-error-fail-open"
    return "no-covering-pr"


def open_pr_heads_command(repo: str, branch: str) -> list[str]:
    return [
        "gh", "pr", "list",
        "--repo", repo,
        "--head", branch,
        "--state", "open",
        "--json", "headRefOid",
    ]


def parse_pr_heads(stdout: str) -> list[str]:
    data = json.loads(stdout or "[]")
    if not isinstance(data, list):
        raise ValueError("expected a list")
    heads = []
    for row in data:
        if not isinstance(row, dict) or not isinstance(row.get("headRefOid"), str):
            raise ValueError("missing headRefOid")
        heads.append(row["headRefOid"])
    return heads


def fetch_open_pr_heads(repo: str, branch: str) -> tuple[bool, list[str]]:
    if not repo or not branch:
        return False, []
    try:
        proc = subprocess.run(
            open_pr_heads_command(repo, branch),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"gh pr list failed: {exc}", file=sys.stderr)
        return False, []
    if proc.returncode != 0:
        detail = (proc.stderr or "").strip()
        print(f"gh pr list exited {proc.returncode}: {detail}", file=sys.stderr)
        return False, []
    try:
        return True, parse_pr_heads(proc.stdout)
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"gh pr list JSON: {exc}", file=sys.stderr)
        return False, []


def main(fetcher=None, sleep=time.sleep, attempts=ATTEMPTS, interval=INTERVAL_SECONDS) -> int:
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    ref = os.environ.get("GITHUB_REF", "")
    sha = os.environ.get("GITHUB_SHA", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    branch = os.environ.get("GITHUB_REF_NAME", "")
    if fetcher is None:
        def fetcher():
            return fetch_open_pr_heads(repo, branch)
    try:
        reason = gate_reason(event, ref, sha, fetcher, sleep, attempts, interval)
    except Exception as exc:
        print(f"ci-ios gate: exception-fail-open: {exc}", file=sys.stderr)
        reason = "exception-fail-open"
    print(f"ci-ios gate: {reason}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"reason={reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
