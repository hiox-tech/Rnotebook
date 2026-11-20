#!/usr/bin/env python3
"""Bound a local verification command and clean up its process group on timeout."""
import os
import signal
import subprocess
import sys

process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    code = process.wait(timeout=float(sys.argv[1]))
except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    print(f"Verification command stopped: {type(error).__name__}", file=sys.stderr)
    code = 124 if isinstance(error, subprocess.TimeoutExpired) else 130
sys.exit(code if code >= 0 else 128 - code)
