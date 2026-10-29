#!/usr/bin/env python3
"""发布前 schema 兼容门禁：客户端实际使用的 GraphQL 字段必须在生产后端存在。

为什么需要（#1183）：`desktop-v0.1.0` 从 develop 构建时，登录调用
`signInForDesktop` / `wechatMiniWebLogin*ForDesktop`，但生产后端还是旧版 main，
GraphQL 返回 `Cannot query field`；客户端把无 code 的 GraphQL 错误映射成
`LoginError::Network`，界面只显示「网络异常」，整个包登录不可用。

做法：从 `crates/**/*.rs` 的 GraphQL 文档里提取顶层字段，逐个向端点发最小探测
请求（`{ field { __typename } }`）。只有 `Cannot query field` / `Unknown field`
判定为缺失；参数缺失、鉴权失败等错误说明字段存在。网络失败、响应不可解析
一律 fail-closed。

用法：
  python3 scripts/check_release_schema.py              # 检查生产端点
  python3 scripts/check_release_schema.py --self-test  # 不联网，验证提取与判定
  python3 scripts/check_release_schema.py --endpoint http://127.0.0.1:8080/api/graphql
"""

import argparse
import json
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

PROD_ENDPOINT = "https://api.codingirlsclub.com/api/graphql"
DEFAULT_TIMEOUT_SECONDS = 15.0
MAX_RESPONSE_BYTES = 1 << 20

ROOT = pathlib.Path(__file__).resolve().parent.parent  # desktop/

RAW_STRING_RE = re.compile(r'r#"(.*?)"#', re.S)
PLAIN_STRING_RE = re.compile(r'"((?:query|mutation)\s(?:[^"\\]|\\.)*)"', re.S)
OPERATION_RE = re.compile(r"^\s*(query|mutation)\b")
TEST_MODULE_RE = re.compile(r"#\[cfg\(test\)\]\s*mod\s+\w+\s*\{")


def strip_test_modules(text):
    """剥掉 `#[cfg(test)] mod ... { ... }` 整块：测试里的假 GraphQL 文档不是客户端依赖。"""
    while True:
        match = TEST_MODULE_RE.search(text)
        if not match:
            return text
        depth = 0
        index = match.end() - 1  # 指向 '{'
        while index < len(text):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    index += 1
                    break
            index += 1
        text = text[: match.start()] + text[index:]


def iter_documents():
    """遍历 desktop 源码里的 GraphQL 文档字符串（raw string 与单行普通字符串）。"""
    for path in sorted((ROOT / "crates").glob("*/src/**/*.rs")):
        text = strip_test_modules(path.read_text(encoding="utf-8", errors="replace"))
        for match in RAW_STRING_RE.finditer(text):
            if OPERATION_RE.match(match.group(1)):
                yield path, match.group(1)
        for match in PLAIN_STRING_RE.finditer(text):
            yield path, match.group(1)


def find_selection_start(text):
    """找 operation 选择集的第一个 `{`（跳过变量定义里的括号）。"""
    parens = 0
    for index, char in enumerate(text):
        if char == "(":
            parens += 1
        elif char == ")":
            parens = max(0, parens - 1)
        elif char == "{" and parens == 0:
            return index
    return -1


def skip_parens(text, index):
    """从 '(' 跳到匹配的 ')' 之后，跳过字段参数（参数里可能有对象字面量）。"""
    depth = 0
    while index < len(text):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return index


def top_level_fields(document):
    """返回选择集第一层的字段名（不取嵌套字段、参数名和 `__typename`）。"""
    text = re.sub(r"#[^\n]*", "", document)
    start = find_selection_start(text)
    if start < 0:
        return []
    fields = []
    index = start
    depth = 0
    while index < len(text):
        char = text[index]
        if text.startswith("...", index):
            # fragment spread / inline fragment：跳过 `... [on Type]`，其选择集交给 `{` 处理
            index += 3
            while index < len(text) and (text[index].isalnum() or text[index] in "_ \t\r\n"):
                index += 1
            continue
        if char == "{":
            depth += 1
            index += 1
            continue
        if char == "}":
            depth -= 1
            index += 1
            if depth == 0:
                break
            continue
        if char == "(" and depth >= 1:
            index = skip_parens(text, index)
            continue
        if depth == 1 and (char.isalpha() or char == "_"):
            end = index
            while end < len(text) and (text[end].isalnum() or text[end] == "_"):
                end += 1
            word = text[index:end]
            lookahead = end
            while lookahead < len(text) and text[lookahead].isspace():
                lookahead += 1
            if lookahead < len(text) and text[lookahead] == ":":
                # alias: field
                lookahead += 1
                while lookahead < len(text) and text[lookahead].isspace():
                    lookahead += 1
                field_end = lookahead
                while field_end < len(text) and (text[field_end].isalnum() or text[field_end] == "_"):
                    field_end += 1
                fields.append(text[lookahead:field_end])
                index = field_end
                continue
            if word not in {"on", "true", "false", "null"} and not word.startswith("__"):
                fields.append(word)
            index = end
            continue
        index += 1

    seen = set()
    ordered = []
    for field in fields:
        if field and field not in seen:
            seen.add(field)
            ordered.append(field)
    return ordered


def collect_fields():
    """返回 {(operation, field): 首个出现的源码路径}。"""
    found = {}
    for path, document in iter_documents():
        match = OPERATION_RE.match(document)
        if not match:
            continue
        operation = match.group(1)
        for field in top_level_fields(document):
            found.setdefault((operation, field), path)
    return found


def endpoint_allowed(endpoint):
    """端点白名单，与 crates/platform/src/runtime.rs 的 is_allowed_endpoint 对齐。"""
    parsed = urllib.parse.urlparse(endpoint)
    host = parsed.hostname or ""
    if parsed.scheme == "https":
        return host == "codingirlsclub.com" or host.endswith(".codingirlsclub.com")
    if parsed.scheme == "http":
        return host in {"localhost", "127.0.0.1", "::1"}
    return False


def probe(endpoint, operation, field, timeout):
    """返回 (状态, 说明)。状态：exists / missing / error。"""
    query = f"{operation} {{ {field} {{ __typename }} }}"
    request = urllib.request.Request(
        endpoint,
        data=json.dumps({"query": query}).encode("utf-8"),
        headers={"content-type": "application/json"},
        method="POST",
    )
    status_code = None
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status_code = response.status
            body = response.read(MAX_RESPONSE_BYTES)
    except urllib.error.HTTPError as error:
        status_code = error.code
        try:
            body = error.read(MAX_RESPONSE_BYTES)
        except OSError:
            return "error", f"HTTP {error.code} 且响应不可读"
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return "error", f"请求失败：{error}"

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return "error", f"响应不是 JSON（前 120 字节：{body[:120]!r}）"

    if not isinstance(payload, dict):
        return "error", "响应不是 GraphQL envelope（顶层不是对象）"

    errors = payload.get("errors") or []
    for item in errors:
        message = item.get("message", "") if isinstance(item, dict) else str(item)
        if "Cannot query field" in message:
            # `Cannot query field "__typename" on type "Boolean"` 是标量字段的正常
            # 报错：字段本身存在，只是不能选子字段（如 revokeToken: Boolean）。
            if message.startswith('Cannot query field "__typename"'):
                return "exists", message
            return "missing", message
        if "Unknown field" in message:
            return "missing", message
    if errors:
        first = errors[0]
        message = first.get("message", "") if isinstance(first, dict) else str(first)
        return "exists", message

    # 非 2xx 且没有 GraphQL errors：可能是 503 {"error": ...} 之类的代理/服务错误，
    # 不能当作「字段存在」（fail-closed）。
    if status_code is not None and status_code >= 400:
        return "error", f"HTTP {status_code} 响应不是 GraphQL 错误包（fail-closed）"
    if "data" not in payload:
        return "error", "响应缺少 data / errors（不是 GraphQL envelope，fail-closed）"
    return "exists", ""


def fail(message):
    print(f"✗ {message}", file=sys.stderr)
    return 1


def run_check(endpoint, timeout):
    if not endpoint_allowed(endpoint):
        return fail(
            f"端点不在白名单内：{endpoint}（https 只允许 codingirlsclub.com 及其子域，"
            "http 只允许本机回环）"
        )

    fields = collect_fields()
    if not fields:
        return fail("没有从 crates/**/*.rs 提取到任何 GraphQL 字段——提取器失效，需人工复核")

    ordered = sorted(fields)
    print(f"检查 {len(ordered)} 个 GraphQL 字段：{endpoint}")

    missing = []
    errors = []
    for operation, field in ordered:
        path = fields[(operation, field)]
        status, detail = probe(endpoint, operation, field, timeout)
        if status == "missing":
            missing.append((operation, field, path, detail))
        elif status == "error":
            errors.append((operation, field, path, detail))

    for operation, field, path, detail in missing:
        print(f"✗ {operation}.{field}（{path}）\n    {detail}", file=sys.stderr)
    for operation, field, path, detail in errors:
        print(f"✗ {operation}.{field}（{path}）探测失败：{detail}", file=sys.stderr)

    if missing:
        return fail(
            f"{len(missing)}/{len(ordered)} 个字段在生产后端不存在——禁止出包。"
            "先部署后端到 main，或回退客户端改动（见 #1183）"
        )
    if errors:
        return fail(f"{len(errors)}/{len(ordered)} 个字段无法确认（fail-closed）——禁止出包")

    print(f"✓ {len(ordered)} 个字段全部存在于 {endpoint}")
    return 0


def self_test():
    failures = 0

    def expect(name, actual, expected):
        nonlocal failures
        if actual == expected:
            print(f"SELF-TEST OK: {name} -> {actual}")
        else:
            print(f"SELF-TEST FAIL: {name} expected {expected}, got {actual}")
            failures += 1

    samples = [
        (
            "multiline mutation",
            "mutation SignIn($login: String!) {\n  signInForDesktop(login: $login) {\n    token\n  }\n}",
            ["signInForDesktop"],
        ),
        (
            "single-line query",
            "query ValidateSession { me { id } }",
            ["me"],
        ),
        (
            "alias/args/nested",
            "query {\n  alias: listCourses(first: 10, filter: {a: 1}) {\n    id\n  }\n  orderStatus\n}",
            ["listCourses", "orderStatus"],
        ),
        (
            "nested fields excluded",
            "query {\n  courseContent {\n    sections {\n      id\n    }\n    __typename\n  }\n}",
            ["courseContent"],
        ),
    ]
    for name, document, expected in samples:
        expect(name, top_level_fields(document), expected)

    test_module = '#[cfg(test)]\nmod tests {\n    fn f() { let q = "query { ok }"; }\n}\nquery { me }'
    expect("test module stripped", "query { ok }" in strip_test_modules(test_module), False)
    expect("non-test document kept", "query { me }" in strip_test_modules(test_module), True)

    # P1（Codex review）：分类必须调用真实 `probe()`，而不是复制条件——
    # 否则把 probe 改成恒返回 exists，self-test 仍会绿。
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class ProbeHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("content-length", 0))
            body = json.loads(self.rfile.read(length))
            query = body.get("query", "")
            if "missing_field" in query:
                self._reply(200, {"errors": [{"message": 'Cannot query field "missing_field" on type "RootQueryType".'}]})
            elif "scalar_field" in query:
                self._reply(200, {"errors": [{"message": 'Cannot query field "__typename" on type "Boolean".'}]})
            elif "server_error" in query:
                self._reply(503, {"error": "service_unavailable"})
            elif "bad_envelope" in query:
                self._reply(200, {"ok": True})
            else:
                self._reply(200, {"data": {"__typename": "X"}})

        def _reply(self, code, payload):
            data = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), ProbeHandler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        endpoint = f"http://127.0.0.1:{port}/api/graphql"
        probe_cases = [
            ("exists", "ok_field", "exists"),
            ("missing", "missing_field", "missing"),
            ("scalar", "scalar_field", "exists"),
            ("http 503", "server_error", "error"),
            ("bad envelope", "bad_envelope", "error"),
        ]
        for name, field, expected in probe_cases:
            status, _ = probe(endpoint, "query", field, 5)
            expect(f"probe: {name}", status, expected)
    finally:
        server.shutdown()
        server.server_close()

    allowed_cases = [
        (PROD_ENDPOINT, True),
        ("https://api.codingirlsclub.com/api/graphql", True),
        ("https://evil.example.com/api/graphql", False),
        ("http://127.0.0.1:8080/api/graphql", True),
        ("http://localhost:8080/api/graphql", True),
    ]
    for endpoint, expected in allowed_cases:
        expect(f"endpoint: {endpoint}", endpoint_allowed(endpoint), expected)

    if failures:
        return 1
    print("SELF-TEST OK: all checks")
    return 0


def main():
    parser = argparse.ArgumentParser(description="校验 desktop 客户端用到的 GraphQL 字段在生产后端存在")
    parser.add_argument("--endpoint", default=PROD_ENDPOINT, help="GraphQL 端点（默认生产）")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS, help="单次探测超时秒数")
    parser.add_argument("--self-test", action="store_true", help="不联网，验证提取与判定逻辑")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    return run_check(args.endpoint, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
