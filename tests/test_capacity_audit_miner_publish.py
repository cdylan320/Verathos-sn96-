from __future__ import annotations

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
    return worker


class PublishArtifactTests(unittest.TestCase):
    def test_receipt_retry_does_not_repeat_successful_endpoint(self) -> None:
        worker = _worker(("http://validator-a", "http://validator-b"))
        calls: list[tuple[str, float]] = []
        attempts = {"http://validator-b": 0}

        def post(url: str, *, json: dict, timeout: float):
            del json
            calls.append((url, timeout))
            if url.startswith("http://validator-a"):
                return _Response(200)
            attempts["http://validator-b"] += 1
            if attempts["http://validator-b"] == 1:
                raise TimeoutError("slow")
            return _Response(200)

        artifact = {"audit_id": "audit-1", "artifact_type": "capacity_audit_final_receipt"}
        with mock.patch("neurons.capacity_audit_miner.httpx.post", side_effect=post):
            accepted = worker._publish_artifact(
                "/capacity/audit/v1/receipt",
                artifact,
                attempts=3,
                retry_delay_s=0.001,
                request_timeout_s=2.0,
                refresh_on_retry=False,
            )

        self.assertEqual(accepted, 2)
        self.assertEqual(
            sum(url.startswith("http://validator-a") for url, _ in calls),
            1,
        )
        self.assertEqual(
            sum(url.startswith("http://validator-b") for url, _ in calls),
            2,
        )
        self.assertTrue(all(timeout == 2.0 for _, timeout in calls))

    def test_unknown_slot_receipt_is_retried_without_blocking_later_artifacts(self) -> None:
        worker = _worker(("http://validator-a",))
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
            accepted = worker._publish_artifact(
                "/capacity/audit/v1/receipt",
                artifact,
                attempts=3,
                request_timeout_s=2.0,
                refresh_on_retry=False,
            )

        self.assertEqual(accepted, 0)
        self.assertEqual(post.call_count, 3)
        self.assertFalse(worker._validator_rejected_audit("http://validator-a", "audit-2"))


if __name__ == "__main__":
    unittest.main()
