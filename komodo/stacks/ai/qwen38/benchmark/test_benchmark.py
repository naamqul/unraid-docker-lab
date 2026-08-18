#!/usr/bin/env python3

"""Local unit tests for the Arc Qwen3.8 benchmark harness."""

import base64
import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("qwen38_benchmark", ROOT / "benchmark.py")
assert SPEC and SPEC.loader
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)


class BenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.corpus = json.loads((ROOT / "corpus.json").read_text(encoding="utf-8"))

    def test_corpus_and_image_are_valid(self):
        info = benchmark.validate_corpus(self.corpus)
        self.assertEqual(info["corpus_name"], "qwen38-q6-f16-mtp-fixed-v1")
        self.assertEqual(
            info["image_sha256"]["vision_interactive"],
            "c3e865670d9bbeaec62cb5501187acce71737782582e948e2e5eb0e4f137d5d5",
        )
        encoded = (ROOT / "fixtures" / "vision-quadrants.png.b64").read_bytes()
        self.assertTrue(base64.b64decode(encoded).startswith(b"\x89PNG\r\n\x1a\n"))

    def test_generated_prompt_is_stable_and_contains_needles(self):
        workload = next(item for item in self.corpus["workloads"] if item["id"] == "near_limit")
        first = benchmark.make_generated_prompt(4000, workload, self.corpus["generator"])
        second = benchmark.make_generated_prompt(4000, workload, self.corpus["generator"])
        self.assertEqual(benchmark.sha256_text(first), benchmark.sha256_text(second))
        self.assertLess(first.index("ARC-NORTH-4931"), first.index("LUNAR-SOUTH-8276"))

    def test_calibration_converges_with_a_predictable_tokenizer(self):
        workload = next(item for item in self.corpus["workloads"] if item["id"] == "long_32k")
        tokenizer = lambda text: len(text.split())
        prompt, count, attempts = benchmark.calibrate_prompt(
            4096, 16, workload, self.corpus["generator"], tokenizer
        )
        self.assertLessEqual(abs(count - 4096), 16)
        self.assertIn("FORGE-32K-7319", prompt)
        self.assertLessEqual(attempts, 8)

    def test_prometheus_and_mtp_extractors(self):
        before = benchmark.parse_prometheus(
            "llamacpp:spec_decode_num_draft_tokens_total 10\n"
            "llamacpp:spec_decode_num_accepted_tokens_total 7\n"
        )
        after = benchmark.parse_prometheus(
            "llamacpp:spec_decode_num_draft_tokens_total 25\n"
            "llamacpp:spec_decode_num_accepted_tokens_total 18\n"
        )
        self.assertEqual(
            benchmark.metric_delta(
                before, after, ["llamacpp:spec_decode_num_draft_tokens_total"]
            ),
            15,
        )
        self.assertEqual(
            benchmark.extract_mtp({"timings": {"draft_n": 9, "draft_n_accepted": 6}}),
            {"draft_tokens": 9.0, "accepted_tokens": 6.0},
        )

    def test_correctness_order(self):
        workload = {
            "expected_contains": ["red", "blue", "green", "yellow"],
            "expected_order": ["red", "blue", "green", "yellow"],
        }
        self.assertTrue(benchmark.correctness("red, blue, green, yellow", workload)[0])
        self.assertFalse(benchmark.correctness("blue, red, green, yellow", workload)[0])

    def test_url_normalization(self):
        self.assertEqual(
            benchmark.chat_url("http://localhost:8080/v1"),
            "http://localhost:8080/v1/chat/completions",
        )
        self.assertEqual(
            benchmark.default_native_base("http://localhost:8080/v1"),
            "http://localhost:8080",
        )

    def test_ovms_v3_tokenizer_payload(self):
        class RecordingClient:
            request = None

            def post_json(self, url, body):
                self.request = (url, body)
                return {"tokens": [1, 2, 3]}

        client = RecordingClient()
        self.assertEqual(
            benchmark.tokenize_with_server(
                client,
                "http://localhost:8080",
                "hello",
                api="ovms-v3",
                model="qwen38-ovms-int8-cpu-131k",
            ),
            3,
        )
        self.assertEqual(
            client.request,
            (
                "http://localhost:8080/v3/tokenize",
                {
                    "model": "qwen38-ovms-int8-cpu-131k",
                    "text": "hello",
                    "add_special_tokens": False,
                },
            ),
        )

    def test_backend_specific_completion_limit(self):
        self.assertEqual(benchmark.completion_limit({}, 32), {"max_tokens": 32})
        self.assertEqual(
            benchmark.completion_limit(
                {"completion_token_field": "max_completion_tokens"}, 64
            ),
            {"max_completion_tokens": 64},
        )
        with self.assertRaises(ValueError):
            benchmark.completion_limit(
                {"completion_token_field": "unsupported"}, 64
            )

    def test_artifact_context_can_prove_at_least_runner_context(self):
        class DiagnosticClient:
            def get_json(self, _url):
                return {}

            def get_text(self, _url):
                return ""

        with tempfile.TemporaryDirectory() as directory:
            config = pathlib.Path(directory) / "config.json"
            config.write_text(
                json.dumps({"text_config": {"max_position_embeddings": 262144}}),
                encoding="utf-8",
            )
            evidence = benchmark.runner_preflight(
                {
                    "backend": "openvino-cpu",
                    "native_base_url": "http://localhost:8080",
                    "context": 131072,
                    "context_check": "at_least",
                    "context_evidence_file": str(config),
                    "require_backend_evidence": False,
                    "require_activity": False,
                },
                DiagnosticClient(),
            )
        self.assertEqual(evidence["reported_context_values"], [262144])


if __name__ == "__main__":
    unittest.main()
