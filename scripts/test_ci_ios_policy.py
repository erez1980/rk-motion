#!/usr/bin/env python3
"""Lightweight checks for iOS workflow retention, events, and summaries."""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_ios_policy  # noqa: E402
import ci_ios_test_summary  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/ios.yml"
PATHS = [
    "ios/**",
    "scripts/build-ios.sh",
    "scripts/generate-ios-project.py",
    "scripts/check-ios-store.py",
    "scripts/make-altstore-source.py",
    "scripts/ci_ios_policy.py",
    "scripts/ci_ios_test_summary.py",
    ".github/workflows/ios.yml",
]
FAILURES: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"ok {name}")
        return
    FAILURES.append(f"{name}: {detail}")
    print(f"FAIL {name}: {detail}")


def load_workflow() -> dict:
    text = WORKFLOW.read_text()
    data = yaml.safe_load(text)
    # PyYAML 1.1 treats the key "on" as boolean true.
    if True in data and "on" not in data:
        data["on"] = data.pop(True)
    return data


def test_gate_events() -> None:
    calls = {"fetch": 0, "sleep": []}

    def fetcher():
        calls["fetch"] += 1
        return True, []

    def sleep(seconds):
        calls["sleep"].append(seconds)

    for event, ref in (
        ("pull_request", "refs/pull/21/merge"),
        ("pull_request", "refs/heads/main"),
        ("workflow_dispatch", "refs/heads/main"),
        ("workflow_dispatch", "refs/heads/codex/automatic-studio"),
        ("push", "refs/heads/main"),
        ("schedule", "refs/heads/main"),
    ):
        calls["fetch"] = 0
        calls["sleep"].clear()
        reason = ci_ios_policy.gate_reason(event, ref, "abc", fetcher, sleep, attempts=6, interval=4)
        check(f"immediate {event} {ref}", reason == "run-immediately" and calls["fetch"] == 0 and calls["sleep"] == [], reason)

    reason = ci_ios_policy.gate_reason(
        "push", "refs/heads/codex/automatic-studio", "abc", fetcher, sleep, attempts=6, interval=4,
    )
    check("branch without PR waits then builds", reason == "no-covering-pr", reason)
    check("branch without PR polls every attempt", calls["fetch"] == 6, str(calls["fetch"]))
    check("branch without PR sleeps between polls", calls["sleep"] == [4, 4, 4, 4, 4], str(calls["sleep"]))

    def covering():
        calls["fetch"] += 1
        heads = ["abc"] if calls["fetch"] >= 2 else ["older"]
        return True, heads

    calls["fetch"] = 0
    calls["sleep"].clear()
    reason = ci_ios_policy.gate_reason(
        "push", "refs/heads/codex/foo", "abc", covering, sleep, attempts=4, interval=4,
    )
    check("covering PR does not return early", reason == "covering-pr-did-not-cancel", reason)
    check("covering PR still uses the full wait", calls["sleep"] == [4, 4, 4], str(calls["sleep"]))

    def broken():
        return False, []

    calls["sleep"].clear()
    reason = ci_ios_policy.gate_reason(
        "push", "refs/heads/codex/foo", "abc", broken, sleep, attempts=3, interval=5,
    )
    check("API error fails open after the wait", reason == "api-error-fail-open", reason)
    check("API error does not skip the wait", calls["sleep"] == [5, 5], str(calls["sleep"]))

    def explodes():
        raise RuntimeError("network")

    reason = ci_ios_policy.gate_reason("push", "refs/heads/codex/foo", "abc", explodes, sleep, attempts=2, interval=1)
    check("fetcher exception fails open", reason == "api-error-fail-open", reason)

    reason = ci_ios_policy.gate_reason(
        "push", "refs/heads/main-experiment", "abc", fetcher, sleep, attempts=1, interval=4,
    )
    check("branch named like main still polls", reason == "no-covering-pr", reason)
    reason = ci_ios_policy.gate_reason(
        "push", "refs/heads/codex/main-fix", "sha", lambda: (True, ["other"]), sleep, attempts=1, interval=4,
    )
    check("different head SHA is not covered", reason == "no-covering-pr", reason)
    reason = ci_ios_policy.gate_reason(
        "push", "refs/heads/codex/foo", "", lambda: (True, [""]), sleep, attempts=1, interval=4,
    )
    check("empty SHA does not match", reason == "no-covering-pr", reason)


def test_main_does_not_skip_build() -> None:
    path = tempfile.NamedTemporaryFile(delete=False)
    path.close()
    previous = {key: os.environ.get(key) for key in ("GITHUB_EVENT_NAME", "GITHUB_REF", "GITHUB_SHA", "GITHUB_REPOSITORY", "GITHUB_REF_NAME", "GITHUB_OUTPUT")}
    os.environ["GITHUB_EVENT_NAME"] = "push"
    os.environ["GITHUB_REF"] = "refs/heads/codex/automatic-studio"
    os.environ["GITHUB_SHA"] = "abc"
    os.environ["GITHUB_REPOSITORY"] = "erez1980/rk-motion"
    os.environ["GITHUB_REF_NAME"] = "codex/automatic-studio"
    os.environ["GITHUB_OUTPUT"] = path.name
    try:
        code = ci_ios_policy.main(fetcher=lambda: (True, ["abc"]), sleep=lambda _seconds: None, attempts=2, interval=1)
        written = Path(path.name).read_text()
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        os.unlink(path.name)
    check("gate exits 0 when a PR already covers the SHA", code == 0, str(code))
    check("gate records the fail-open reason", written == "reason=covering-pr-did-not-cancel\n", written)


def test_commands_and_release_rules() -> None:
    command = ci_ios_policy.open_pr_heads_command("erez1980/rk-motion", "codex/a;rm")
    check("gh argv has no shell", command == [
        "gh", "pr", "list", "--repo", "erez1980/rk-motion", "--head", "codex/a;rm",
        "--state", "open", "--json", "headRefOid",
    ], str(command))
    check("parse heads", ci_ios_policy.parse_pr_heads('[{"headRefOid":"abc"}]') == ["abc"])
    try:
        ci_ios_policy.parse_pr_heads('{"headRefOid":"abc"}')
        check("parse object rejected", False, "no error")
    except ValueError:
        check("parse object rejected", True)
    check("retention constant", ci_ios_policy.RETENTION_DAYS == 7)
    check("build runs after skipped gate", ci_ios_policy.build_job_runs("skipped"))
    check("build runs after gate success", ci_ios_policy.build_job_runs("success"))
    check("build runs after gate failure", ci_ios_policy.build_job_runs("failure"))
    check("cancelled gate does not take the build success path", not ci_ios_policy.build_job_runs("cancelled"))
    cases = (
        ("push", "refs/heads/main", "success", True),
        ("workflow_dispatch", "refs/heads/main", "success", True),
        ("pull_request", "refs/heads/main", "success", False),
        ("pull_request", "refs/pull/21/merge", "success", False),
        ("push", "refs/heads/codex/foo", "success", False),
        ("push", "refs/heads/main", "failure", False),
        ("push", "refs/heads/main", "cancelled", False),
        ("push", "refs/heads/main", "skipped", False),
    )
    for event, ref, result, expected in cases:
        got = ci_ios_policy.release_job_runs(event, ref, result)
        check(f"release {event} {ref} {result}", got is expected, str(got))
    check("xcresult on failure", ci_ios_policy.upload_xcresult(True, False))
    check("xcresult on cancel", ci_ios_policy.upload_xcresult(False, True))
    check("no xcresult on success", not ci_ios_policy.upload_xcresult(False, False))
    check(
        "concurrency group matches push and pull_request",
        ci_ios_policy.concurrency_group("", "codex/automatic-studio")
        == ci_ios_policy.concurrency_group("codex/automatic-studio", "ignored")
        == "ios-codex/automatic-studio",
    )
    check("main concurrency group", ci_ios_policy.concurrency_group("", "main") == "ios-main")


def test_summary() -> None:
    success = """\x1b[32mTest Case '-[RKMotionTests.Foo testA]' started.\x1b[0m
Test Case '-[RKMotionTests.Foo testA]' passed (0.001 seconds).
\tExecuted 96 tests, with 0 failures (0 unexpected) in 1.000 (1.000) seconds
\tExecuted 96 tests, with 0 failures (0 unexpected) in 1.000 (1.000) seconds
** TEST SUCCEEDED **
"""
    text = ci_ios_test_summary.summarize(success, 0)
    check("summary passed", "Result: passed" in text and "1 passed, 0 failed" in text, text)
    check("summary ignores duplicate suite totals", "96" not in text, text)
    check("summary states artifact policy", "7 days" in text and "fails or is cancelled" in text, text)
    failed = """Test Case '-[RKMotionTests.Foo testBad]' started.
Test Case '-[RKMotionTests.Foo testBad]' failed (0.010 seconds).
** TEST FAILED **
"""
    text = ci_ios_test_summary.summarize(failed, 65)
    check("summary failed case", "Result: failed" in text and "-[RKMotionTests.Foo testBad]" in text, text)
    crash = """Test Case '-[RKMotionTests.EffectsExportTests testEveryEffectExports]' started.
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
** TEST FAILED **
"""
    text = ci_ios_test_summary.summarize(crash, 65)
    check("summary names the crashed test", "testEveryEffectExports" in text and "Crash or timeout restarts: 1" in text, text)
    many = "\n".join(
        f"Test Case '-[RKMotionTests.Foo test{i}]' failed (0.001 seconds)." for i in range(25)
    ) + "\n** TEST FAILED **\n"
    text = ci_ios_test_summary.summarize(many, 65)
    check("summary caps names", "- and 5 more" in text and "test24" not in text, text)
    check("nonzero exit fails a succeeded marker", "Result: failed" in ci_ios_test_summary.summarize("** TEST SUCCEEDED **\n", 65))
    with tempfile.TemporaryDirectory() as directory:
        log = Path(directory) / "log.txt"
        out = Path(directory) / "summary.md"
        log.write_text("** TEST SUCCEEDED **\n", encoding="utf-8")
        code = ci_ios_test_summary.main(["--log", str(log), "--output", str(out), "--exit-code", "0"])
        check("summary cli", code == 0 and "Result: passed" in out.read_text(), out.read_text() if out.exists() else "")


def test_workflow() -> None:
    data = load_workflow()
    triggers = data["on"]
    check("push branches", triggers["push"]["branches"] == ["main", "codex/**"], str(triggers["push"]["branches"]))
    check("push paths", triggers["push"]["paths"] == PATHS, str(triggers["push"]["paths"]))
    check("pull_request paths", triggers["pull_request"]["paths"] == PATHS, str(triggers["pull_request"]["paths"]))
    check("pull_request has no branch filter", "branches" not in triggers["pull_request"])
    check("workflow_dispatch preserved", "workflow_dispatch" in triggers)
    check("concurrency group", data["concurrency"]["group"] == "ios-${{ github.head_ref || github.ref_name }}")
    check("concurrency cancels in progress", data["concurrency"]["cancel-in-progress"] is True)
    check("workflow permission stays contents read", data["permissions"] == {"contents": "read"})
    jobs = data["jobs"]
    check("job ids", set(jobs) == {"prepare", "build", "release"}, str(set(jobs)))
    for job_id in ("build", "release"):
        check(f"{job_id} has no display-name override", "name" not in jobs[job_id])
    prepare = jobs["prepare"]
    check("prepare is ubuntu", prepare["runs-on"] == "ubuntu-latest", str(prepare["runs-on"]))
    check("prepare only on non-main push", prepare["if"] == "github.event_name == 'push' && github.ref != 'refs/heads/main'")
    check("prepare permissions", prepare["permissions"] == {"contents": "read", "pull-requests": "read"})
    check("prepare does not request actions write", "actions" not in prepare["permissions"])
    prepare_run = " ".join(step.get("run", "") for step in prepare["steps"])
    check("prepare uses the policy script", "python3 scripts/ci_ios_policy.py" in prepare_run, prepare_run)
    build = jobs["build"]
    check("build runner unchanged", build["runs-on"] == "macos-15")
    check("build needs prepare", build["needs"] in ("prepare", ["prepare"]))
    check(
        "build if matches fail-open results",
        build["if"] == "${{ needs.prepare.result == 'skipped' || needs.prepare.result == 'success' || needs.prepare.result == 'failure' }}",
        str(build.get("if")),
    )
    check("build timeout preserved", build["timeout-minutes"] == 45)
    runs = [step.get("run", "") for step in build["steps"]]
    check("simulator test command preserved", any("CODE_SIGNING_ALLOWED=NO test" in run and "TestResults.xcresult" in run for run in runs))
    check("summary command present", any("ci_ios_test_summary.py" in run for run in runs))
    check("unsigned IPA build preserved", any("build-ios.sh unsigned" in run for run in runs))
    uploads = [step for step in build["steps"] if step.get("uses") == "actions/upload-artifact@v4"]
    check("three artifact uploads", len(uploads) == 3, str(uploads))
    for upload in uploads:
        check(
            f"retention 7 for {upload['with'].get('name')}",
            upload["with"].get("retention-days") == ci_ios_policy.RETENTION_DAYS,
            str(upload["with"]),
        )
    by_name = {upload["with"]["name"]: upload for upload in uploads}
    ipa = by_name["RK-Motion-unsigned-IPA"]
    check("IPA path preserved", ipa["with"]["path"] == "build/ios/RK-Motion-*.ipa")
    check("IPA missing file still fails", ipa["with"]["if-no-files-found"] == "error")
    check("IPA upload is not limited to main", "if" not in ipa)
    summary = by_name["RK-Motion-test-summary"]
    check("summary always uploaded", summary["if"] == "always()")
    check("summary missing file ignored", summary["with"]["if-no-files-found"] == "ignore")
    xcresult = by_name["RK-Motion-test-results"]
    check("xcresult only on failure or cancellation", xcresult["if"] == "failure() || cancelled()")
    check("xcresult path preserved", xcresult["with"]["path"] == "build/ios/TestResults.xcresult")
    check("xcresult missing file ignored", xcresult["with"]["if-no-files-found"] == "ignore")
    release = jobs["release"]
    check("release needs build", release["needs"] in ("build", ["build"]))
    check("release if preserved", release["if"] == "github.ref == 'refs/heads/main' && github.event_name != 'pull_request'")
    check("release runner unchanged", release["runs-on"] == "ubuntu-latest")
    check("release permission preserved", release["permissions"] == {"contents": "write"})
    check("release concurrency preserved", release["concurrency"] == {"group": "ios-release", "cancel-in-progress": False})
    release_run = "\n".join(step.get("run", "") for step in release["steps"])
    for snippet in (
        "gh release create",
        "gh release upload",
        "dist/source.json",
        "make-altstore-source.py",
        "gh release edit",
        "--latest",
    ):
        check(f"release still {snippet}", snippet in release_run)
    download = [step for step in release["steps"] if step.get("uses") == "actions/download-artifact@v4"]
    check("release still downloads the IPA artifact", len(download) == 1 and download[0]["with"]["name"] == "RK-Motion-unsigned-IPA")
    blob = WORKFLOW.read_text()
    check("no actions cache", "actions/cache" not in blob and "\n  cache:" not in blob)
    check("no self-hosted runner", "self-hosted" not in blob)
    check("toolchain pin preserved", "Xcode_26.3.app" in blob)
    check("serialized workflow", json.dumps(data["jobs"]["build"]["runs-on"]) == '"macos-15"')


def main() -> int:
    test_gate_events()
    test_main_does_not_skip_build()
    test_commands_and_release_rules()
    test_summary()
    test_workflow()
    if FAILURES:
        print(f"\n{len(FAILURES)} failed")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
