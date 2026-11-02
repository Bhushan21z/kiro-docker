#!/usr/bin/env python3
"""Check an evaluator's outputs before they leave the pod.

Mirrors the server's acceptance gate (codinferno utils/evaluation/
resultContract.js) so a bad output gets one repair turn here instead of a
failed run there, and adds the one check only the pod can make: whether each
cited piece of evidence actually exists in the input the agent was given. A
score whose citations do not resolve is an assertion, not a finding.

The server re-runs every contract check itself. Nothing here is trusted
downstream; it exists to catch problems while they can still be fixed.

Exit status: 0 valid, 1 invalid (repairable), 4 credential material found
(never repaired, never uploaded), 2 usage error. A JSON report is always
written to --report.
"""
import argparse
import json
import os
import re
import sys

try:
    import jsonschema
except ImportError:  # pragma: no cover - the image always has it
    jsonschema = None

MAX_REPORT_BYTES = 10 * 1024 * 1024
MAX_RESULT_BYTES = 2 * 1024 * 1024

SECRET_PATTERNS = [
    ("kiro_api_key_shape", re.compile(r"ksk_[A-Za-z0-9_-]{8,}")),
    ("aws_presigned_signature", re.compile(r"X-Amz-Signature=", re.I)),
    ("aws_presigned_credential", re.compile(r"X-Amz-Credential=", re.I)),
    ("aws_access_key_id", re.compile(r"\b(AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("private_key_block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
]

# Same deny-list, same ids, as resultContract.js HTML_RULES.
HTML_RULES = [
    ("script_tag", re.compile(r"<\s*script\b", re.I)),
    ("event_handler_attribute", re.compile(r"<[^>]*\son[a-z]+\s*=", re.I)),
    ("javascript_url", re.compile(r"(?:href|src|action|formaction|xlink:href)\s*=\s*[\"']?\s*javascript:", re.I)),
    ("external_resource", re.compile(r"(?:src|href|action|formaction|srcset|poster|data|xlink:href)\s*=\s*[\"']?\s*(?:https?:)?//", re.I)),
    ("css_external_url", re.compile(r"url\(\s*[\"']?\s*(?:https?:)?//", re.I)),
    ("css_import", re.compile(r"@import\b", re.I)),
    ("embedded_frame", re.compile(r"<\s*(?:iframe|frame|object|embed|applet)\b", re.I)),
    ("base_tag", re.compile(r"<\s*base\b", re.I)),
    ("form_tag", re.compile(r"<\s*form\b", re.I)),
    ("meta_refresh", re.compile(r"<\s*meta[^>]+http-equiv\s*=\s*[\"']?\s*refresh", re.I)),
]

REF_LINES = re.compile(r"^(?P<path>[^:]+?)(?::(?P<start>\d+)(?:-(?P<end>\d+))?)?$")


def scan_secrets(text, api_key):
    found = []
    if api_key and len(api_key) >= 8 and api_key in text:
        found.append("kiro_api_key_value")
    for rid, rx in SECRET_PATTERNS:
        if rx.search(text):
            found.append(rid)
    return found


def check_html(html):
    errors = []
    if not html.strip():
        return ["report is empty"]
    if len(html.encode("utf-8")) > MAX_REPORT_BYTES:
        errors.append(f"report exceeds {MAX_REPORT_BYTES} bytes")
    if not re.search(r"<\s*html\b", html, re.I) or not re.search(r"<\s*body\b", html, re.I):
        errors.append("report is not a complete HTML document")
    flat = re.sub(r"\r?\n", " ", html)
    for rid, rx in HTML_RULES:
        if rx.search(flat):
            errors.append(f"report.html: {rid}")
    return errors


def check_result_contract(result, schema, run_id, user_event_id):
    errors = []
    if jsonschema is None:
        return ["jsonschema module unavailable"]
    validator = jsonschema.Draft7Validator(schema)
    for err in sorted(validator.iter_errors(result), key=lambda e: list(e.absolute_path)):
        where = "/" + "/".join(str(p) for p in err.absolute_path)
        errors.append(f"result.json {where}: {err.message}")
    if errors:
        return errors
    if run_id and result.get("run_id") != run_id:
        errors.append("result.json /run_id: must equal the run_id in eval-manifest.json")
    if user_event_id and result.get("user_event_id") != int(user_event_id):
        errors.append("result.json /user_event_id: must equal the user_event_id in eval-manifest.json")
    seen = set()
    for i, c in enumerate(result["criteria"]):
        if c["id"] in seen:
            errors.append(f"result.json /criteria/{i}/id: duplicate criterion id '{c['id']}'")
        seen.add(c["id"])
        if c["score"] > c["max_score"]:
            errors.append(f"result.json /criteria/{i}/score: {c['score']} exceeds max_score {c['max_score']}")
    return errors


class EvidenceIndex:
    """Lazily built lookups over the input tree the agent read."""

    def __init__(self, input_root):
        self.root = os.path.realpath(input_root)
        self.bundle = os.path.join(self.root, "bundle")
        self._event_ids = None
        self._test_ids = None
        self._diff_paths = None
        self._manifests = None

    def _inside(self, path):
        real = os.path.realpath(path)
        return real if real == self.root or real.startswith(self.root + os.sep) else None

    def resolve_file(self, rel):
        rel = rel.strip().lstrip("/")
        for base in (self.bundle, self.root):
            real = self._inside(os.path.join(base, rel))
            if real and os.path.isfile(real):
                return real
        return None

    def event_ids(self):
        if self._event_ids is None:
            ids = set()
            tdir = os.path.join(self.bundle, "telemetry")
            if os.path.isdir(tdir):
                for name in sorted(os.listdir(tdir)):
                    if not name.endswith(".jsonl"):
                        continue
                    with open(os.path.join(tdir, name), encoding="utf-8", errors="replace") as fh:
                        for line in fh:
                            try:
                                ev = json.loads(line)
                            except ValueError:
                                continue
                            if isinstance(ev, dict) and ev.get("event_id"):
                                ids.add(str(ev["event_id"]))
            self._event_ids = ids
        return self._event_ids

    def test_run_ids(self):
        if self._test_ids is None:
            ids = set()
            path = os.path.join(self.bundle, "raw", "db", "test_case_results.jsonl")
            if os.path.isfile(path):
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        try:
                            row = json.loads(line)
                        except ValueError:
                            continue
                        if isinstance(row, dict) and row.get("id") is not None:
                            ids.add(f"test_case_results-{row['id']}")
            self._test_ids = ids
        return self._test_ids

    def diff_paths(self):
        if self._diff_paths is None:
            paths = set()
            patch = os.path.join(self.bundle, "repo", "diff.patch")
            if os.path.isfile(patch):
                with open(patch, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        m = re.match(r"^(?:\+\+\+ b/|--- a/)(.+?)\s*$", line)
                        if m:
                            paths.add(m.group(1))
            self._diff_paths = paths
        return self._diff_paths

    def manifests(self):
        if self._manifests is None:
            out = []
            for p in (os.path.join(self.bundle, "manifest.json"), os.path.join(self.root, "eval-manifest.json")):
                try:
                    with open(p, encoding="utf-8") as fh:
                        out.append(json.load(fh))
                except (OSError, ValueError):
                    pass
            self._manifests = out
        return self._manifests


def line_count(path):
    with open(path, "rb") as fh:
        return sum(1 for _ in fh)


def verify_ref(index, kind, ref):
    """Return None if the reference resolves, else a short reason."""
    ref = ref.strip()
    if kind in ("file", "diff"):
        m = REF_LINES.match(ref)
        if not m:
            return "unparseable reference"
        path = index.resolve_file(m.group("path"))
        if path is None:
            if kind == "diff":
                rel = m.group("path").strip()
                rel = rel[len("repo/final/"):] if rel.startswith("repo/final/") else rel
                if rel in index.diff_paths():
                    return None
            return "file not found in input"
        if m.group("start"):
            start = int(m.group("start"))
            end = int(m.group("end") or start)
            if start < 1 or end < start:
                return "invalid line range"
            if end > line_count(path):
                return "line range beyond end of file"
        return None
    if kind == "event":
        return None if ref in index.event_ids() else "event_id not present in telemetry"
    if kind == "test_run":
        return None if (ref in index.test_run_ids() or ref in index.event_ids()) else "test run not present in bundle"
    if kind == "manifest":
        key = re.sub(r"^(?:eval-)?manifest\.json\s*(?:#/?|:)?", "", ref).lstrip("/.")
        first = re.split(r"[./#\[]", key, maxsplit=1)[0] if key else ""
        if not first:
            return None if index.manifests() else "manifest not present"
        return None if any(first in m for m in index.manifests() if isinstance(m, dict)) else "manifest key not found"
    return "unknown evidence kind"


def check_evidence(result, index):
    total = 0
    verified = 0
    unverified = []
    groups = [("criteria", c.get("id"), c.get("evidence") or []) for c in result.get("criteria", [])]
    groups += [("integrity_flags", f.get("kind"), f.get("evidence") or []) for f in result.get("integrity_flags", [])]
    for section, owner, evidence in groups:
        for ev in evidence:
            total += 1
            reason = verify_ref(index, ev.get("kind"), str(ev.get("ref", "")))
            if reason is None:
                verified += 1
            elif len(unverified) < 50:
                unverified.append({"section": section, "owner": owner, "kind": ev.get("kind"),
                                   "ref": str(ev.get("ref", ""))[:200], "reason": reason})
    ratio = round(verified / total, 4) if total else 1.0
    return {"total": total, "verified": verified, "ratio": ratio, "unverified": unverified}


def _shape_errors(example, value, where="$", out=None, depth=0):
    """Compare value's shape with an example instance: same keys, same JSON
    types, recursively. Lists are compared element-wise against the example's
    first element. `null` in either is accepted (evidence may not support a
    value). Returns at most 20 errors."""
    out = [] if out is None else out
    if len(out) >= 20 or depth > 20 or example is None or value is None:
        return out
    tname = lambda v: "object" if isinstance(v, dict) else "array" if isinstance(v, list) else \
        "boolean" if isinstance(v, bool) else "number" if isinstance(v, (int, float)) else "string"
    if tname(example) != tname(value):
        out.append(f"custom_result.json {where}: expected {tname(example)}, got {tname(value)}")
        return out
    if isinstance(example, dict):
        for k in example:
            if k not in value:
                out.append(f"custom_result.json {where}: missing key '{k}'")
            else:
                _shape_errors(example[k], value[k], f"{where}.{k}", out, depth + 1)
        for k in value:
            if k not in example:
                out.append(f"custom_result.json {where}: unexpected key '{k}'")
    elif isinstance(example, list) and example:
        for i, item in enumerate(value[:50]):
            _shape_errors(example[0], item, f"{where}[{i}]", out, depth + 1)
    return out


def _looks_like_schema(doc):
    return isinstance(doc, dict) and ("$schema" in doc or (doc.get("type") in ("object", "array") and "properties" in doc))


def check_custom_result(out_dir, input_root, result):
    """custom_result.json is the challenge's own output format. Its shape comes
    from a file the evaluator found in the rubric and named in
    result.output_format, so it is checked against that file."""
    path = os.path.join(out_dir, "custom_result.json")
    fmt = result.get("output_format") if isinstance(result, dict) else None
    if not os.path.isfile(path):
        if fmt and fmt.get("kind") in ("json_structure", "json_schema", "json_and_html"):
            return ["result.json declares a JSON output_format but /eval/out/custom_result.json was not written"]
        return []
    if not fmt:
        return ["custom_result.json was written but result.json has no output_format naming its source"]
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)
    except ValueError as err:
        return [f"custom_result.json is not valid JSON: {err}"]
    root = os.path.realpath(input_root)
    errors = []
    json_sources = []
    for rel in fmt.get("source_files", []):
        real = os.path.realpath(os.path.join(root, rel.lstrip("/")))
        if not real.startswith(root + os.sep) or not os.path.isfile(real):
            errors.append(f"output_format source '{rel}' does not exist under /eval/input")
        elif real.lower().endswith(".json"):
            json_sources.append(real)
    for src in json_sources[:1]:
        try:
            with open(src, encoding="utf-8") as fh:
                ref = json.load(fh)
        except ValueError:
            continue
        if _looks_like_schema(ref) and jsonschema is not None:
            try:
                for err in sorted(jsonschema.Draft7Validator(ref).iter_errors(value), key=lambda e: list(e.absolute_path))[:20]:
                    where = "/" + "/".join(str(p) for p in err.absolute_path)
                    errors.append(f"custom_result.json {where}: {err.message}")
            except jsonschema.exceptions.SchemaError:
                pass
        else:
            errors.extend(_shape_errors(ref, value))
    return errors


def read_text(path, limit):
    if not os.path.isfile(path):
        return None
    if os.path.getsize(path) > limit:
        raise ValueError(f"{os.path.basename(path)} exceeds {limit} bytes")
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def validate(out_dir, input_root, schema_path, run_id, user_event_id, min_ratio, api_key):
    report = {"ok": False, "secret_leak": False, "secret_findings": [], "errors": [], "evidence": None}
    try:
        result_text = read_text(os.path.join(out_dir, "result.json"), MAX_RESULT_BYTES)
        html = read_text(os.path.join(out_dir, "report.html"), MAX_REPORT_BYTES)
    except ValueError as err:
        report["errors"].append(str(err))
        return report
    if result_text is None:
        report["errors"].append("result.json was not written to /eval/out")
    if html is None:
        report["errors"].append("report.html was not written to /eval/out")

    custom_text = None
    custom_path = os.path.join(out_dir, "custom_result.json")
    if os.path.isfile(custom_path):
        try:
            custom_text = read_text(custom_path, MAX_RESULT_BYTES)
        except ValueError as err:
            report["errors"].append(str(err))
    leaks = sorted(set(scan_secrets(result_text or "", api_key) + scan_secrets(html or "", api_key)
                       + scan_secrets(custom_text or "", api_key)))
    if leaks:
        report.update(secret_leak=True, secret_findings=leaks)
        report["errors"].append("outputs contain credential material")
        return report
    if result_text is None or html is None:
        return report

    try:
        result = json.loads(result_text)
    except ValueError as err:
        report["errors"].append(f"result.json is not valid JSON: {err}")
        return report

    with open(schema_path, encoding="utf-8") as fh:
        schema = json.load(fh)
    report["errors"].extend(check_result_contract(result, schema, run_id, user_event_id))
    report["errors"].extend(check_html(html))
    report["errors"].extend(check_custom_result(out_dir, input_root, result))
    if not report["errors"]:
        report["evidence"] = check_evidence(result, EvidenceIndex(input_root))
        if report["evidence"]["ratio"] < min_ratio:
            sample = "; ".join(f"{u['ref']} ({u['reason']})" for u in report["evidence"]["unverified"][:10])
            report["errors"].append(
                f"only {report['evidence']['verified']}/{report['evidence']['total']} evidence references resolve "
                f"(minimum ratio {min_ratio}); unresolved: {sample}")
    report["ok"] = not report["errors"]
    return report


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--out", required=True)
    p.add_argument("--input", required=True)
    p.add_argument("--schema", required=True)
    p.add_argument("--report", required=True)
    p.add_argument("--run-id", default="")
    p.add_argument("--user-event-id", default="")
    p.add_argument("--min-evidence-ratio", type=float, default=float(os.environ.get("EVAL_MIN_EVIDENCE_RATIO", "0.5")))
    args = p.parse_args(argv)
    # Read from the environment, never argv, so the key is not visible in ps.
    report = validate(args.out, args.input, args.schema, args.run_id, args.user_event_id,
                      args.min_evidence_ratio, os.environ.get("KIRO_API_KEY", ""))
    with open(args.report, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    if report["secret_leak"]:
        return 4
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
