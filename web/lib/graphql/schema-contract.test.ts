import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { buildSchema, Kind, print, validate, type DocumentNode } from "graphql";
import { CHECK_IN_ENROLLMENT } from "@/lib/graphql/attendance";
import { MY_ENROLLMENTS } from "@/lib/graphql/participations";
import { GET_INITIATIVE, LIST_INITIATIVES } from "@/lib/graphql/admin";
import { INITIATIVE_MOUNT_PREVIEW } from "@/lib/graphql/initiatives";

/**
 * 手写 GraphQL 文档 ↔ 后端 SDL 的契约守卫。
 *
 * 手写 mutation/query 的字段形状没有 codegen 兜底：后端改 object 形状（或我们把
 * 生成 mutation 的 `{result, errors}` 信封形状套到手写扁平原 payload 上）时，
 * 前端只会在运行时静默拿到 undefined——`{result, errors}` 与
 * `{enrollmentId, checkedInAt, method, errors}` 的错配曾导致「核销成功却显示失败」。
 *
 * 断言：文档选择集 ⊆ SDL 里同名字段集（含嵌套 errors 的 message/code），
 * 且 SDL 里没有的键（例如扁平 payload 上的 `result`）不得出现在选择集里。
 * 真源是 `backend/priv/graphql/schema.graphql`（后端再生成并由其测试守卫新鲜度）。
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const SDL_PATH = resolve(HERE, "../../../backend/priv/graphql/schema.graphql");

/** 从 SDL 抽出 object/input 类型的字段名集合（只做字段集比对，不建完整 AST 索引） */
function objectFields(sdl: string, typeName: string): Set<string> {
  const match = sdl.match(
    new RegExp(`^(?:type|input)\\s+${typeName}\\s*(?:implements[^{]*)?\\{([\\s\\S]*?)^\\}`, "m"),
  );
  const fields = new Set<string>();
  if (!match) return fields;
  for (const line of match[1].split("\n")) {
    const name = line.trim().match(/^([A-Za-z_][A-Za-z0-9_]*)\s*[:(]/);
    if (name) fields.add(name[1]);
  }
  return fields;
}

/**
 * 收集文档首个操作的根字段名与其下的全部字段路径（相对根字段，点号连接）。
 * 例：`mutation { checkInEnrollment(...) { enrollmentId errors { code } } }`
 * → { root: "checkInEnrollment", paths: ["enrollmentId", "errors", "errors.code"] }
 */
function rootFieldPaths(doc: { definitions: readonly unknown[] }): {
  root: string;
  paths: string[];
} {
  const paths: string[] = [];
  const walk = (selectionSet: { selections?: unknown[] } | undefined, prefix: string) => {
    for (const raw of selectionSet?.selections ?? []) {
      const node = raw as {
        kind?: string;
        name?: { value?: string };
        selectionSet?: { selections?: unknown[] };
      };
      if (node.kind !== "Field" || !node.name?.value) continue;
      const path = prefix ? `${prefix}.${node.name.value}` : node.name.value;
      paths.push(path);
      walk(node.selectionSet, path);
    }
  };

  for (const definition of doc.definitions) {
    const op = definition as {
      kind?: string;
      selectionSet?: { selections?: unknown[] };
    };
    if (op.kind !== "OperationDefinition") continue;
    const first = (op.selectionSet?.selections ?? [])[0] as
      | { name?: { value?: string }; selectionSet?: { selections?: unknown[] } }
      | undefined;
    if (!first?.name?.value) continue;
    walk(first.selectionSet, "");
    return { root: first.name.value, paths };
  }
  return { root: "", paths: [] };
}

describe("手写 GraphQL 文档 ↔ SDL 契约", () => {
  const sdl = readFileSync(SDL_PATH, "utf8");

  it("checkInEnrollment 选择集 ⊆ SDL CheckInEnrollmentPayload，且不含生成信封的 result 键", () => {
    const { root, paths } = rootFieldPaths(CHECK_IN_ENROLLMENT);
    const payloadFields = objectFields(sdl, "CheckInEnrollmentPayload");
    const errorFields = objectFields(sdl, "MutationError");

    expect(root).toBe("checkInEnrollment");
    expect(payloadFields.size).toBeGreaterThan(1);
    expect(errorFields.size).toBeGreaterThan(0);

    for (const path of paths) {
      const [head, second] = path.split(".");
      if (!second) {
        // 根字段的非叶子选择必须是 payload 自己的字段
        // （`result` 这类生成信封键在 SDL 的扁平 payload 里不存在）
        expect(payloadFields, `SDL CheckInEnrollmentPayload 缺字段 ${head}`).toContain(head);
        continue;
      }
      if (head === "errors") {
        expect(errorFields, `SDL MutationError 缺字段 ${second}`).toContain(second);
      }
    }

    // 反向钉子：扁平 payload 上不得出现 {result, errors} 信封的 result
    expect(paths.some((p) => p === "result" || p.startsWith("result."))).toBe(false);
  });

  it("myEnrollments 选择集 ⊆ SDL Enrollment，且含 checkInCode", () => {
    const { root, paths } = rootFieldPaths(MY_ENROLLMENTS);
    const enrollmentFields = objectFields(sdl, "Enrollment");

    expect(root).toBe("myEnrollments");
    expect(enrollmentFields, "SDL Enrollment 缺 checkInCode").toContain("checkInCode");

    // myEnrollments 走 KeysetPage 包装（count/results），码在 results 子选择里
    const codePath = paths.find((p) => p === "checkInCode" || p.endsWith(".checkInCode"));
    expect(codePath, "MY_ENROLLMENTS 未选择 checkInCode").toBeDefined();
  });

  it("initiativeMountPreview 选择集 ⊆ SDL InitiativeMountPreview / InitiativeRulePreview（#596）", () => {
    const { root, paths } = rootFieldPaths(INITIATIVE_MOUNT_PREVIEW);
    const previewFields = objectFields(sdl, "InitiativeMountPreview");
    const ruleFields = objectFields(sdl, "InitiativeRulePreview");

    expect(root).toBe("initiativeMountPreview");
    expect(previewFields.size).toBeGreaterThan(1);
    expect(ruleFields.size).toBeGreaterThan(0);

    for (const path of paths) {
      const [head, second] = path.split(".");
      expect(previewFields, `SDL InitiativeMountPreview 缺字段 ${head}`).toContain(head);
      if (second) {
        expect(ruleFields, `SDL InitiativeRulePreview 缺字段 ${second}`).toContain(second);
      }
    }

    // 权限不扩大的结构性防线：公开类型不得出现规则字段
    for (const publicType of ["PublicInitiative", "PublicInitiativeCard"]) {
      expect(objectFields(sdl, publicType)).not.toContain("rules");
    }
  });

  /**
   * #595：挂载场读面。列表 query 刻意不取 mountedEvents（否则 admin 列表页
   * N+1），详情 query 取；选择集字段必须都在 SDL 的 AdminInitiativeMountedEvent 上。
   */
  it("Initiatives 文档：列表不取 mountedEvents，详情取且字段 ⊆ SDL", () => {
    expect(objectFields(sdl, "AdminInitiative")).toContain("mountedEvents");
    expect(print(LIST_INITIATIVES)).not.toContain("mountedEvents");

    const detail = print(GET_INITIATIVE);
    expect(detail).toContain("mountedEvents");

    const mountFields = objectFields(sdl, "AdminInitiativeMountedEvent");
    expect(mountFields.size).toBeGreaterThan(10);

    const selected = detail.match(/mountedEvents\s*\{([^}]*)\}/)?.[1].split(/\s+/).filter(Boolean) ?? [];
    expect(selected.length).toBeGreaterThan(10);
    for (const field of selected) {
      expect(mountFields, `SDL AdminInitiativeMountedEvent 缺字段 ${field}`).toContain(field);
    }
  });
});

/**
 * 全部手写文档 ↔ 后端 schema 的整体校验（graphql-js validate）：字段不存在、操作类型放错（query / mutation）、
 * 参数名不对都会在这里红。后台「单人重发」曾以 mutation 调用一个定义在 Query 上的字段，界面测试 mock 掉了
 * 请求层，上线后才会发现（2026-09-26）。
 */
describe("全部手写文档 ↔ 后端 SDL 校验", () => {
  it("lib/graphql 下每个导出的 DocumentNode 都能通过后端 schema 校验", () => {
    const schema = buildSchema(readFileSync(SDL_PATH, "utf8"));
    const modules = import.meta.glob(["./*.ts", "!./*.test.ts"], { eager: true }) as Record<
      string,
      Record<string, unknown>
    >;
    const failures: string[] = [];
    let checked = 0;

    for (const [path, exports] of Object.entries(modules)) {
      for (const [name, value] of Object.entries(exports)) {
        if ((value as { kind?: unknown } | null)?.kind !== Kind.DOCUMENT) continue;
        checked += 1;
        const key = `${path.slice(2)}:${name}`;
        const errors = validate(schema, value as DocumentNode).map((error) => error.message);
        if (errors.length > 0) failures.push(`${key}: ${errors.join(" | ")}`);
      }
    }

    expect(checked).toBeGreaterThan(100);
    expect(failures).toEqual([]);
  });
});
