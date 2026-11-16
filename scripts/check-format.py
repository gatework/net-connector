#!/usr/bin/env python3
"""Check project Go files, respecting Git's ignored reference workspaces."""
import os
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[1]
    tracked = subprocess.check_output([
        "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.go"
    ], cwd=root)
    files = sorted({root / os.fsdecode(name) for name in tracked.split(b"\0") if name})
    files = [str(path) for path in files if path.is_file()]
    if not files:
        return 0
    result = subprocess.run([
        "go", "run", "golang.org/x/tools/cmd/goimports@v0.52.0", "-l", *files
    ], cwd=root, stdout=subprocess.PIPE, text=True, check=True)
    if result.stdout:
        print("Go files require import/format normalization:")
        print(result.stdout, end="")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
