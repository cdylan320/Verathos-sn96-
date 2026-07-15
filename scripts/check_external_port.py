#!/usr/bin/env python3
"""Check if TCP ports are reachable from the public internet.

Uses the same checkers as the Verathos miner (yougetsignal + portchecker.io).

Usage:
  ./scripts/check_external_port.py
  ./scripts/check_external_port.py 8889
  ./scripts/check_external_port.py n1.us.clorecloud.net 8889
  ./scripts/check_external_port.py n1.us.clorecloud.net 8888 8889 22
  ./scripts/check_external_port.py n1.us.clorecloud.net 40000-40010
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

try:
    import httpx
except ImportError:
    print("Need httpx: pip install httpx", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
CONF = ROOT / "miner.conf"
UA = {"User-Agent": "Mozilla/5.0"}


def load_defaults() -> tuple[str, int]:
    host, port = "", 8889
    if not CONF.exists():
        return host, port
    text = CONF.read_text()
    m = re.search(r'^ENDPOINT\s*=\s*"([^"]+)"', text, re.M)
    if m:
        parsed = urlparse(m.group(1))
        host = parsed.hostname or ""
        if parsed.port:
            port = parsed.port
    m = re.search(r'^HTTPS_PORT\s*=\s*(\d+)', text, re.M)
    if m:
        port = int(m.group(1))
    return host, port


def expand_ports(args: list[str]) -> list[int]:
    out: list[int] = []
    for arg in args:
        if re.fullmatch(r"\d+-\d+", arg):
            a, b = map(int, arg.split("-"))
            if a > b:
                a, b = b, a
            if b - a > 50:
                raise SystemExit(f"Refusing range >50 ports: {arg}")
            out.extend(range(a, b + 1))
        elif arg.isdigit():
            out.append(int(arg))
        else:
            raise SystemExit(f"Bad port/range: {arg}")
    return out


def check_yougetsignal(client: httpx.Client, host: str, port: int) -> str:
    try:
        r = client.post(
            "https://ports.yougetsignal.com/check-port.php",
            data={"remoteAddress": host, "portNumber": str(port)},
            headers=UA,
        )
        if r.status_code != 200:
            return "?"
        body = r.text.lower()
        if "is open" in body:
            return "OPEN"
        if "is closed" in body:
            return "CLOSED"
        return "?"
    except Exception:
        return "?"


def check_portchecker(client: httpx.Client, host: str, port: int) -> str:
    try:
        r = client.get(
            f"https://portchecker.io/api/v1/query?host={host}&ports={port}",
            headers=UA,
        )
        if r.status_code != 200:
            return "?"
        ports = r.json().get("ports", [])
        for p in ports:
            if int(p.get("port", -1)) == port:
                return "OPEN" if p.get("status") == "open" else "CLOSED"
        return "?"
    except Exception:
        return "?"


def local_listeners() -> None:
    try:
        out = subprocess.check_output(["ss", "-tln"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return
    print("Local listeners:")
    for line in out.splitlines():
        if "Local Address" in line or "0.0.0.0:" in line or "[::]:" in line:
            print(f"  {line}")
    print()


def main() -> int:
    default_host, default_port = load_defaults()
    argv = sys.argv[1:]

    if not argv:
        host, ports = default_host, [default_port]
    elif len(argv) == 1 and (argv[0].isdigit() or re.fullmatch(r"\d+-\d+", argv[0])):
        host, ports = default_host, expand_ports(argv)
    else:
        host = argv[0]
        ports = expand_ports(argv[1:] or [str(default_port)])

    if not host:
        print(f"Usage: {sys.argv[0]} [host] <port> [port2 ...] [start-end]")
        print("Could not detect host from miner.conf ENDPOINT.")
        return 1

    print(f"Host: {host}")
    local_listeners()
    print(f"{'PORT':<8} {'yougetsignal':<14} {'portchecker':<14} {'RESULT':<8}")
    print(f"{'----':<8} {'------------':<14} {'-----------':<14} {'------':<8}")

    any_open = False
    with httpx.Client(timeout=12.0, follow_redirects=True) as client:
        for port in ports:
            ygs = check_yougetsignal(client, host, port)
            pci = check_portchecker(client, host, port)
            if ygs == "OPEN" or pci == "OPEN":
                result = "OPEN"
                any_open = True
            elif ygs == "?" and pci == "?":
                result = "UNKNOWN"
            else:
                result = "CLOSED"
            print(f"{port:<8} {ygs:<14} {pci:<14} {result:<8}")

    print()
    if any_open:
        print("At least one port reports OPEN from the internet.")
        return 0
    print(
        "No checked ports report OPEN. Open/map the port in Clore, "
        "then set miner.conf ENDPOINT/HTTPS_PORT to that public port."
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
