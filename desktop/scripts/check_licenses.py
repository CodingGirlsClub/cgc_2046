#!/usr/bin/env python3
"""Rust 依赖许可门禁与 SBOM（story 1.6）。

规则来源 docs/开源合规/依赖引入规则.md：白名单（宽松 + 弱 copyleft）与黑名单兜底；
SPDX OR/AND 语义：OR 任一允许分支即放行，AND 需全部允许。缺失 license 字段 fail-closed。

用法：
  python3 scripts/check_licenses.py              # 扫描 + 写 target/sbom.cdx.json
  python3 scripts/check_licenses.py --self-test  # 假 fixture 验证门禁会红
  python3 scripts/check_licenses.py --sbom path  # 指定 SBOM 输出
"""

import json
import re
import subprocess
import sys

ALLOWED = {
    "MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "0BSD", "CC0-1.0",
    "Unlicense", "BlueOak-1.0.0", "MIT-0", "Python-2.0", "Zlib",
    "MPL-2.0", "LGPL-3.0-only", "LGPL-3.0-or-later", "EPL-2.0",
    # Rust 生态常见、OSI/FSF 认可的宽松许可（AGPL-3.0 兼容）：
    # Unicode-3.0（ICU4X/IDNA）、CDLA-Permissive-2.0（根证书数据）。
    "Unicode-3.0", "CDLA-Permissive-2.0", "NCSA",
}
ALLOWED_EXCEPTIONS = {"LLVM-exception", "Unicode-3.0"}
BLACKLIST = ["gpl-2-0", "sspl", "busl", "elastic", "proprietary", "commercial"]


def normalize(value):
    return re.sub(r"[^a-z0-9]", "-", value.lower())


def blacklisted(candidate):
    norm = normalize(candidate)
    return any(bad in norm for bad in BLACKLIST)


def preprocess(expr):
    # `Apache-2.0 WITH LLVM-exception` 视作 Apache-2.0（例外本身不改变兼容性）。
    for exception in sorted(ALLOWED_EXCEPTIONS):
        expr = expr.replace(f" WITH {exception}", "")
    return expr


def tokenize(expr):
    expr = preprocess(expr)
    expr = expr.replace("(", " ( ").replace(")", " ) ")
    return [token if token != "/" else "OR" for token in expr.split() if token]


def atom_allowed(token):
    if token in {"(", ")", "AND", "OR", "WITH"}:
        return False
    if token.endswith("+"):
        return False
    return any(part.strip() in ALLOWED for part in token.split("/"))


def license_allowed(expr):
    tokens = tokenize(expr)
    if not tokens:
        return False
    at = 0

    def parse_or():
        nonlocal at
        value = parse_and()
        while at < len(tokens) and tokens[at].upper() == "OR":
            at += 1
            value = parse_and() or value
        return value

    def parse_and():
        nonlocal at
        value = parse_atom()
        while at < len(tokens) and tokens[at].upper() == "AND":
            at += 1
            value = parse_atom() and value
        return value

    def parse_atom():
        nonlocal at
        if at >= len(tokens):
            raise ValueError("missing operand")
        token = tokens[at]
        at += 1
        if token == "(":
            value = parse_or()
            if at >= len(tokens) or tokens[at] != ")":
                raise ValueError("unbalanced")
            at += 1
            return value
        if token == ")" or token.upper() in {"AND", "OR", "WITH"}:
            raise ValueError("malformed")
        return atom_allowed(token)

    try:
        value = parse_or()
        if at != len(tokens):
            return False
        return bool(value)
    except ValueError:
        return False


def scan(packages):
    violations = []
    for package in packages:
        license_expr = package.get("license")
        if not license_expr:
            if package.get("license_file"):
                # 有 license 文件但无 SPDX 声明：规则要求显式 ID，fail-closed 并提示人审。
                violations.append((package["name"], package.get("version", "?"), "NO-SPDX-ID"))
            else:
                violations.append((package["name"], package.get("version", "?"), "UNKNOWN"))
            continue
        if not license_allowed(license_expr):
            violations.append((package["name"], package.get("version", "?"), license_expr))
    return violations


def sbom(packages, version):
    components = []
    for package in sorted(packages, key=lambda item: (item["name"], item.get("version", ""))):
        license_expr = package.get("license")
        entry = {
            "type": "library",
            "name": package["name"],
            "version": package.get("version", "0"),
        }
        if license_expr:
            entry["licenses"] = [{"expression": license_expr}]
        components.append(entry)
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "name": "cgc-desktop",
                "version": version,
            }
        },
        "components": components,
    }


def metadata():
    raw = subprocess.check_output(
        ["cargo", "metadata", "--format-version", "1"],
        text=True,
    )
    return json.loads(raw)


def self_test():
    fixtures = [
        ({"name": "good", "version": "1.0.0", "license": "MIT"}, False),
        ({"name": "bad", "version": "1.0.0", "license": "GPL-2.0-only"}, True),
        ({"name": "or", "version": "1.0.0", "license": "MIT OR GPL-2.0-only"}, False),
        ({"name": "and", "version": "1.0.0", "license": "MIT AND GPL-2.0-only"}, True),
        ({"name": "missing", "version": "1.0.0"}, True),
        ({"name": "unknown", "version": "1.0.0", "license": "Foo-1.0"}, True),
        (
            {"name": "unicode", "version": "1.0.0", "license": "(MIT OR Apache-2.0) AND Unicode-3.0"},
            False,
        ),
        (
            {"name": "llvm", "version": "1.0.0", "license": "Apache-2.0 WITH LLVM-exception OR MIT"},
            False,
        ),
        ({"name": "cdla", "version": "1.0.0", "license": "CDLA-Permissive-2.0"}, False),
    ]
    failures = 0
    for package, expect_violation in fixtures:
        found = scan([package])
        if bool(found) != expect_violation:
            print(f"SELF-TEST FAIL: {package} expected violation={expect_violation}, got {found}")
            failures += 1
        else:
            print(f"SELF-TEST OK: {package['name']} -> {'red' if found else 'green'}")
    if failures:
        return 1
    bom = sbom(
        [{"name": "good", "version": "1.0.0", "license": "MIT"}],
        "0.0.1",
    )
    if bom["bomFormat"] != "CycloneDX" or len(bom["components"]) != 1:
        print(f"SELF-TEST FAIL: bad SBOM {bom}")
        return 1
    print("SELF-TEST OK: SBOM shape")
    return 0


def main():
    args = sys.argv[1:]
    if "--self-test" in args:
        return self_test()
    body = metadata()
    # 第一方 workspace crate（source 为 null）不参与第三方许可扫描。
    packages = [
        package
        for package in body["packages"]
        if package.get("source") is not None
    ]
    violations = scan(packages)
    if violations:
        for name, version, license_expr in violations:
            print(f"VIOLATION {name} {version}: {license_expr}")
        print(f"✗ {len(violations)} license violations")
        return 1
    print(f"✓ {len(packages)} Rust packages license-compatible with AGPL-3.0")
    output = "target/sbom.cdx.json"
    if "--sbom" in args:
        output = args[args.index("--sbom") + 1]
    version = body["packages"][0].get("version", "0.0.0")
    bom = sbom(packages, version)
    with open(output, "w", encoding="utf-8") as handle:
        json.dump(bom, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"SBOM: {output} ({len(bom['components'])} components)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
