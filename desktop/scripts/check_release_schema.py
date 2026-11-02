#!/usr/bin/env python3
"""发布前 schema 兼容门禁：客户端实际使用的 GraphQL 字段必须在生产后端存在。

为什么需要（#1183）：`desktop-v0.1.0` 从 develop 构建时，登录调用
`signInForDesktop` / `wechatMiniWebLogin*ForDesktop`，但生产后端还是旧版 main，
GraphQL 返回 `Cannot query field`；客户端把无 code 的 GraphQL 错误映射成
`LoginError::Network`，界面只显示「网络异常」，整个包登录不可用。

做法：从 `crates/**/*.rs` 的 GraphQL 文档里提取每份 document，逐个向端点提交**完整
文档**（保留嵌套选择集、变量定义与 fragment 定义），并在根选择集字段上加
`@skip(if: true)`：服务端仍执行完整的 schema 校验，但不会调用 resolver，所以探测
本身没有副作用（不会登录、下单、撤销 token）。同一 root field 的多套选择集各自探测，
不做字段级去重。只有 `Cannot query field` / `Unknown field` 判定为缺失——嵌套字段
缺失同样会被这类校验错误暴露；变量校验失败、鉴权失败等错误只说明字段存在。
网络失败、响应不可解析一律 fail-closed。

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
VARIABLE_RE = re.compile(r"\$([A-Za-z_]\w*)\s*:\s*([\[\]!\w]+)")

# 探测时给变量占位：标量给类型合法的值，其余（输入对象、枚举、列表）给 null。
# null 触发的是变量校验错误，按既有语义仍判「字段存在」，不影响缺失判定。
SCALAR_PLACEHOLDERS = {"Int": 0, "Float": 0.0, "String": "", "Boolean": True, "ID": "0"}


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


def find_selection_start(text, start=0):
    """从 `start` 起找选择集的第一个 `{`（跳过变量定义里的括号与默认值）。"""
    parens = 0
    for index in range(start, len(text)):
        char = text[index]
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
    seen = set()
    ordered = []
    for field, _ in iter_root_fields(document):
        if not field or field in seen or field.startswith("__") or field in {"on", "true", "false", "null"}:
            continue
        seen.add(field)
        ordered.append(field)
    return ordered


def operation_selection_start(document):
    """返回操作选择集第一个 `{` 的位置（从操作关键字起找，避免跑到 fragment 定义里）。"""
    match = OPERATION_RE.match(document)
    return find_selection_start(document, match.start() if match else 0)


def iter_root_fields(document):
    """遍历操作选择集第一层的 (字段名, 插入指令的位置)：位置在字段参数之后、选择集之前。"""
    index = operation_selection_start(document)
    if index < 0:
        return
    depth = 0
    while index < len(document):
        char = document[index]
        if char == "#":
            while index < len(document) and document[index] != "\n":
                index += 1
            continue
        if document.startswith("...", index):
            # fragment spread / inline fragment：跳过 `... [on Type]`，其选择集交给 `{` 处理
            index += 3
            while index < len(document) and (document[index].isalnum() or document[index] == "_"):
                index += 1
            while index < len(document) and document[index] in " \t\r\n":
                index += 1
            if document.startswith("on", index) and index + 2 < len(document) and not (
                document[index + 2].isalnum() or document[index + 2] == "_"
            ):
                index += 2
                while index < len(document) and (document[index].isalnum() or document[index] == "_"):
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
                return
            continue
        if char == "(":
            index = skip_parens(document, index)
            continue
        if depth == 1 and (char.isalpha() or char == "_"):
            end = index
            while end < len(document) and (document[end].isalnum() or document[end] == "_"):
                end += 1
            name = document[index:end]
            insert = end
            cursor = _skip_space(document, end)
            if cursor < len(document) and document[cursor] == ":":
                # alias: field —— 指令要加在真实字段的参数之后
                cursor = _skip_space(document, cursor + 1)
                field_end = cursor
                while field_end < len(document) and (document[field_end].isalnum() or document[field_end] == "_"):
                    field_end += 1
                name = document[cursor:field_end]
                insert = field_end
                cursor = _skip_space(document, field_end)
            if cursor < len(document) and document[cursor] == "(":
                insert = cursor = skip_parens(document, cursor)
            yield name, insert
            index = cursor
            continue
        index += 1


def _skip_space(text, index):
    while index < len(text) and text[index] in " \t\r\n":
        index += 1
    return index


def variable_placeholders(document):
    """按操作变量定义生成占位变量：标量给类型合法的值，其余给 null。"""
    match = OPERATION_RE.match(document)
    start = operation_selection_start(document)
    if not match or start < 0:
        return {}
    variables = {}
    for name, type_text in VARIABLE_RE.findall(document[match.start():start]):
        base = type_text.replace("[", "").replace("]", "").replace("!", "")
        variables[name] = SCALAR_PLACEHOLDERS.get(base)
    return variables


def build_probe(document):
    """返回 (探测用文档, 变量)：保留完整选择集与 fragment，根字段加 `@skip(if: true)`。"""
    insertions = list(iter_root_fields(document))
    if not insertions:
        return None, {}
    query = document
    for _, position in sorted(insertions, key=lambda item: item[1], reverse=True):
        query = query[:position] + " @skip(if: true)" + query[position:]
    return query, variable_placeholders(document)


def collect_documents():
    """返回 {document: (源码路径, operation, [顶层字段...])}，同一份文档只探测一次。

    不能按 (operation, field) 去重：同一 root field 在不同文档里可能选不同的嵌套字段
    （catalog.rs 的 CourseLearning 与 CourseLearningDetail、courses/events 两处
    MyEnrollment），只留第一份会漏掉客户端真正提交的那套选择集（#1202 Codex P2）。
    """
    found = {}
    for path, document in iter_documents():
        match = OPERATION_RE.match(document)
        if not match:
            continue
        fields = top_level_fields(document)
        if not fields:
            continue
        found.setdefault(document, (path, match.group(1), fields))
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


def probe(endpoint, document, timeout):
    """返回 (状态, 说明)。状态：exists / missing / error。

    提交完整文档（嵌套选择集、变量、fragment 都在），根字段用 `@skip(if: true)` 包住：
    服务端照样做整份 schema 校验，但不会执行 resolver，因此嵌套字段缺失同样会被拦下。
    """
    query, variables = build_probe(document)
    if query is None:
        return "error", "无法定位操作选择集第一层字段，不能安全地加 @skip(if: true)（fail-closed）"
    request = urllib.request.Request(
        endpoint,
        data=json.dumps({"query": query, "variables": variables}).encode("utf-8"),
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
        # 字段校验错误（含嵌套字段）说明 schema 与本包不兼容；变量/鉴权/参数错误不算。
        if "Cannot query field" in message or "Unknown field" in message:
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

    documents = collect_documents()
    if not documents:
        return fail("没有从 crates/**/*.rs 提取到任何 GraphQL 文档——提取器失效，需人工复核")

    ordered = sorted(documents.items(), key=lambda item: (item[1][0], item[0]))
    field_pairs = {(operation, field) for _, operation, fields in documents.values() for field in fields}
    print(f"检查 {len(ordered)} 个 GraphQL 文档（{len(field_pairs)} 个顶层字段）：{endpoint}")

    missing = []
    errors = []
    for document, (path, operation, fields) in ordered:
        status, detail = probe(endpoint, document, timeout)
        label = f"{operation} {' '.join(fields)}"
        if status == "missing":
            missing.append((label, path, detail))
        elif status == "error":
            errors.append((label, path, detail))

    for label, path, detail in missing:
        print(f"✗ {label}（{path}）\n    {detail}", file=sys.stderr)
    for label, path, detail in errors:
        print(f"✗ {label}（{path}）探测失败：{detail}", file=sys.stderr)

    if missing:
        return fail(
            f"{len(missing)}/{len(ordered)} 份文档在生产后端不兼容——禁止出包。"
            "先部署后端到 main，或回退客户端改动（见 #1183）"
        )
    if errors:
        return fail(f"{len(errors)}/{len(ordered)} 份文档无法确认（fail-closed）——禁止出包")

    print(f"✓ {len(ordered)} 份文档（{len(field_pairs)} 个顶层字段）全部存在于 {endpoint}")
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
    # #1202：探测提交完整文档 + `@skip(if: true)`，嵌套字段缺失必须判 missing。
    import contextlib
    import io
    import tempfile
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    def squash(text):
        return " ".join(text.split())

    notification_document = (
        "query NotificationFeed($first: Int!, $after: String) {\n"
        "  notificationFeed(first: $first, after: $after) {\n"
        "    count\n"
        "    results { id type readAt title body targetType targetId }\n"
        "  }\n"
        "}"
    )
    probe_query, probe_variables = build_probe(notification_document)
    expect(
        "probe: full document + root @skip",
        squash(probe_query),
        squash(
            "query NotificationFeed($first: Int!, $after: String) {\n"
            "  notificationFeed(first: $first, after: $after) @skip(if: true) {\n"
            "    count\n"
            "    results { id type readAt title body targetType targetId }\n"
            "  }\n"
            "}"
        ),
    )
    expect("probe: scalar placeholder variables", probe_variables, {"first": 0, "after": ""})
    expect("probe: no synthetic __typename", "__typename" in probe_query, False)

    scalar_document = "mutation RevokeToken {\n  revokeToken\n}"
    expect(
        "probe: scalar root field",
        squash(build_probe(scalar_document)[0]),
        squash("mutation RevokeToken { revokeToken @skip(if: true) }"),
    )

    fragment_document = (
        "query GetCourse($id: ID!) {\n"
        "  getCourse(id: $id) {\n"
        "    ...CourseFields\n"
        "  }\n"
        "}\n\n"
        "fragment CourseFields on Course { id title }"
    )
    expect(
        "probe: keeps fragment definitions",
        squash(build_probe(fragment_document)[0]),
        squash(
            "query GetCourse($id: ID!) { getCourse(id: $id) @skip(if: true) { ...CourseFields } }\n\n"
            "fragment CourseFields on Course { id title }"
        ),
    )

    class ProbeHandler(BaseHTTPRequestHandler):
        requests = []

        def do_POST(self):
            length = int(self.headers.get("content-length", 0))
            body = json.loads(self.rfile.read(length))
            type(self).requests.append(body)
            query = body.get("query", "")
            if "targetType" in query:
                self._reply(
                    200,
                    {"errors": [{"message": 'Cannot query field "targetType" on type "Notification".'}]},
                )
            elif "checkInCode" in query:
                self._reply(
                    200,
                    {"errors": [{"message": 'Cannot query field "checkInCode" on type "Enrollment".'}]},
                )
            elif "missing_root" in query:
                self._reply(
                    200,
                    {"errors": [{"message": 'Cannot query field "missing_root" on type "RootQueryType".'}]},
                )
            elif "server_error" in query:
                self._reply(503, {"error": "service_unavailable"})
            elif "bad_envelope" in query:
                self._reply(200, {"ok": True})
            else:
                self._reply(200, {"data": {"ok_field": None}})

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
            ("exists", "query Ok($first: Int!) { ok_field(first: $first) { id } }", "exists"),
            ("missing root field", "query MissingRoot { missing_root { id } }", "missing"),
            ("nested field missing", notification_document, "missing"),
            ("http 503", "query ServerError { server_error { id } }", "error"),
            ("bad envelope", "query BadEnvelope { bad_envelope { id } }", "error"),
        ]
        for name, document, expected in probe_cases:
            status, _ = probe(endpoint, document, 5)
            expect(f"probe: {name}", status, expected)

        # 传输层断言：真实发出的请求带的是完整文档 + skip + 变量。
        first_request = ProbeHandler.requests[0]
        expect("probe: sends variables", first_request.get("variables"), {"first": 0})
        expect("probe: request carries @skip", "@skip(if: true)" in first_request.get("query", ""), True)
        expect("probe: request keeps nested selection", "ok_field(first: $first)" in first_request.get("query", ""), True)

        # #1202 门禁级回归：root field 存在、嵌套字段缺失 → not compatible，非零退出。
        notification_source = '''
const NOTIFICATION_FEED_QUERY: &str = r#"
query NotificationFeed($first: Int!, $after: String) {
  notificationFeed(first: $first, after: $after) {
    count
    results { id type targetType targetId }
  }
}
"#;
'''
        compatible_source = notification_source.replace(" targetType targetId", "")
        # 同一个 root field 的两套选择集：短的那份在前也不能让长的被跳过（Codex P2）。
        short_enrollment = '''
const SHORT_ENROLLMENT: &str = r#"
query MyEnrollment($kind: String!, $offeringId: ID!) {
  myEnrollment(kind: $kind, offeringId: $offeringId) { id status }
}
"#;
'''
        long_enrollment = '''
const LONG_ENROLLMENT: &str = r#"
query MyEnrollment($kind: String!, $offeringId: ID!) {
  myEnrollment(kind: $kind, offeringId: $offeringId) { id status checkInCode }
}
"#;
'''

        def run_gate(sources):
            with tempfile.TemporaryDirectory() as tmp:
                for name, source_text in sources.items():
                    path = pathlib.Path(tmp, "crates", "platform", "src", name)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(source_text, encoding="utf-8")
                original_root = globals()["ROOT"]
                globals()["ROOT"] = pathlib.Path(tmp)
                out, err = io.StringIO(), io.StringIO()
                try:
                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                        status = run_check(endpoint, 5)
                finally:
                    globals()["ROOT"] = original_root
                return status, out.getvalue(), err.getvalue()

        status, _, err = run_gate({"notifications.rs": notification_source})
        expect("gate: nested field missing is not compatible", status, 1)
        expect("gate: error names the nested field", "targetType" in err, True)
        expect("gate: blocks the release", "禁止出包" in err, True)

        status, out, _ = run_gate({"notifications.rs": compatible_source})
        expect("gate: compatible document passes", status, 0)
        expect("gate: reports document coverage", "✓ 1 份文档（1 个顶层字段）全部存在于" in out, True)

        status, out, err = run_gate({"a_short_enrollment.rs": short_enrollment, "b_long_enrollment.rs": long_enrollment})
        expect("gate: probes every document of a root field", "检查 2 个 GraphQL 文档（1 个顶层字段）" in out, True)
        expect("gate: second selection set is checked", status, 1)
        expect("gate: names the alternate selection field", "checkInCode" in err, True)
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
