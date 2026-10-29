import json
import tempfile
import unittest
from pathlib import Path

from tools.summarize_node_errors import enrich_results, summarize


class SummaryTests(unittest.TestCase):
    def test_groups_addresses_and_reports_missing_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            logs = root / "node_logs"
            logs.mkdir()
            nodes = [{"node": f"gossipsub-{i}", "group": "gossipsub", "state": "failed"}
                     for i in range(3)]
            (root / "node_results.json").write_text(json.dumps(
                {"nodes": nodes, "failed": 3, "num_nodes": 3, "ended": "all nodes exited"}))
            for i in range(2):
                (logs / f"gossipsub-{i}.log").write_text(
                    f'ERR 2026-10-29 22:09:0{i}.000+00:00 Invalid config '
                    f'error="/ip4/10.42.0.{i}/tcp/9000"\n')
            result = summarize(root)
            self.assertIn("gossipsub: 2 nodes", result)
            self.assertIn("1 failed nodes had no readable error line", result)
            self.assertIn("10.42.0.0", result)


    def test_structured_failure_is_attached_without_losing_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "node_logs").mkdir()
            node = {"node": "bootstrap-0", "group": "bootstrap", "state": "failed",
                    "exit_code": 1, "image_id": "sha256:abc"}
            (root / "node_results.json").write_text(json.dumps({"nodes": [node]}))
            failure = {"role": "bootstrap", "phase": "startup",
                       "category": "configuration", "message": "bad address"}
            (root / "node_logs/bootstrap-0.log").write_text(
                "NETWORK_LAB_FAILURE " + json.dumps(failure) + "\n")
            results = enrich_results(root)
            self.assertEqual(results["nodes"][0]["failure"], failure)
            self.assertEqual(results["nodes"][0]["image_id"], "sha256:abc")
            self.assertIn("phase=startup category=configuration", summarize(root, results))


if __name__ == "__main__":
    unittest.main()
