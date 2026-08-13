from __future__ import annotations

import queue
import threading
import unittest
from unittest import mock

from neurons.capacity_audit_miner import CapacityAuditMinerWorker


class _Response:
    def __init__(self, status_code: int, text: str = ""):
        self.status_code = status_code
        self.text = text


def _worker(urls: tuple[str, ...]) -> CapacityAuditMinerWorker:
    worker = object.__new__(CapacityAuditMinerWorker)
    worker.validator_urls = urls
    worker._validator_endpoint_resolver = None
    worker._audit_endpoint_rejections = {}
    worker._audit_endpoint_rejections_lock = threading.Lock()
    worker._publisher_lock = threading.Lock()
    worker._publisher_result_lock = threading.Lock()
    worker._publisher_stop = threading.Event()
    worker._publisher_queues: dict[str, queue.Queue] = {}
    worker._publisher_threads: dict[str, threading.Thread] = {}
    return worker


class PublishArtifactTests(unittest.TestCase):
    def tearDown(self) -> None:
        worker = getattr(self, "_worker", None)
        if worker is None:
            return
        worker._publisher_stop.set()
        for thread in tuple(worker._publisher_threads.values()):
            thread.join(timeout=1.0)

    def test_receipt_retry_does_not_repeat_successful_endpoint(self) -> None:
        worker = _worker(("http://validator-a", "http://validator-b"))
        self._worker = worker
        calls: list[tuple[str, float]] = []
        attempts = {"http://validator-b": 0}
        ready = threading.Event()

        def post(url: str, *, json: dict, timeout: float):
            del json
            calls.append((url, timeout))
            if url.startswith("http://validator-a"):
                return _Response(200)
            attempts["http://validator-b"] += 1
            if attempts["http://validator-b"] == 1:
                raise TimeoutError("slow")
            ready.set()
            return _Response(200)

        artifact = {"audit_id": "audit-1", "artifact_type": "capacity_audit_final_receipt"}
        with mock.patch("neurons.capacity_audit_miner.httpx.post", side_effect=post):
            queued = worker._publish_artifact(
                "/capacity/audit/v1/receipt",
                artifact,
                attempts=3,
                retry_delay_s=0.001,
            )
            self.assertTrue(worker._wait_for_async_publishes_for_test(timeout_s=2.0))
            self.assertTrue(ready.wait(timeout=2.0))

        self.assertEqual(queued, 2)
        self.assertEqual(
            sum(url.startswith("http://validator-a") for url, _ in calls),
            1,
        )
        self.assertEqual(
            sum(url.startswith("http://validator-b") for url, _ in calls),
            2,
        )
        self.assertTrue(all(timeout == 5.0 for _, timeout in calls))

    def test_unknown_slot_receipt_is_not_retried_after_rejection(self) -> None:
        worker = _worker(("http://validator-a",))
        self._worker = worker
        response = _Response(400, '{"error":"unknown audit slot"}')
        post = mock.Mock(return_value=response)
        artifact = {
            "audit_id": "audit-2",
            "artifact_type": "capacity_audit_final_receipt",
            "B_select": 10,
            "B_start": 15,
            "B_proof": 19,
        }
        with mock.patch(
            "neurons.capacity_audit_miner.httpx.post",
            post,
        ):
            queued = worker._publish_artifact(
                "/capacity/audit/v1/receipt",
                artifact,
                attempts=3,
            )
            self.assertTrue(worker._wait_for_async_publishes_for_test(timeout_s=2.0))

        self.assertEqual(queued, 1)
        self.assertEqual(post.call_count, 1)
        self.assertTrue(worker._validator_rejected_audit("http://validator-a", "audit-2"))


if __name__ == "__main__":
    unittest.main()
