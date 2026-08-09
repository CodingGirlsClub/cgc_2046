# Plan 002: 让零导流产物门禁真实、完整且 fail-closed

> **Executor instructions**: 逐步执行并在每一步运行验证。发现 Scope 外命中时只报告相对路径和禁词类型，
> 不要删业务文案来“修测试”。遇到 STOP 条件立即停止，不要弱化红线。
> 完成后更新 `advisor-plans/README.md` 的状态行，除非 reviewer 明确由其维护。
>
> **Drift check（第一条命令）**:
> `git diff --stat f1fd4aa..HEAD -- miniprogram/scripts/check-no-diversion.mjs miniprogram/tests .github/workflows/ci.yml`
> 如果实现自本方案编写后改变，先对照 “Current state”；关键假设不一致即 STOP。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: correctness / security
- **Planned at**: commit `f1fd4aa`, 2026-08-09

## Why this matters

零导流是抖音/小红书裁剪端的合规红线，CI 注释还声称检查是 escape-aware。
当前解码分支必然抛错后回退原文，缺构建目录或扫描零文件也会成功，且模板/JSON/样式从未扫描。
本方案把“检查通过”收紧为可证明的命题：两个目标目录都存在、有文本产物、所有相关产物经安全解码后
无禁词；任何前置条件缺失都红灯。

## Current state

- `miniprogram/scripts/check-no-diversion.mjs:14-22` 当前禁词与错误解码：

  ```js
  const BANNED = ["微信", "WeChat", "OpenClacky", "加我", "二维码", "口令"];
  function decode(raw) {
    try {
      return raw.encode("utf-8").decode("unicode_escape");
    } catch {
      return raw;
    }
  }
  ```

  JavaScript string 没有 `encode`/`decode`，所以 escape 文本保持原样。
- `miniprogram/scripts/check-no-diversion.mjs:25-33` 只收集 `.js`；`:46-50` 对缺目录/零 JS 输出成功。
- 既有裁剪产物包含 `.js`、`.sjs`、`.json`、`.ttml`、`.ttss`、`.xhsml`、`.css`、`.txt`；
  文案可能出现在 JS 以外。
- `.github/workflows/ci.yml:99-105` 的顺序已正确：先三端 build，再 `pnpm check:diversion`。
  本方案无需改 workflow，只修被调用程序和回归测试。
- `miniprogram/tests/domain.test.ts:1-10` 使用 `node:test` + `node:assert/strict`；新增 `.test.ts`
  会被当前 `pnpm test:unit` glob 自动执行。
- 红线范围不变：不得删减 `BANNED`，也不得把抖音/小红书的本端正常平台文案误当跨端导流。

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| 进入包目录 | `cd miniprogram` | 当前目录以 `/miniprogram` 结尾 |
| 定向测试 | `node --experimental-strip-types --test tests/diversion-policy.test.ts` | exit 0；全部 fixture 通过 |
| 全量 unit | `pnpm test:unit` | exit 0；既有 domain + diversion tests 通过 |
| 构建抖音 | `pnpm build:tt` | exit 0；`dist/tt` 有产物 |
| 构建小红书 | `pnpm build:xhs` | exit 0；`dist/xhs` 有产物 |
| 合规检查 | `pnpm check:diversion` | exit 0；两个平台都报告扫描了非零文件 |
| 类型检查 | `pnpm typecheck` | exit 0，无错误 |

## Scope

**In scope**:

- `miniprogram/scripts/check-no-diversion.mjs`
- `miniprogram/scripts/diversion-policy.mjs`（创建）
- `miniprogram/tests/diversion-policy.test.ts`（创建）
- `advisor-plans/README.md`（只更新状态行）

**Out of scope**:

- `.github/workflows/ci.yml`：当前 build→scan 顺序已足够。
- `miniprogram/src/**` 业务/UI 文案；fixture 暴露现有命中时先报告，不在本方案删源码。
- 修改禁词集合、降低大小写匹配、忽略 common/vendor chunk 或只扫描一个平台。
- 微信全量端 `dist/weapp`；零导流断言只针对 `tt`、`xhs`。
- `miniprogram/project.config.json`、真实 AppID、secret、token、`.env`。

## Git workflow

- Branch: `advisor/002-diversion-gate-fail-closed`
- 建议单一提交：`fix(miniprogram): 零导流门禁改为 fail-closed`
- 未经 operator 指示不得 push 或开 PR。

## Steps

### Step 1: 提取可单测的安全文本策略

创建 `scripts/diversion-policy.mjs`，导出：

- `BANNED_TERMS`：保持当前六项，不减项。
- `TEXT_EXTENSIONS`：至少覆盖 `.js`、`.sjs`、`.json`、`.ttml`、`.ttss`、`.xhsml`、`.css`、`.txt`。
- `decodeTextEscapes(raw)`：只用明确 regex 转换 `\\uXXXX`、`\\u{...}` 和 `\\xNN`；
  最多重复两轮以覆盖双重转义。不得使用 `eval`、`Function`、JSON 包裹整文件或执行产物内容。
- `scanArtifactTree(dir)`：返回 `{ filesScanned, hits, error }`；目录缺失和零合格文件是结构化错误。
- 每个 hit 只含相对 file path 和命中的 term，不回显整行/整文件。

读取文件前可按扩展名过滤；若文件含 NUL byte，按非文本跳过并计数，不得把它算作“已扫描文本文件”。
同一 file/term 只报告一次。

**Verify**:

```bash
node --input-type=module -e "import { decodeTextEscapes } from './scripts/diversion-policy.mjs'; const x=decodeTextEscapes('\\u0057\\u0065\\u0043\\u0068\\u0061\\u0074'); if(x!=='WeChat') process.exit(1)"
```

预期：exit 0；没有执行输入字符串。

### Step 2: 用 fixture 先证明 fail-closed 边界

创建 `tests/diversion-policy.test.ts`，使用 `mkdtempSync` 创建系统临时目录，并在 `after` 中清理该精确临时目录。
至少覆盖：

1. 普通无禁词的 `.js`/`.json`/模板/样式组合通过，`filesScanned > 0`。
2. 中文原文命中。
3. ASCII term 大小写合同（保持当前精确大小写；若产品要大小写不敏感，STOP 由 human 决定）。
4. `\\uXXXX` 中文/ASCII 命中。
5. `\\u{...}` 与 `\\xNN` 命中。
6. 双重转义命中。
7. 禁词只存在 `.json`、`.ttml`、`.xhsml` 或 `.css` 时仍命中。
8. 目录不存在返回错误。
9. 目录存在但没有合格文本文件返回错误。
10. 不命中内容只返回路径/term，不回显文件正文。

测试 fixture 可包含禁词；它不是发布产物。不要在 repo 中创建持久 `dist` fixture。

**Verify**:

```bash
node --experimental-strip-types --test tests/diversion-policy.test.ts
```

预期：exit 0，至少上述十类合同全部通过。

### Step 3: 把 CLI 改成两端独立 fail-closed

重写 `scripts/check-no-diversion.mjs` 为薄 CLI：

- 对 `dist/tt`、`dist/xhs` 各调用一次 `scanArtifactTree`。
- 任一目录缺失、无文本产物、读取失败或有 hit：整体 exit 1。
- 成功输出必须包含每端非零 `filesScanned`，文案不要再写“js”。
- 失败报告只列相对文件、term 和结构错误；不得打印文件内容。
- 禁止用 `catch { return raw }` 把解码/读取异常转为成功。
- 保留 shebang；直接 import policy module，不复制第二份规则。

**Verify**:

```bash
tmp_root="$(mktemp -d)"
MISSING_ARTIFACT_DIR="$tmp_root/not-built" node --input-type=module -e "import { scanArtifactTree } from './scripts/diversion-policy.mjs'; const r=scanArtifactTree(process.env.MISSING_ARTIFACT_DIR); if(!r.error || r.filesScanned!==0) process.exit(1)"
rmdir "$tmp_root"
```

预期：两条命令 exit 0；缺失目录被明确识别为错误且文件数为 0。CLI 自身仍应根据脚本位置定位项目 root，
不要改为根据 cwd 猜路径。

### Step 4: 用新鲜三端产物验证真实门禁

```bash
pnpm build:tt
pnpm build:xhs
pnpm check:diversion
pnpm test:unit
pnpm typecheck
git diff --check
git status --short
```

**Verify**: 所有检查 exit 0；合规命令对 tt/xhs 各报告非零文本文件数；`git status --short`
只新增/修改 Scope 文件和索引。`dist/` 应保持 ignored，不得加入 Git。

## Test plan

- 核心回归是 `tests/diversion-policy.test.ts` 的原文、三种 escape、双转义、非 JS 文本、缺目录、空目录。
- 真实集成是新鲜 `build:tt` + `build:xhs` 后执行 CLI；不能只在旧 `dist` 上验收。
- CI 已按正确顺序调用相同 CLI，无需再造第二套 workflow assertion。
- reviewer 应检查测试从系统临时目录清理，不执行产物文本，也不使用宽泛递归删除路径。

## Done criteria

- [ ] `node --experimental-strip-types --test tests/diversion-policy.test.ts` exit 0。
- [ ] `pnpm test:unit`、`pnpm typecheck` exit 0。
- [ ] `pnpm build:tt && pnpm build:xhs && pnpm check:diversion` exit 0，两个平台文件数都大于 0。
- [ ] `rg -n '\.encode\(|\.decode\(' miniprogram/scripts` 无命中。
- [ ] `rg -n "existsSync\(dir\).*return acc|endsWith\(\"\.js\"\)" miniprogram/scripts/check-no-diversion.mjs` 无命中。
- [ ] 缺目录和零合格文件 fixture 均断言非成功结果。
- [ ] `git diff --check` exit 0，无 Scope 外新改动；本地项目标识配置保持不变。
- [ ] `advisor-plans/README.md` 的 002 状态已更新。

## STOP conditions

立即停止并报告，如果：

- 修复后真实 `dist/tt` 或 `dist/xhs` 首次命中禁词；报告相对 `file:term`，不要直接删业务源码。
- 需要减少禁词、跳过 common/vendor、跳过某个平台或恢复“零文件通过”才能绿。
- 发现某个要扫描的产物是二进制，无法在不误报的情况下定义文本边界；带文件类型证据请求决策。
- 需要执行 artifact 内容、使用 `eval`/`Function` 或修改 CI 顺序。
- 任一步验证在一次合理修正后仍失败，或需要触碰 Scope 外文件。

## Maintenance notes

- 新平台或新模板扩展名加入构建链时，必须同时补 `TEXT_EXTENSIONS` 和 fixture。
- 红线 term 变化是合规政策变更，应由 human 决定并同步 checklist，不是普通 refactor。
- reviewer 重点看空输入 fail-closed、双转义上限、相对路径报告和无文件内容泄漏。
