#!/usr/bin/env python3
"""Real-network multiplayer test: a host process and a client process talk over ENet (UDP, localhost) for N game days.
Both must end on the same day with the same state checksum and report no desync.

    python3 tests/net_enet_test.py [--godot PATH] [--days 40]

Godot is taken from --godot, $GODOT, or `godot` on PATH. Exit code 0 = passed.
"""
import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def free_udp_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def start(godot: str, args: list[str]) -> subprocess.Popen:
    return subprocess.Popen([godot, "--headless", "--path", ROOT, "-s", "tools/net_selftest.gd", "--"] + args,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default=os.environ.get("GODOT") or shutil.which("godot") or "godot")
    ap.add_argument("--days", type=int, default=40)
    args = ap.parse_args()
    port = free_udp_port()
    host = start(args.godot, ["host", str(port), str(args.days)])
    deadline = time.time() + 60
    host_lines: list[str] = []
    while time.time() < deadline:                      # wait until the host listens
        line = host.stdout.readline()
        if not line:
            break
        host_lines.append(line.rstrip())
        if "HOST_READY" in line or "HOST_FAILED" in line:
            break
    if not any("HOST_READY" in l for l in host_lines):
        host.kill()
        print("host did not start:\n" + "\n".join(host_lines[-15:]))
        return 1
    client = start(args.godot, ["client", str(port), str(args.days), "NetTester"])
    try:
        c_out = client.communicate(timeout=120)[0]
        h_out = host.communicate(timeout=60)[0]
    except subprocess.TimeoutExpired:
        host.kill()
        client.kill()
        print("TIMEOUT")
        return 1
    host_text = "\n".join(host_lines) + "\n" + h_out
    print("--- host ---\n" + "\n".join(l for l in host_text.splitlines() if l.startswith("HOST_")))
    print("--- client ---\n" + "\n".join(l for l in c_out.splitlines() if l.startswith("CLIENT_")))
    h = re.search(r"HOST_DONE day=(\d+) sum=(-?\d+) desyncs=(\d+) commands=(\d+) rejected=(\d+) players=(\d+)", host_text)
    c = re.search(r"CLIENT_DONE day=(\d+) sum=(-?\d+) desyncs=(\d+) snapshots=(\d+) events=(\d+)", c_out)
    problems = []
    if not h:
        problems.append("host did not finish")
    if not c:
        problems.append("client did not finish")
    if h and c:
        if h.group(1) != c.group(1):
            problems.append(f"different day: host {h.group(1)} client {c.group(1)}")
        if h.group(2) != c.group(2):
            problems.append(f"STATE DIFFERS: host sum {h.group(2)} client sum {c.group(2)}")
        if int(h.group(3)) != 0 or int(c.group(3)) != 0:
            problems.append(f"desyncs: host-reported {h.group(3)}, client-reported {c.group(3)}")
        if int(h.group(4)) < 2 or int(h.group(5)) != 0:
            problems.append(f"expected the host's and the client's command to be accepted (accepted {h.group(4)}, rejected {h.group(5)})")
        if int(c.group(5)) < 2:
            problems.append(f"the client saw too few events ({c.group(5)}): its own command should come back from the host")
    if problems:
        print("FAILED:\n  " + "\n  ".join(problems))
        return 1
    print(f"OK: host and client are identical after {args.days} days over real UDP (checksum {h.group(2)}, {h.group(4)} commands, 0 desyncs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
