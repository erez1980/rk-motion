#!/usr/bin/env python3
"""Turn an xcodebuild log into a short Markdown summary.

The full ``.xcresult`` bundle stays an Actions artifact only when the job
fails or is cancelled. This summary is what a green run keeps.
"""
from __future__ import annotations

import argparse
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
CASE_START = re.compile(r"Test Case '([^']+)' started")
CASE_END = re.compile(r"Test Case '([^']+)' (passed|failed)")
MARKER = re.compile(r"\*\* TEST (SUCCEEDED|FAILED) \*\*")
RESTART = "Restarting after unexpected exit, crash, or test timeout"
MAX_NAMES = 20


def summarize(log_text: str, exit_code: int | None) -> str:
    text = ANSI.sub("", log_text)
    passed = 0
    failed_names: list[str] = []
    restart_names: list[str] = []
    open_case = None
    marker = None
    for line in text.splitlines():
        start = CASE_START.search(line)
        if start:
            open_case = start.group(1)
        end = CASE_END.search(line)
        if end:
            name, outcome = end.group(1), end.group(2)
            if outcome == "passed":
                passed += 1
            else:
                failed_names.append(name)
            if open_case == name:
                open_case = None
        if RESTART in line:
            if open_case:
                restart_names.append(open_case)
                open_case = None
        found = MARKER.search(line)
        if found:
            marker = found.group(1)
    if exit_code not in (None, 0) or marker == "FAILED":
        result = "failed"
    elif exit_code == 0 or marker == "SUCCEEDED":
        result = "passed"
    else:
        result = "unknown"
    lines = [
        "### Simulator tests",
        f"Result: {result}",
        f"xcodebuild exit code: {exit_code if exit_code is not None else 'unknown'}",
        f"Recorded XCTest cases: {passed} passed, {len(failed_names)} failed",
    ]
    lines.extend(_name_block("Failed tests:", failed_names))
    if restart_names:
        lines.append(f"Crash or timeout restarts: {len(restart_names)}")
        lines.extend(_name_block("In progress at restart:", restart_names))
    elif RESTART in text:
        lines.append("Crash or timeout restarts: present, with no XCTest case still in progress")
    lines.append(
        "Full TestResults.xcresult is uploaded only when this job fails or is cancelled. "
        "Actions artifact retention is 7 days. GitHub Release assets are not Actions artifacts."
    )
    return "\n".join(lines) + "\n"


def _name_block(title: str, names: list[str]) -> list[str]:
    if not names:
        return []
    shown = names[:MAX_NAMES]
    block = [title, *[f"- {name}" for name in shown]]
    extra = len(names) - len(shown)
    if extra:
        block.append(f"- and {extra} more")
    return block


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--exit-code", dest="exit_code", default=None)
    args = parser.parse_args(argv)
    exit_code = None if args.exit_code in (None, "") else int(args.exit_code)
    with open(args.log, encoding="utf-8", errors="replace") as handle:
        summary = summarize(handle.read(), exit_code)
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
