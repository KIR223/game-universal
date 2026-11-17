#!/usr/bin/env python3
"""Fails if the repository contains something that looks like a secret or a signing key.

Checks tracked files (git ls-files; falls back to a directory walk): private key blocks, well-known token formats,
`password = "..."`-style assignments, and key/keystore files that must never be committed (release signing keys!).
The Android DEBUG keystore is created on the fly in CI and is never stored; release keys must stay outside the repo.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FORBIDDEN_NAMES = re.compile(r"(\.keystore|\.jks|\.p12|\.pfx|\.pem|\.mobileprovision|\.key)$|(^|/)\.env(\..*)?$|(^|/)id_(rsa|ed25519)$", re.I)
PATTERNS = [
    ("private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("AWS access key id", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("GitHub token", re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b")),
    ("Slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("hard-coded credential", re.compile(r"""(?i)\b(password|passwd|secret|api[_-]?key|token|storepass|keypass)\b\s*[:=]\s*["'][^"'\s]{8,}["']""")),
]
# values that are clearly placeholders / documentation
ALLOW = re.compile(r"(?i)example|placeholder|changeme|your[_-]|<.*>|\$\{|\$[A-Z_]+|android$")
TEXT_EXT = {".gd", ".py", ".md", ".txt", ".yml", ".yaml", ".json", ".cfg", ".godot", ".tscn", ".tres", ".sh", ".ps1", ".gradle", ".xml", ".toml", ".ini", ".gdshader", ".uid", ""}
SKIP_DIRS = ("data/world/", ".godot/", "build/")


def tracked_files():
    try:
        out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.splitlines()
        return [ROOT / p for p in out]
    except Exception:
        return [p for p in ROOT.rglob("*") if p.is_file() and ".git" not in p.parts]


def main() -> int:
    problems = []
    for path in tracked_files():
        rel = path.relative_to(ROOT).as_posix()
        if rel.startswith(SKIP_DIRS) or not path.is_file():
            continue
        if FORBIDDEN_NAMES.search(rel):
            problems.append(f"{rel}: key/credential file must not be committed")
            continue
        if path.suffix.lower() not in TEXT_EXT:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            for name, rx in PATTERNS:
                m = rx.search(line)
                if m and not ALLOW.search(m.group(0)):
                    problems.append(f"{rel}:{lineno}: {name}")
    if problems:
        print("Possible secrets found:\n  " + "\n  ".join(problems))
        return 1
    print("secrets scan OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
