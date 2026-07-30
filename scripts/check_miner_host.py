#!/usr/bin/env python3
"""Detailed, dependency-free preflight for a prospective Verathos miner host.

This script is intentionally usable before ``./miner setup``.  It checks the
host hardware, matches the GPU against the repository's capacity-audit
calibration table, and repeatedly measures control-plane/validator latency.

It cannot run the real CUDA audit workload before that wheel is installed.
After setup, also run ``./miner check-audit`` for the runtime check.
"""

from __future__ import annotations

import argparse
import ast
import concurrent.futures
import datetime as dt
import json
import math
import os
import pathlib
import shutil
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Iterable


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
GPU_TABLE_PATH = REPO_ROOT / "neurons" / "capacity_audit.py"
DEFAULT_API_URL = "https://api.verathos.ai/v1/subnet-config"
DEFAULT_ENDPOINT_CACHE = pathlib.Path.home() / ".verathos" / "capacity_audit_validator_endpoints.json"


@dataclass(frozen=True)
class CheckResult:
    name: str
    status: str  # PASS | WARN | FAIL | INFO
    summary: str
    details: tuple[str, ...] = ()


@dataclass(frozen=True)
class GpuCalibration:
    name: str
    vram_gb: int
    passes: int
    deadline_s: float
    calibrated: bool


class Reporter:
    def __init__(self, log_path: pathlib.Path):
        self.log_path = log_path
        self.lines: list[str] = []

    def emit(self, line: str = "") -> None:
        print(line)
        self.lines.append(line)

    def result(self, item: CheckResult) -> None:
        self.emit(f"[{item.status:4}] {item.name}: {item.summary}")
        for detail in item.details:
            self.emit(f"       {detail}")

    def save(self) -> None:
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_path.write_text("\n".join(self.lines) + "\n")


def _run(command: list[str], timeout_s: float = 15.0) -> str:
    return subprocess.check_output(
        command,
        text=True,
        stderr=subprocess.STDOUT,
        timeout=timeout_s,
    ).strip()


def _percentile(values: list[float], quantile: float) -> float:
    if not values:
        return math.inf
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(quantile * len(ordered)) - 1))
    return ordered[index]


def _literal(node: ast.AST, default=None):
    try:
        return ast.literal_eval(node)
    except Exception:
        return default


def _load_gpu_calibrations() -> tuple[GpuCalibration, ...]:
    """Read literal CapacityGpuClass rows without importing project deps."""
    tree = ast.parse(GPU_TABLE_PATH.read_text(), filename=str(GPU_TABLE_PATH))
    rows: list[GpuCalibration] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func_name = getattr(node.func, "id", "") or getattr(node.func, "attr", "")
        if func_name != "CapacityGpuClass" or len(node.args) < 2:
            continue
        name = _literal(node.args[0])
        vram_gb = _literal(node.args[1])
        if not isinstance(name, str) or not isinstance(vram_gb, int):
            continue
        keywords = {kw.arg: _literal(kw.value) for kw in node.keywords if kw.arg}
        passes = int(keywords.get("capacity_passes") or keywords.get("passes") or 0)
        rows.append(
            GpuCalibration(
                name=name,
                vram_gb=vram_gb,
                passes=passes,
                deadline_s=float(keywords.get("deadline_s") or 30.0),
                calibrated=bool(keywords.get("calibrated", False)),
            )
        )
    return tuple(rows)


def _normalize_gpu_name(value: str) -> str:
    return " ".join(value.lower().replace("nvidia corporation", "nvidia").split())


def _detect_gpus() -> list[dict[str, str]]:
    fields = "index,name,memory.total,memory.used,temperature.gpu,driver_version"
    raw = _run(
        ["nvidia-smi", f"--query-gpu={fields}", "--format=csv,noheader,nounits"],
        timeout_s=10.0,
    )
    out: list[dict[str, str]] = []
    for line in raw.splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) != 6:
            continue
        out.append(dict(zip(fields.split(","), parts)))
    return out


def check_gpu() -> CheckResult:
    try:
        gpus = _detect_gpus()
    except (FileNotFoundError, subprocess.SubprocessError) as exc:
        return CheckResult("GPU", "FAIL", f"nvidia-smi failed: {exc}")
    if not gpus:
        return CheckResult("GPU", "FAIL", "No NVIDIA GPU detected")

    rows = _load_gpu_calibrations()
    details: list[str] = []
    statuses: list[str] = []
    for gpu in gpus:
        name = gpu["name"]
        vram_gb = max(1, round(int(gpu["memory.total"]) / 1024))
        matched = next(
            (
                row
                for row in rows
                if _normalize_gpu_name(row.name) == _normalize_gpu_name(name)
                and abs(row.vram_gb - vram_gb) <= 2
            ),
            None,
        )
        details.append(
            f"GPU {gpu['index']}: {name}; VRAM={vram_gb}GB "
            f"(used={int(gpu['memory.used']) / 1024:.1f}GB); "
            f"temp={gpu['temperature.gpu']}C; driver={gpu['driver_version']}"
        )
        if matched is None:
            statuses.append("FAIL")
            details.append("  No matching capacity-audit calibration row.")
        elif not matched.calibrated:
            statuses.append("FAIL")
            details.append(
                f"  Row exists but is NOT calibrated: passes={matched.passes}, "
                f"deadline={matched.deadline_s:.1f}s."
            )
        else:
            statuses.append("PASS")
            details.append(
                f"  Calibrated: {matched.passes} timed passes within "
                f"{matched.deadline_s:.1f}s."
            )

    status = "FAIL" if "FAIL" in statuses else "PASS"
    summary = (
        f"{len(gpus)} GPU(s) detected; all have calibrated audit rows"
        if status == "PASS"
        else "At least one GPU is unsupported or uncalibrated"
    )
    return CheckResult("GPU", status, summary, tuple(details))


def _meminfo() -> dict[str, int]:
    values: dict[str, int] = {}
    for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
        key, _, raw = line.partition(":")
        token = raw.strip().split()[0]
        if token.isdigit():
            values[key] = int(token) * 1024
    return values


def check_cpu_ram() -> CheckResult:
    cpus = os.cpu_count() or 0
    mem = _meminfo()
    total_gb = mem.get("MemTotal", 0) / 1024**3
    available_gb = mem.get("MemAvailable", 0) / 1024**3
    load1, load5, load15 = os.getloadavg()
    details = (
        f"CPU logical cores={cpus}; load average={load1:.2f}/{load5:.2f}/{load15:.2f}",
        f"RAM total={total_gb:.1f}GB; currently available={available_gb:.1f}GB",
        "Recommended: >=8 logical cores and >=16GB RAM; avoid swap during mining.",
    )
    if cpus < 4 or total_gb < 8:
        return CheckResult("CPU/RAM", "FAIL", "Host resources are below safe minimums", details)
    if cpus < 8 or total_gb < 16:
        return CheckResult("CPU/RAM", "WARN", "Usable but proof concurrency may be constrained", details)
    return CheckResult("CPU/RAM", "PASS", "Host resources meet baseline", details)


def check_disk(workspace: pathlib.Path) -> CheckResult:
    target = workspace if workspace.exists() else workspace.parent
    usage = shutil.disk_usage(target)
    free_gb = usage.free / 1024**3
    details = (
        f"Filesystem={target}; free={free_gb:.1f}GB; total={usage.total / 1024**3:.1f}GB",
        "Model download size varies significantly; 100GB free is a practical baseline.",
    )
    if free_gb < 40:
        return CheckResult("Disk", "FAIL", "Insufficient free space for typical model caches", details)
    if free_gb < 100:
        return CheckResult("Disk", "WARN", "Free space may be insufficient for larger models", details)
    return CheckResult("Disk", "PASS", "Free space meets baseline", details)


def _http_probe(url: str, timeout_s: float, *, expect_audit_health: bool) -> tuple[bool, float, str]:
    started = time.monotonic()
    request = urllib.request.Request(url, headers={"User-Agent": "verathos-host-check/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=timeout_s) as response:
            body = response.read(4096)
            status = int(response.status)
    except urllib.error.HTTPError as exc:
        latency_ms = (time.monotonic() - started) * 1000
        # A rate limit still proves DNS/TCP/TLS/HTTP reachability, but not
        # application health.
        if not expect_audit_health and 400 <= int(exc.code) < 500:
            return True, latency_ms, f"HTTP {exc.code} (reachable)"
        return False, latency_ms, f"HTTP {exc.code}"
    except Exception as exc:
        return False, (time.monotonic() - started) * 1000, f"{type(exc).__name__}: {exc}"
    latency_ms = (time.monotonic() - started) * 1000
    if status != 200:
        return False, latency_ms, f"HTTP {status}"
    if expect_audit_health:
        try:
            data = json.loads(body)
        except Exception:
            return False, latency_ms, "HTTP 200, invalid JSON health response"
        service = str(data.get("service") or "").lower() if isinstance(data, dict) else ""
        capacity_audit = bool(data.get("capacity_audit")) if isinstance(data, dict) else False
        if service != "verathos-capacity-audit-ingest" and not capacity_audit:
            return False, latency_ms, "HTTP 200, wrong service"
    return True, latency_ms, "ok"


def _probe_series(
    name: str,
    url: str,
    *,
    samples: int,
    timeout_s: float,
    expect_audit_health: bool,
) -> tuple[str, str, tuple[str, ...]]:
    results: list[tuple[bool, float, str]] = []
    for sample in range(samples):
        results.append(_http_probe(url, timeout_s, expect_audit_health=expect_audit_health))
        if sample + 1 < samples:
            time.sleep(0.2)
    success = [latency for ok, latency, _ in results if ok]
    ratio = len(success) / max(1, samples)
    p50 = statistics.median(success) if success else math.inf
    p95 = _percentile(success, 0.95)
    errors = [reason for ok, _, reason in results if not ok]
    details = (
        f"URL={url}",
        f"samples={samples}; success={len(success)}/{samples} ({ratio:.0%}); "
        f"latency p50={p50:.0f}ms p95={p95:.0f}ms",
        f"errors={errors}" if errors else "errors=none",
    )
    if ratio >= 0.95 and p95 <= 1500:
        return "PASS", f"{name} is reliable with acceptable latency", details
    if ratio >= 0.80 and p95 <= 3000:
        return "WARN", f"{name} is reachable but has limited timing margin", details
    return "FAIL", f"{name} is unreliable or too slow", details


def _extract_urls(value) -> set[str]:
    urls: set[str] = set()
    if isinstance(value, str) and value.startswith(("http://", "https://")):
        urls.add(value.rstrip("/"))
    elif isinstance(value, dict):
        for child in value.values():
            urls.update(_extract_urls(child))
    elif isinstance(value, list):
        for child in value:
            urls.update(_extract_urls(child))
    return urls


def cached_validator_urls(cache_path: pathlib.Path) -> tuple[str, ...]:
    try:
        return tuple(sorted(_extract_urls(json.loads(cache_path.read_text()))))
    except Exception:
        return ()


def check_network(
    *,
    api_url: str,
    validator_urls: tuple[str, ...],
    samples: int,
    timeout_s: float,
) -> list[CheckResult]:
    results: list[CheckResult] = []
    status, summary, details = _probe_series(
        "Verathos API",
        api_url,
        samples=samples,
        timeout_s=timeout_s,
        expect_audit_health=False,
    )
    results.append(CheckResult("Control-plane network", status, summary, details))
    if not validator_urls:
        results.append(
            CheckResult(
                "Validator ingest network",
                "WARN",
                "No validator URLs available before setup; ingest reliability is unverified",
                (
                    "Pass one or more --validator-url values, or rerun after setup.",
                    "After setup, ./miner check-audit discovers current validator endpoints.",
                ),
            )
        )
        return results

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(16, len(validator_urls))) as pool:
        futures = {
            pool.submit(
                _probe_series,
                url,
                f"{url}/capacity/audit/v1/health",
                samples=samples,
                timeout_s=timeout_s,
                expect_audit_health=True,
            ): url
            for url in validator_urls
        }
        endpoint_results: list[CheckResult] = []
        for future in concurrent.futures.as_completed(futures):
            url = futures[future]
            try:
                endpoint_status, endpoint_summary, endpoint_details = future.result()
            except Exception as exc:
                endpoint_status, endpoint_summary, endpoint_details = (
                    "FAIL",
                    f"{url} probe crashed",
                    (str(exc),),
                )
            endpoint_results.append(
                CheckResult(f"Validator ingest {url}", endpoint_status, endpoint_summary, endpoint_details)
            )
    results.extend(sorted(endpoint_results, key=lambda item: item.name))
    return results


def check_audit_runtime_installed() -> CheckResult:
    candidates = [
        REPO_ROOT / ".venv-vllm" / "bin" / "python",
        pathlib.Path(sys.executable),
    ]
    for python in candidates:
        if not python.exists():
            continue
        try:
            output = _run(
                [
                    str(python),
                    "-c",
                    "import hot_capacity_workspace_cuda;"
                    "from hot_capacity_workspace.bench_combined import main;"
                    "print('ok')",
                ],
                timeout_s=30.0,
            )
        except Exception:
            continue
        if output.endswith("ok"):
            return CheckResult(
                "Audit runtime",
                "PASS",
                "CUDA audit wheel is installed and importable",
                ("Run ./miner check-audit after the miner starts to inspect worker logs.",),
            )
    return CheckResult(
        "Audit runtime",
        "INFO",
        "Audit wheel is not installed yet (expected before setup)",
        (
            "This pre-setup check cannot measure the real timed CUDA workload.",
            "After setup, run ./miner check-audit; only a real audit confirms timing headroom.",
        ),
    )


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workspace",
        type=pathlib.Path,
        default=pathlib.Path(os.environ.get("WORKSPACE", str(pathlib.Path.home()))),
        help="Filesystem where models will be cached (default: WORKSPACE or home)",
    )
    parser.add_argument(
        "--validator-url",
        action="append",
        default=[],
        help="Validator ingest base URL; repeat for multiple validators",
    )
    parser.add_argument(
        "--endpoint-cache",
        type=pathlib.Path,
        default=DEFAULT_ENDPOINT_CACHE,
        help="Use validator URLs from an existing discovery cache when present",
    )
    parser.add_argument("--api-url", default=DEFAULT_API_URL)
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--timeout-s", type=float, default=3.0)
    parser.add_argument(
        "--log-file",
        type=pathlib.Path,
        default=pathlib.Path.cwd() / f"miner-host-check-{timestamp}.log",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    reporter = Reporter(args.log_file.resolve())
    reporter.emit("Verathos miner host qualification")
    reporter.emit(f"Generated: {dt.datetime.now(dt.timezone.utc).isoformat()}")
    reporter.emit(f"Host: {os.uname().nodename}; kernel={os.uname().release}")
    reporter.emit(f"Repository: {REPO_ROOT}")
    reporter.emit("")

    manual = {
        str(url).rstrip("/")
        for url in (
            *args.validator_url,
            *filter(
                None,
                os.environ.get("VERATHOS_CAPACITY_AUDIT_VALIDATOR_URLS", "").split(","),
            ),
        )
        if str(url).startswith(("http://", "https://"))
    }
    urls = tuple(sorted(manual or set(cached_validator_urls(args.endpoint_cache))))

    results = [
        check_gpu(),
        check_cpu_ram(),
        check_disk(args.workspace.expanduser()),
        check_audit_runtime_installed(),
        *check_network(
            api_url=args.api_url,
            validator_urls=urls,
            samples=max(3, int(args.samples)),
            timeout_s=max(0.5, float(args.timeout_s)),
        ),
    ]
    for result in results:
        reporter.result(result)

    failures = sum(result.status == "FAIL" for result in results)
    warnings = sum(result.status == "WARN" for result in results)
    reporter.emit("")
    if failures:
        verdict = "BAD / DO NOT START MINING"
        exit_code = 1
    elif warnings:
        verdict = "CONDITIONAL / REVIEW WARNINGS"
        exit_code = 2
    else:
        verdict = "GOOD BASELINE / PROCEED TO SETUP"
        exit_code = 0
    reporter.emit(f"FINAL VERDICT: {verdict}")
    reporter.emit(
        "Priority: calibrated GPU + audit timing headroom + reliable low-latency "
        "validator access. Raw bandwidth is secondary."
    )
    reporter.emit(f"Detailed log: {reporter.log_path}")
    reporter.save()
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
