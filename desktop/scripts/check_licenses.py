#!/usr/bin/env python3
"""依赖许可门禁与 SBOM（story 1.6 / ADR-0031）。

规则来源 docs/开源合规/依赖引入规则.md：白名单（宽松 + 弱 copyleft）与黑名单兜底；
SPDX OR/AND 语义：OR 任一允许分支即放行，AND 需全部允许。缺失 license 字段 fail-closed。

两段扫描：
  1. Cargo 依赖图（cargo metadata，含 test-support 特性）；
  2. 运行时 npm 包清单 `scripts/npm_licenses.json`——客户端通过 npm 安装的外部 ACP agent
     及其传递依赖不进入 Cargo 依赖图，必须单独登记（ADR-0031：openma DeepSeek Harness ACP）。

用法：
  python3 scripts/check_licenses.py              # 扫描 + 写 target/sbom.cdx.json
  python3 scripts/check_licenses.py --self-test  # 假 fixture 验证门禁会红
  python3 scripts/check_licenses.py --sbom path  # 指定 SBOM 输出
"""

import json
import pathlib
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

# 运行时 npm 包清单（见文件头说明）：与 Cargo 扫描共用同一套白名单。
NPM_MANIFEST_NAME = "npm_licenses.json"


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


def npm_manifest_path():
    return pathlib.Path(__file__).resolve().with_name(NPM_MANIFEST_NAME)


def load_npm_manifest(path=None):
    """读取运行时 npm 包清单；缺失或非法 JSON 由调用方按违规处理（fail-closed）。"""
    manifest_path = pathlib.Path(path) if path else npm_manifest_path()
    with open(manifest_path, encoding="utf-8") as handle:
        return json.load(handle)


def scan_external_npm(manifest):
    """校验运行时 npm 包清单：schema、根包登记、字段完整、无重复、许可白名单。"""
    violations = []
    if not isinstance(manifest, dict):
        return [("<npm manifest>", "?", "MALFORMED-MANIFEST")]
    if manifest.get("schema_version") != 1:
        violations.append(("<npm manifest>", "?", "UNSUPPORTED-SCHEMA"))
    packages = manifest.get("packages")
    if not isinstance(packages, list) or not packages:
        return violations + [("<npm manifest>", "?", "EMPTY-MANIFEST")]

    rows = {}
    for package in packages:
        if not isinstance(package, dict):
            violations.append(("<npm manifest>", "?", "MALFORMED-ENTRY"))
            continue
        name = package.get("name")
        version = package.get("version")
        if not isinstance(name, str) or not name or not isinstance(version, str) or not version:
            violations.append((str(name or "<unknown>"), str(version or "?"), "MALFORMED-ENTRY"))
            continue
        key = (name, version)
        if key in rows:
            violations.append((name, version, "DUPLICATE-ENTRY"))
            continue
        rows[key] = package
        license_expr = package.get("license")
        if not isinstance(license_expr, str) or not license_expr:
            violations.append((name, version, "NO-SPDX-ID"))
        elif not license_allowed(license_expr):
            violations.append((name, version, license_expr))

    roots = manifest.get("roots")
    if not isinstance(roots, list) or not roots:
        violations.append(("<npm manifest>", "?", "MISSING-ROOTS"))
    else:
        for root in roots:
            if (
                not isinstance(root, dict)
                or not isinstance(root.get("name"), str)
                or not isinstance(root.get("version"), str)
                or not root.get("name")
                or not root.get("version")
            ):
                violations.append(("<npm manifest>", "?", "MALFORMED-ROOT"))
            elif (root["name"], root["version"]) not in rows:
                violations.append((root["name"], root["version"], "ROOT-NOT-REGISTERED"))

    bundled = manifest.get("bundled_runtime")
    if bundled is not None:
        if (
            not isinstance(bundled, dict)
            or not isinstance(bundled.get("name"), str)
            or not isinstance(bundled.get("version"), str)
            or not bundled.get("name")
            or not bundled.get("version")
        ):
            violations.append(("<npm manifest>", "?", "MALFORMED-BUNDLED-RUNTIME"))
        else:
            license_expr = bundled.get("license")
            if not isinstance(license_expr, str) or not license_expr:
                violations.append((bundled["name"], bundled["version"], "NO-SPDX-ID"))
            elif not license_allowed(license_expr):
                violations.append((bundled["name"], bundled["version"], license_expr))
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
    # 显式带上 test-support 依赖面：gpui-pre 的该 feature 会引入
    # proptest/postage 等测试依赖，默认 metadata 看不到它们，门禁会漏扫。
    raw = subprocess.check_output(
        [
            "cargo",
            "metadata",
            "--format-version",
            "1",
            "--features",
            "gpui-kit/test-support",
        ],
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

    def npm_manifest(packages, roots=None, bundled=None):
        return {
            "schema_version": 1,
            "roots": roots
            if roots is not None
            else [{"name": "@openma/deepseek-harness-acp", "version": "0.4.41"}],
            "bundled_runtime": bundled
            if bundled is not None
            else {"name": "@deepseek-ai/dsh", "version": "0.2.1-rc.5", "license": "MIT"},
            "packages": packages,
        }

    npm_fixtures = [
        (
            "npm-good",
            npm_manifest(
                [
                    {
                        "name": "@openma/deepseek-harness-acp",
                        "version": "0.4.41",
                        "license": "Apache-2.0",
                    },
                    {"name": "tar", "version": "7.5.22", "license": "BlueOak-1.0.0"},
                ]
            ),
            False,
        ),
        (
            "npm-gpl",
            npm_manifest(
                [{"name": "bad", "version": "1.0.0", "license": "GPL-2.0-only"}],
                roots=[{"name": "bad", "version": "1.0.0"}],
            ),
            True,
        ),
        ("npm-empty", npm_manifest([]), True),
        (
            "npm-root-missing",
            npm_manifest(
                [{"name": "tar", "version": "7.5.22", "license": "BlueOak-1.0.0"}],
                roots=[{"name": "@openma/deepseek-harness-acp", "version": "0.4.41"}],
            ),
            True,
        ),
        (
            "npm-missing-license",
            npm_manifest(
                [{"name": "@openma/deepseek-harness-acp", "version": "0.4.41"}],
            ),
            True,
        ),
        (
            "npm-bundled-gpl",
            npm_manifest(
                [{"name": "@openma/deepseek-harness-acp", "version": "0.4.41", "license": "Apache-2.0"}],
                bundled={"name": "@deepseek-ai/dsh", "version": "0.2.1-rc.5", "license": "GPL-2.0-only"},
            ),
            True,
        ),
    ]
    for label, manifest, expect_violation in npm_fixtures:
        found = scan_external_npm(manifest)
        if bool(found) != expect_violation:
            print(f"SELF-TEST FAIL: {label} expected violation={expect_violation}, got {found}")
            failures += 1
        else:
            print(f"SELF-TEST OK: {label} -> {'red' if found else 'green'}")

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
    try:
        npm_manifest = load_npm_manifest()
    except (OSError, ValueError) as error:
        print(f"VIOLATION {NPM_MANIFEST_NAME}: {error}")
        return 1
    npm_violations = scan_external_npm(npm_manifest)
    if violations or npm_violations:
        for name, version, license_expr in violations:
            print(f"VIOLATION {name} {version}: {license_expr}")
        for name, version, license_expr in npm_violations:
            print(f"VIOLATION npm {name} {version}: {license_expr}")
        print(f"✗ {len(violations) + len(npm_violations)} license violations")
        return 1
    print(f"✓ {len(packages)} Rust packages license-compatible with AGPL-3.0")
    print(
        f"✓ {len(npm_manifest['packages'])} runtime npm packages license-compatible with AGPL-3.0"
    )
    output = "target/sbom.cdx.json"
    if "--sbom" in args:
        output = args[args.index("--sbom") + 1]
    version = body["packages"][0].get("version", "0.0.0")
    bom = sbom(packages, version)
    # 门禁可能在任何 cargo 构建之前跑（例如发布流水线只做打包），此时 target/ 还不存在：
    # 不建目录会 FileNotFoundError 把门禁本身判红，掩盖真正的许可结论。
    pathlib.Path(output).parent.mkdir(parents=True, exist_ok=True)
    with open(output, "w", encoding="utf-8") as handle:
        json.dump(bom, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"SBOM: {output} ({len(bom['components'])} components)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
