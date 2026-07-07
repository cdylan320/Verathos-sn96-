#!/usr/bin/env python3
"""Preflight checks for miner hot-capacity audit receipt delivery."""

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys
from types import SimpleNamespace

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import httpx

from neurons.capacity_audit import capacity_audit_gpu_support_status
from neurons.capacity_audit_discovery import (
    CapacityAuditEndpointResolver,
    normalize_audit_endpoint,
)


def probe_capacity_audit_ingest_health(endpoint: str, *, timeout_s: float = 5.0) -> str:
    """Return ok | bad | unknown for a validator audit ingest base URL."""
    try:
        resp = httpx.get(
            f"{endpoint.rstrip('/')}/capacity/audit/v1/health",
            timeout=timeout_s,
        )
        if resp.status_code == 200:
            try:
                data = resp.json()
            except Exception:
                data = {}
            if not isinstance(data, dict):
                return "bad"
            service = str(data.get("service") or "").strip().lower()
            if service in {"verathos-capacity-audit-ingest"}:
                return "ok"
            if bool(data.get("capacity_audit")):
                return "ok"
            return "bad"
        if resp.status_code in {401, 403, 404}:
            return "bad"
        return "unknown"
    except Exception:
        return "unknown"


def _quiet_third_party_logs() -> None:
    import logging

    logging.getLogger().setLevel(logging.ERROR)
    for name in ("bittensor", "bt", "httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.ERROR)
    try:
        import bittensor as bt

        setter = getattr(getattr(bt, "logging", None), "set_level", None)
        if callable(setter):
            setter("error")
    except Exception:
        pass


def _detect_gpu() -> tuple[str, int]:
    try:
        name = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip().splitlines()[0].strip()
        vram_mb = int(
            subprocess.check_output(
                ["nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits"],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip().splitlines()[0].strip()
        )
    except (FileNotFoundError, IndexError, ValueError, subprocess.CalledProcessError):
        return "", 0
    vram_gb = max(1, int(round(vram_mb / 1024)))
    return name, vram_gb


def _check_wheel() -> tuple[str, str]:
    try:
        import hot_capacity_workspace_cuda  # noqa: F401
    except Exception as exc:
        return (
            "fail",
            "hot_capacity_workspace_cuda wheel not importable "
            f"({exc}). Run: bash scripts/setup_miner.sh",
        )
    try:
        from hot_capacity_workspace.bench_combined import main  # noqa: F401
    except Exception as exc:
        return (
            "fail",
            "hot_capacity_workspace bench module missing "
            f"({exc}). Reinstall from dist/: bash scripts/setup_miner.sh",
        )
    return "ok", "hot_capacity_workspace_cuda wheel importable"


def _check_gpu() -> tuple[str, str]:
    gpu_name, vram_gb = _detect_gpu()
    if not gpu_name:
        return "fail", "nvidia-smi unavailable or no GPU detected"
    ok, reason, row = capacity_audit_gpu_support_status(gpu_name, vram_gb)
    if ok and row is not None:
        return (
            "ok",
            f"{gpu_name} ({vram_gb} GB) calibrated as {row.match_gpu_name} "
            f"(passes={row.capacity_passes or row.passes}, deadline={row.deadline_s:.0f}s)",
        )
    if reason == "uncalibrated_gpu_class" and row is not None:
        return (
            "fail",
            f"{gpu_name} ({vram_gb} GB) matches uncalibrated row {row.match_gpu_name}",
        )
    return (
        "fail",
        f"{gpu_name} ({vram_gb} GB) has no calibrated hot-capacity audit row ({reason})",
    )


def _manual_validator_urls(raw: str) -> tuple[str, ...]:
    return tuple(
        endpoint
        for endpoint in (normalize_audit_endpoint(part) for part in raw.split(","))
        if endpoint
    )


def _check_validator_endpoints(
    *,
    network: str,
    netuid: int,
    manual_urls: tuple[str, ...],
    probe_timeout_s: float,
) -> tuple[str, str, list[tuple[str, str]]]:
    config = SimpleNamespace(subtensor_network=network, netuid=int(netuid))
    resolver = CapacityAuditEndpointResolver(config, manual_urls=manual_urls)
    urls = resolver.current_urls(force_refresh=True)
    if not urls:
        hint = (
            "No validator audit ingest endpoints discovered. "
            "Ensure subnet validators publish axon ingest URLs, or set "
            "VERATHOS_CAPACITY_AUDIT_VALIDATOR_URLS=http://host:8091"
        )
        return "fail", hint, []

    probes: list[tuple[str, str]] = []
    reachable = 0
    for url in urls:
        status = probe_capacity_audit_ingest_health(url, timeout_s=probe_timeout_s)
        probes.append((url, status))
        if status == "ok":
            reachable += 1

    if reachable <= 0:
        return (
            "fail",
            f"Discovered {len(urls)} validator ingest URL(s) but none reachable "
            f"from this host (outbound firewall?). Probe timeout={probe_timeout_s:.1f}s",
            probes,
        )
    if reachable < len(urls):
        return (
            "warn",
            f"{reachable}/{len(urls)} validator ingest endpoint(s) reachable from this host",
            probes,
        )
    return (
        "ok",
        f"{reachable}/{len(urls)} validator ingest endpoint(s) reachable from this host",
        probes,
    )


def main(argv: list[str] | None = None) -> int:
    _quiet_third_party_logs()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subtensor-network", default=os.environ.get("BT_SUBTENSOR_NETWORK", "finney"))
    parser.add_argument("--netuid", type=int, default=int(os.environ.get("VERATHOS_NETUID", "96")))
    parser.add_argument(
        "--manual-validator-urls",
        default=os.environ.get("VERATHOS_CAPACITY_AUDIT_VALIDATOR_URLS", ""),
        help="Comma-separated override for validator audit ingest base URLs",
    )
    parser.add_argument("--probe-timeout-s", type=float, default=5.0)
    parser.add_argument("--skip-network", action="store_true", help="Skip validator endpoint probes")
    args = parser.parse_args(argv)

    failures = 0
    warnings = 0

    status, message = _check_wheel()
    print(f"{status.upper()}: {message}")
    if status == "fail":
        failures += 1
    elif status == "warn":
        warnings += 1

    status, message = _check_gpu()
    print(f"{status.upper()}: {message}")
    if status == "fail":
        failures += 1
    elif status == "warn":
        warnings += 1

    if args.skip_network:
        print("WARN: Skipped validator ingest endpoint probes (--skip-network)")
        warnings += 1
    else:
        manual_urls = _manual_validator_urls(args.manual_validator_urls)
        status, message, probes = _check_validator_endpoints(
            network=args.subtensor_network,
            netuid=args.netuid,
            manual_urls=manual_urls,
            probe_timeout_s=args.probe_timeout_s,
        )
        print(f"{status.upper()}: {message}")
        for url, probe_status in probes[:8]:
            print(f"  - {url} -> {probe_status}")
        if len(probes) > 8:
            print(f"  - ... and {len(probes) - 8} more")
        if status == "fail":
            failures += 1
        elif status == "warn":
            warnings += 1

    if failures:
        return 1
    if warnings:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
