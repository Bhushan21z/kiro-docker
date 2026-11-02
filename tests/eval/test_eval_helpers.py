"""Unit tests for the evaluator's pod-side helpers.

  python3 -m unittest discover -s tests/eval -p 'test_*.py'
"""
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "eval"))

import safe_extract  # noqa: E402
import validate  # noqa: E402
import redact_stream  # noqa: E402

SCHEMA = os.path.join(ROOT, "eval", "schema", "result.schema.v1.json")


def make_zip(path, entries, symlink=None):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, body in entries.items():
            zf.writestr(name, body)
        if symlink:
            info = zipfile.ZipInfo(symlink[0])
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            zf.writestr(info, symlink[1])


class SafeExtractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dest = os.path.join(self.tmp, "out")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_extract(self, entries, symlink=None, **limits):
        z = os.path.join(self.tmp, "a.zip")
        make_zip(z, entries, symlink)
        args = dict(max_entries=100, max_file_bytes=1 << 20, max_total_bytes=1 << 21, max_ratio=1000)
        args.update(limits)
        return safe_extract.extract(z, self.dest, **args)

    def test_extracts_a_normal_tree_with_safe_modes(self):
        count, size = self.run_extract({"a/b.txt": "hi", "c.txt": "x"})
        self.assertEqual((count, size), (2, 3))
        mode = stat.S_IMODE(os.stat(os.path.join(self.dest, "a/b.txt")).st_mode)
        self.assertEqual(mode & 0o7000, 0)  # never setuid/setgid/sticky from the archive

    def test_rejects_traversal_absolute_and_backslash(self):
        for bad in ("../x", "a/../../x", "/etc/passwd", "a\\b", "C:/x"):
            with self.subTest(bad=bad), self.assertRaises(safe_extract.Rejected):
                self.run_extract({bad: "x"})

    def test_rejects_symlinks(self):
        with self.assertRaises(safe_extract.Rejected):
            self.run_extract({"a.txt": "x"}, symlink=("link", "/etc/passwd"))

    def test_enforces_entry_size_and_ratio_limits(self):
        with self.assertRaises(safe_extract.Rejected):
            self.run_extract({"a": "x", "b": "y"}, max_entries=1)
        with self.assertRaises(safe_extract.Rejected):
            self.run_extract({"a": "x" * 2000}, max_file_bytes=1000, max_ratio=10 ** 9)
        with self.assertRaises(safe_extract.Rejected):
            self.run_extract({"a": "0" * 200000}, max_ratio=50)

    def test_rejects_duplicates(self):
        z = os.path.join(self.tmp, "dup.zip")
        with zipfile.ZipFile(z, "w") as zf:
            zf.writestr("a", "1")
            zf.writestr("a", "2")
        with self.assertRaises(safe_extract.Rejected):
            safe_extract.extract(z, self.dest, 100, 1 << 20, 1 << 21, 1000)


class HtmlRulesTest(unittest.TestCase):
    OK = "<!DOCTYPE html><html><head><style>b{}</style></head><body><a href='#x'>x</a>" \
         "<img src='data:image/png;base64,AA'></body></html>"

    def test_accepts_self_contained_report(self):
        self.assertEqual(validate.check_html(self.OK), [])

    def test_rejects_each_rule(self):
        cases = {
            "script_tag": "<script>x</script>",
            "event_handler_attribute": "<div\nonclick='x'>",
            "javascript_url": "<a href='javascript:x'>",
            "external_resource": "<img src='https://e.test/p'>",
            "css_external_url": "<p style='background:url(//e.test/p)'>",
            "css_import": "<style>@import 'x';</style>",
            "embedded_frame": "<iframe></iframe>",
            "base_tag": "<base href='/'>",
            "form_tag": "<form>",
            "meta_refresh": "<meta http-equiv='refresh' content='0'>",
        }
        for rule, snippet in cases.items():
            with self.subTest(rule=rule):
                self.assertIn(f"report.html: {rule}", validate.check_html(self.OK.replace("</body>", snippet + "</body>")))


class ValidateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.inp = os.path.join(self.tmp, "input")
        self.out = os.path.join(self.tmp, "out")
        b = os.path.join(self.inp, "bundle")
        os.makedirs(os.path.join(b, "repo/final/src"))
        os.makedirs(os.path.join(b, "telemetry"))
        os.makedirs(os.path.join(b, "raw/db"))
        os.makedirs(os.path.join(self.inp, "rubric"))
        os.makedirs(self.out)
        with open(os.path.join(b, "repo/final/src/a.js"), "w") as fh:
            fh.write("1\n2\n3\n")
        with open(os.path.join(b, "telemetry/activity.jsonl"), "w") as fh:
            fh.write(json.dumps({"event_id": "activity-5"}) + "\n")
        with open(os.path.join(b, "raw/db/test_case_results.jsonl"), "w") as fh:
            fh.write(json.dumps({"id": 9}) + "\n")
        with open(os.path.join(b, "manifest.json"), "w") as fh:
            json.dump({"session": {"ended_reason": "submitted"}}, fh)
        with open(os.path.join(self.inp, "rubric/r.md"), "w") as fh:
            fh.write("# r\n")
        self.write(self.result(), HtmlRulesTest.OK)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def result(self, evidence=None):
        return {
            "schema_version": "1.0", "run_id": "r1", "user_event_id": 7,
            "rubric": {"source_files": ["rubric/r.md"], "derivation_notes": "n"},
            "criteria": [{"id": "c", "title": "C", "weight": 1, "max_score": 10, "score": 5,
                          "confidence": "high", "rationale": "r", "evidence": evidence or [
                              {"kind": "file", "ref": "repo/final/src/a.js:1-3"},
                              {"kind": "file", "ref": "rubric/r.md"},
                              {"kind": "event", "ref": "activity-5"},
                              {"kind": "test_run", "ref": "test_case_results-9"},
                              {"kind": "manifest", "ref": "session.ended_reason"}]}],
            "summary": {"strengths": [], "concerns": [], "narrative": "n"},
            "recommendation": "yes", "integrity_flags": [], "data_quality": []}

    def write(self, result, html):
        with open(os.path.join(self.out, "result.json"), "w") as fh:
            fh.write(result if isinstance(result, str) else json.dumps(result))
        with open(os.path.join(self.out, "report.html"), "w") as fh:
            fh.write(html)

    def check(self, key="ksk_live_123456789"):
        return validate.validate(self.out, self.inp, SCHEMA, "r1", "7", 0.5, key)

    def test_valid_outputs_with_every_ref_kind_resolving(self):
        rep = self.check()
        self.assertTrue(rep["ok"], rep["errors"])
        self.assertEqual(rep["evidence"]["ratio"], 1.0)

    def test_line_range_beyond_file_and_unknown_event_are_unverified(self):
        self.write(self.result([{"kind": "file", "ref": "repo/final/src/a.js:2-40"},
                                {"kind": "event", "ref": "activity-404"},
                                {"kind": "file", "ref": "../../etc/passwd"}]), HtmlRulesTest.OK)
        rep = self.check()
        self.assertFalse(rep["ok"])
        self.assertEqual(rep["evidence"]["verified"], 0)

    def test_wrong_run_id_and_score_above_max(self):
        r = self.result()
        r["run_id"] = "other"
        r["criteria"][0]["score"] = 11
        self.write(r, HtmlRulesTest.OK)
        errs = " ".join(self.check()["errors"])
        self.assertIn("run_id", errs)

    def test_secret_in_output_is_a_leak_not_a_repairable_error(self):
        self.write(self.result(), HtmlRulesTest.OK.replace("</body>", "ksk_live_123456789</body>"))
        rep = self.check()
        self.assertTrue(rep["secret_leak"])
        self.assertEqual(rep["secret_findings"], ["kiro_api_key_shape", "kiro_api_key_value"])

    def test_missing_files_and_bad_json(self):
        os.remove(os.path.join(self.out, "report.html"))
        self.assertIn("report.html was not written to /eval/out", self.check()["errors"])
        self.write("{nope", HtmlRulesTest.OK)
        self.assertTrue(any("not valid JSON" in e for e in self.check()["errors"]))


class RedactTest(unittest.TestCase):
    def test_redacts_key_value_shapes_and_presigned_urls(self):
        text = "a ksk_ABCDEFGH123 b secretvalue123 c https://x/y?X-Amz-Signature=z d AKIAABCDEFGHIJKLMNOP"
        out, n = redact_stream.redact(text, "secretvalue123")
        self.assertEqual(n, 4)
        for s in ("ksk_ABCDEFGH123", "secretvalue123", "X-Amz", "AKIA"):
            self.assertNotIn(s, out)


if __name__ == "__main__":
    unittest.main()
