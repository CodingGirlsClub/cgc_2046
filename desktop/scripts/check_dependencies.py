#!/usr/bin/env python3
"""依赖边界检查（story 1.10）。

断言三条禁止边（脊柱 AD-1）：
1. domain crate 互引（account/events/courses/agent_chat）；
2. cgc-platform 反向依赖任何 cgc-platform-* 适配 crate；
3. cgc-platform 反向依赖 domain 实现 crate。

用法：
  python3 scripts/check_dependencies.py              # 检查真实 cargo metadata
  python3 scripts/check_dependencies.py --self-test  # 用假图验证三类违规都能报出
"""

import json
import subprocess
import sys

DOMAINS = {"cgc-account", "cgc-events", "cgc-courses", "cgc-agent-chat"}
PLATFORM = "cgc-platform"


def internal_graph(packages):
    graph = {}
    for package in packages:
        deps = {
            dependency["name"]
            for dependency in package.get("dependencies", [])
            if dependency["name"].startswith("cgc-")
        }
        graph[package["name"]] = deps
    return graph


def violations(graph):
    found = []
    for name, deps in graph.items():
        if name in DOMAINS:
            for dep in deps & (DOMAINS - {name}):
                found.append(("DOMAIN_DEP", name, dep))
        if name == PLATFORM:
            for dep in deps:
                if dep.startswith("cgc-platform-"):
                    found.append(("PLATFORM_REVERSE", name, dep))
                elif dep in DOMAINS or dep == "cgc-desktop-app":
                    found.append(("PLATFORM_IMPL", name, dep))
    return found


def package(name, deps):
    return {"name": name, "dependencies": [{"name": dep} for dep in deps]}


def self_test():
    fixtures = [
        (
            "domain interdependency",
            [package("cgc-events", ["cgc-platform", "cgc-account"])],
            "DOMAIN_DEP",
        ),
        (
            "platform reverse adapter",
            [package("cgc-platform", ["cgc-platform-macos"])],
            "PLATFORM_REVERSE",
        ),
        (
            "platform reverse domain impl",
            [package("cgc-platform", ["cgc-courses"])],
            "PLATFORM_IMPL",
        ),
    ]
    for label, packages, expected in fixtures:
        found = violations(internal_graph(packages))
        if not any(kind == expected for kind, _, _ in found):
            print(f"SELF-TEST FAIL: {label} not reported (got {found})")
            return 1
        kind, src, dst = next(item for item in found if item[0] == expected)
        print(f"SELF-TEST OK: {label} -> {kind} {src} -> {dst}")
    clean = internal_graph(
        [
            package("cgc-desktop-app", ["cgc-events", "cgc-platform"]),
            package("cgc-events", ["cgc-platform"]),
            package("cgc-platform", []),
            package("cgc-platform-macos", ["cgc-platform"]),
        ]
    )
    if violations(clean):
        print(f"SELF-TEST FAIL: clean graph reported {violations(clean)}")
        return 1
    print("SELF-TEST OK: clean graph has no violations")
    return 0


def real_check():
    raw = subprocess.check_output(
        ["cargo", "metadata", "--no-deps", "--format-version", "1"],
        text=True,
    )
    graph = internal_graph(json.loads(raw)["packages"])
    found = violations(graph)
    if found:
        for kind, src, dst in found:
            print(f"VIOLATION {kind}: {src} -> {dst}")
        return 1
    print(f"dependency boundaries OK ({len(graph)} internal crates)")
    for name in sorted(graph):
        print(f"  {name} -> {sorted(graph[name]) or '-'}")
    return 0


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv else real_check())
