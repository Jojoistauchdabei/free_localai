import argparse
import base64
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime

GITHUB_API = "https://api.github.com"
GITHUB_SEARCH_API = f"{GITHUB_API}/search/code"
GITHUB_HTML_SEARCH = "https://github.com/search"
USER_AGENT = "github-api-key-scanner/1.0"

DEFAULT_QUERIES = [
    "api_key",
    "apikey",
    "API_KEY",
    "ACCESS_TOKEN",
    "access_token",
    "client_secret",
    "secret_key",
    "private_key",
    "api_secret",
    "AUTH_TOKEN",
]

PATTERNS = [
    ("anthropic", re.compile(r"sk-ant-[0-9A-Za-z_\-]{20,}")),
    ("openai", re.compile(r"sk-[0-9A-Za-z_\-]{20,}")),
    ("github_fine_grained", re.compile(r"github_pat_[0-9A-Za-z_]{20,}")),
    ("github_classic", re.compile(r"ghp_[0-9A-Za-z]{36}")),
    ("github_oauth", re.compile(r"gho_[0-9A-Za-z]{36}")),
    ("github_user_to_server", re.compile(r"ghu_[0-9A-Za-z]{36}")),
    ("github_server_to_server", re.compile(r"ghs_[0-9A-Za-z]{36}")),
    ("github_refresh", re.compile(r"ghr_[0-9A-Za-z]{36}")),
    ("aws_access_key_id", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("slack_bot", re.compile(r"xoxb-[0-9]{10,}-[0-9A-Za-z\-]{20,}")),
    ("slack_user", re.compile(r"xoxp-[0-9]{10,}-[0-9A-Za-z\-]{20,}")),
    ("slack_app", re.compile(r"xoxe-[0-9]{10,}-[0-9A-Za-z\-]{20,}")),
    ("slack_legacy", re.compile(r"xox[apsr]-[0-9]{10,}-[0-9A-Za-z\-]{10,}")),
    ("stripe_live", re.compile(r"(?:sk|rk)_live_[0-9A-Za-z]{24,}")),
    ("stripe_test", re.compile(r"(?:sk|rk)_test_[0-9A-Za-z]{24,}")),
    ("google_gemini", re.compile(r"AIza[0-9A-Za-z_\-]{30,}")),
]

GENERIC_RE = re.compile(r"[0-9A-Za-z_\-]{32,}")


def shannon_entropy(s):
    if not s:
        return 0.0
    c = Counter(s)
    n = len(s)
    return -sum((v / n) * math.log2(v / n) for v in c.values())


def extract_candidates(text, generic):
    found = {}
    for name, pattern in PATTERNS:
        for m in pattern.finditer(text):
            key = m.group(0)
            if key not in found:
                found[key] = name
    if generic:
        for tok in GENERIC_RE.findall(text):
            if tok not in found and len(tok) >= 32 and shannon_entropy(tok) >= 3.6:
                found[tok] = "generic"
    return found


def http_request(url, headers=None, timeout=10):
    req = urllib.request.Request(url, headers=headers or {}, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(262144).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        try:
            body = e.read(262144).decode("utf-8", "replace")
        except Exception:
            body = ""
        return e.code, body
    except urllib.error.URLError as e:
        return 0, str(getattr(e, "reason", e))
    except Exception as e:
        return 0, str(e)


def classify(status):
    if 200 <= status < 300:
        return "valid", f"HTTP {status}"
    if status in (401, 403):
        return "invalid", f"HTTP {status}"
    return "unknown", f"HTTP {status}"


def test_github_api_key(key):
    status, _ = http_request(
        f"{GITHUB_API}/user",
        {"Authorization": f"token {key}", "Accept": "application/vnd.github+json"},
    )
    verdict, detail = classify(status)
    return verdict, f"GET /user -> {detail}"


def test_openai(key):
    status, _ = http_request("https://api.openai.com/v1/models", {"Authorization": f"Bearer {key}"})
    verdict, detail = classify(status)
    return verdict, f"GET /v1/models -> {detail}"


def test_anthropic(key):
    status, _ = http_request(
        "https://api.anthropic.com/v1/models",
        {"x-api-key": key, "anthropic-version": "2023-06-01"},
    )
    verdict, detail = classify(status)
    return verdict, f"GET /v1/models -> {detail}"


def test_slack(key):
    status, body = http_request("https://slack.com/api/auth.test", {"Authorization": f"Bearer {key}"})
    try:
        data = json.loads(body)
    except Exception:
        data = {}
    if data.get("ok") is True:
        return "valid", "auth.test -> ok=true"
    err = data.get("error", f"HTTP {status}")
    if err in ("invalid_auth", "bad_auth_token", "unauthorized"):
        return "invalid", f"auth.test -> {err}"
    return "unknown", f"auth.test -> {err}"


def test_stripe(key):
    token = base64.b64encode(key.encode("utf-8")).decode("ascii")
    status, _ = http_request("https://api.stripe.com/v1/balance", {"Authorization": f"Basic {token}"})
    verdict, detail = classify(status)
    return verdict, f"GET /v1/balance -> {detail}"


def test_google(key):
    status, body = http_request("https://generativelanguage.googleapis.com/v1beta/models", {"x-goog-api-key": key})
    verdict, detail = classify(status)
    if verdict == "valid":
        return "valid", f"GET /v1beta/models -> {detail}"
    lowered = body.lower()
    if "not valid" in lowered or "invalid" in lowered:
        return "invalid", f"GET /v1beta/models -> {detail}"
    return "unknown", f"GET /v1beta/models -> {detail}"


def test_aws_format_only(key):
    return "skipped", "AWS keys have no standalone validation endpoint; verify manually with 'aws sts get-caller-identity'"


TESTERS = {
    "anthropic": test_anthropic,
    "openai": test_openai,
    "github_classic": test_github_api_key,
    "github_oauth": test_github_api_key,
    "github_user_to_server": test_github_api_key,
    "github_server_to_server": test_github_api_key,
    "github_refresh": test_github_api_key,
    "github_fine_grained": test_github_api_key,
    "slack_bot": test_slack,
    "slack_user": test_slack,
    "slack_app": test_slack,
    "slack_legacy": test_slack,
    "stripe_live": test_stripe,
    "stripe_test": test_stripe,
    "google_gemini": test_google,
    "aws_access_key_id": test_aws_format_only,
}


def get_github_token():
    for env in ("GITHUB_TOKEN", "GITHUB_PAT"):
        value = os.environ.get(env, "").strip()
        if value:
            return value
    try:
        r = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            value = r.stdout.strip()
            if value:
                return value
    except Exception:
        pass
    return None


def fetch_file_text(item):
    repo = item.get("repository") or {}
    full = repo.get("full_name")
    path = item.get("path")
    branch = repo.get("default_branch") or "master"
    if not (full and path):
        return ""
    url = f"https://raw.githubusercontent.com/{full}/{branch}/{urllib.parse.quote(path)}"
    status, body = http_request(url, {"User-Agent": USER_AGENT})
    return body if status == 200 else ""


def search_code_api(query, token, per_page):
    url = f"{GITHUB_SEARCH_API}?q={urllib.parse.quote(query)}&per_page={per_page}"
    headers = {
        "Accept": "application/vnd.github.text-match+json",
        "User-Agent": USER_AGENT,
    }
    if token:
        headers["Authorization"] = f"token {token}"
    status, body = http_request(url, headers)
    if status != 200:
        return [], f"search API returned HTTP {status}"
    try:
        data = json.loads(body)
    except Exception as e:
        return [], f"search API returned invalid JSON: {e}"
    entries = []
    for item in data.get("items", []):
        fragments = "\n".join(tm.get("fragment", "") for tm in item.get("text_matches", []))
        file_text = fetch_file_text(item)
        text = "\n".join(t for t in (fragments, file_text) if t)
        entries.append({"url": item.get("html_url", ""), "text": text})
    return entries, ""


def search_code_scrape(query, per_page):
    url = f"{GITHUB_HTML_SEARCH}?q={urllib.parse.quote(query)}&type=code&per_page={per_page}"
    status, html = http_request(url, {"User-Agent": USER_AGENT, "Accept": "text/html"})
    if status != 200:
        return [], f"HTML search returned HTTP {status}"
    urls = [f"https://github.com{u}" for u in re.findall(r'href="(/[^"]+/blob/[^"]+)"', html)]
    return [{"url": u, "text": html} for u in urls] or [{"url": "", "text": html}], ""


def dedupe(cands):
    seen = {}
    for c in cands:
        key = (c["type"], c["key"])
        if key not in seen:
            seen[key] = c
    return list(seen.values())


def redact(key):
    return f"{key[:8]}...(len={len(key)})"


def run_tests(cands):
    for c in cands:
        tester = TESTERS.get(c["type"])
        if tester:
            try:
                verdict, detail = tester(c["key"])
            except Exception as e:
                verdict, detail = "unknown", f"error: {e}"
            c["test"] = {"verdict": verdict, "detail": detail}
        else:
            c["test"] = {"verdict": "skipped", "detail": "no test endpoint for this key type"}
        time.sleep(0.2)


def write_report(cands, queries, generic, out_path):
    report = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "queries": queries,
        "generic": generic,
        "candidates": cands,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    return out_path


def main():
    parser = argparse.ArgumentParser(
        description="Scan GitHub for API keys and access tokens in public code."
    )
    parser.add_argument(
        "--queries",
        nargs="*",
        default=DEFAULT_QUERIES,
        help="GitHub code search queries (default: common secret patterns)",
    )
    parser.add_argument("--per-page", type=int, default=50, help="results per query (default: 50, max 100)")
    parser.add_argument("--generic", action="store_true", help="also extract generic high-entropy tokens")
    parser.add_argument("--test", dest="test", action="store_true", default=True, help="test each found key with a read-only provider call")
    parser.add_argument("--no-test", dest="test", action="store_false", help="scan only, do not test keys")
    parser.add_argument("--output", default=None, help="report path (default: github_api_key_scan_<timestamp>.json)")
    args = parser.parse_args()

    args.queries = [q for q in args.queries if q]
    per_page = max(1, min(args.per_page, 100))

    if args.test:
        print("WARNING: testing enabled. Each test sends the found key to the provider API")
        print("(api.openai.com, slack.com, api.stripe.com, ...) - only test keys you know")
        print("are exposed or leaked. Disable with --no-test.")
        print()

    token = get_github_token()

    candidates = []
    for query in args.queries:
        entries, err = ([], "")
        if token:
            entries, err = search_code_api(query, token, per_page)
        else:
            entries, err = search_code_scrape(query, per_page)
        if err:
            print(f"warning: query '{query}': {err}", file=sys.stderr)
        for entry in entries:
            for key, name in extract_candidates(entry["text"], args.generic).items():
                candidates.append({"type": name, "key": key, "source_url": entry["url"] or query})
        time.sleep(1.0)

    candidates = dedupe(candidates)

    if args.test:
        run_tests(candidates)

    out_path = args.output or f"github_api_key_scan_{datetime.now():%Y%m%d_%H%M%S}.json"
    write_report(candidates, args.queries, args.generic, out_path)

    by_type = {}
    for c in candidates:
        by_type[c["type"]] = by_type.get(c["type"], 0) + 1
    types_summary = ", ".join(f"{t}={n}" for t, n in sorted(by_type.items())) or "none"
    print(f"Found {len(candidates)} candidate(s): {types_summary}")
    for c in candidates:
        line = f"  [{c['type']}] {redact(c['key'])} <- {c['source_url']}"
        if "test" in c:
            line += f"  test={c['test']['verdict']}"
            if c["test"]["detail"]:
                line += f" ({c['test']['detail']})"
        print(line)
    print(f"Report: {out_path}")


if __name__ == "__main__":
    main()
