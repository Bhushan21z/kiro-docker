#!/usr/bin/env python3
"""Redact credential material from a text stream (stdin -> stdout).

The agent can read its own environment, so a prompt-injected run can put
KIRO_API_KEY into its transcript through an ordinary file-read tool result.
The transcript is kept for audit, so it is redacted rather than dropped; the
count goes to stderr so evaluate.sh can record that it happened — a non-zero
count is itself a sign the candidate tried to steer the evaluator.
"""
import os
import re
import sys

PATTERNS = [
    re.compile(r"ksk_[A-Za-z0-9_-]{8,}"),
    re.compile(r"https?://[^\s\"'<>]*X-Amz-[^\s\"'<>]*", re.I),
    re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
]


def redact(text, api_key):
    count = 0
    if api_key and len(api_key) >= 8 and api_key in text:
        count += text.count(api_key)
        text = text.replace(api_key, "[REDACTED]")
    for rx in PATTERNS:
        text, n = rx.subn("[REDACTED]", text)
        count += n
    return text, count


def main():
    data = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    out, count = redact(data, os.environ.get("KIRO_API_KEY", ""))
    sys.stdout.write(out)
    print(count, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
