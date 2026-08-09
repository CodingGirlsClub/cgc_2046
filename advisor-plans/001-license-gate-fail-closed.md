# Plan 001: 让许可证门禁只放行明确获准的 SPDX 组合

> **Executor instructions**: 严格逐步执行。每一步都运行验证命令并确认预期结果后再继续。
> 遇到 “STOP conditions” 中任何一项立即停止并报告，不要临时加白名单、忽略包或修改规则来让 CI 变绿。
> 完成后更新 `advisor-plans/README.md` 中本方案状态，除非派发你的 reviewer 明确说由其维护索引。
>
> **Drift check（第一条命令）**:
> `git diff --stat f1fd4aa..HEAD -- miniprogram/scripts/check-licenses.mjs miniprogram/tests miniprogram/package.json miniprogram/pnpm-lock.yaml`
> 如果任一实现文件自本方案编写后改变，先逐段对照 “Current state”；不一致即 STOP。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: human 对现有 `pako@1.0.11` 的 `MIT AND Zlib` 声明作出并回填书面裁定
- **Category**: security / dependencies
- **Planned at**: commit `f1fd4aa`, 2026-08-09

## Why this matters

仓库规则要求新依赖命中明确白名单，未列出的许可证先讨论；当前实现却只拒绝少量字符串。
这意味着 `UNLICENSED`、拼错的 SPDX、专有自定义文本或任何未知声明都能获得
“AGPL-3.0 compatible”结论。修复后，CI 的绿色结果才代表“每个 AND 项都获准，或至少一个
完整 OR 分支获准”，而不是“没撞到 blacklist”。

## Current state

- `docs/开源合规/依赖引入规则.md:13-20` 是持续白名单；`:49-53` 要求未列许可证先开 issue，
  由 human 拍板并回填规则。执行者必须遵守它，但本方案不授权修改它。
- `miniprogram/scripts/check-licenses.mjs:20-28` 只有 blacklist：

  ```js
  const BLACKLIST = [
    "gpl-2-0", "sspl", "busl", "elastic", "proprietary", "commercial"
  ];
  ```

- `miniprogram/scripts/check-licenses.mjs:53-70` 把任意非空字符串拆成候选；`:121-128`
  只有所有候选都命中 blacklist 才拒绝：

  ```js
  if (candidates.every(isBlacklisted)) {
    violations.push({ name: pkg.name ?? entry.name, license: candidates.join(" / ") });
  }
  ```

- 当前依赖树存在 `pako@1.0.11`，其 package metadata 是 `MIT AND Zlib`；Zlib 当前不在持续规则表中。
  这是已知的 human gate，不是让执行者自行判断兼容性的邀请。
- 持续规则只允许 CC-BY 用于数据包；当前树中该形态来自 `caniuse-lite@1.0.30001809`。
  因此 CC-BY 不能进入不看 package context 的通用 allowlist。
- `miniprogram/scripts/check-licenses.mjs:30-37` 对缺失字段的例外只按 package name 匹配；升级到另一个
  version 后仍会继承旧结论，必须改成精确 `name@version`。
- 项目可复用的测试风格见 `miniprogram/tests/domain.test.ts:1-10`：`node:test` +
  `node:assert/strict`，无需为本方案引入测试框架。
- 根原则：新增 npm 依赖必须先核验许可证；本方案选择成熟 SPDX parser，禁止手写表达式 parser。

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| 进入包目录 | `cd miniprogram` | 当前目录以 `/miniprogram` 结尾 |
| 核验 parser | `pnpm view spdx-expression-parse@5.0.0 version license --json` | 输出 version `5.0.0`、license `MIT` |
| 安装 | `pnpm add -D spdx-expression-parse@5.0.0 --save-exact` | exit 0；package/lock 仅出现预期依赖变化 |
| 定向测试 | `node --test tests/license-policy.test.mjs` | exit 0；所有 policy cases 通过 |
| 全量 unit | `pnpm test:unit` | exit 0；既有 domain 与新增 policy tests 全通过 |
| 合规扫描 | `pnpm check:licenses` | exit 0；没有 UNKNOWN/forbidden/unapproved 条目 |
| 类型检查 | `pnpm typecheck` | exit 0，无错误 |

## Scope

**In scope（仅可修改/创建这些实现文件）**:

- `miniprogram/scripts/check-licenses.mjs`
- `miniprogram/scripts/license-policy.mjs`（创建）
- `miniprogram/tests/license-policy.test.mjs`（创建）
- `miniprogram/package.json`
- `miniprogram/pnpm-lock.yaml`
- `advisor-plans/README.md`（只更新状态行）

**Out of scope（即使看起来相关也不得触碰）**:

- `docs/开源合规/依赖引入规则.md`：许可证政策只能由 human 裁定，本计划不代替该决策。
- backend/web 的许可证检查器；本方案只修小程序 job。
- 删除/替换 `miniprogram-automator`、`pako` 或 Taro 依赖来绕过当前政策 gate。
- `miniprogram/project.config.json` 及任何真实平台项目标识、secret、token、`.env`。
- 用字符串 contains、正则拆 `AND`/`OR`，或添加“未知即通过”的 fallback。

## Git workflow

- Branch: `advisor/001-license-gate-fail-closed`
- 按逻辑单元提交；匹配仓库 conventional 风格，例如：
  `fix(miniprogram): 许可证门禁改为白名单 fail-closed`
- 未经 operator 指示不得 push 或开 PR。

## Steps

### Step 0: 先取得许可证政策裁定

运行：

```bash
cd miniprogram
node -e "const p=require('./node_modules/.pnpm/pako@1.0.11/node_modules/pako/package.json'); console.log(JSON.stringify({name:p.name,version:p.version,license:p.license}))"
```

**Verify**: exit 0，输出只包含 package name/version/license type，license 为 `MIT AND Zlib`。

随后检查 `docs/开源合规/依赖引入规则.md:13-20,49-53`。当前 Zlib 未列出，因此本方案现在必须
STOP，由 human 决定以下两条路之一并把结论回填规则/issue：

1. 明确允许 Zlib，再继续本方案；或
2. 明确拒绝 Zlib，并先用另一个获准依赖链移除该声明。

不要把现有依赖、开发依赖或传递依赖“grandfather”成隐式例外。

### Step 1: 引入已核验的 SPDX parser

human gate 解除后，先运行 registry metadata 命令，确认固定版本仍是 MIT，再安装精确版本：

```bash
cd miniprogram
pnpm view spdx-expression-parse@5.0.0 version license --json
pnpm add -D spdx-expression-parse@5.0.0 --save-exact
```

不要使用 `^`/`~`，不要顺手升级其他包。

**Verify**:

```bash
node -e "const p=require('./package.json'); if(p.devDependencies['spdx-expression-parse']!=='5.0.0') process.exit(1)"
git diff -- package.json pnpm-lock.yaml
```

预期：第一条 exit 0；diff 只新增该 direct dev dependency 及 pnpm 解析出的锁文件节点。

### Step 2: 把政策求值器从文件扫描器中拆出

创建 `scripts/license-policy.mjs`，导出纯函数，至少包含：

- `evaluateLicenseDeclaration(raw, context)`：`context` 至少含 package name/version，返回结构化
  `{ allowed, reason }`，不得直接退出进程。
- 使用 `spdx-expression-parse` 解析 string SPDX；解析失败、空值、`UNLICENSED`、`SEE LICENSE IN ...`
  一律拒绝并标记 `UNKNOWN`/`INVALID`。
- SPDX `OR`：任一完整分支允许即可；`AND`：同一分支的所有 license 都必须允许。
- `WITH` exception、`LicenseRef-*` 或 parser 识别但规则未列出的 ID：只有持续规则明确列出才允许，否则拒绝。
- object `{type,url}` 只评估 `type`；数组逐项按“多选”语义处理，但空数组拒绝。
- 允许 ID 必须逐项对应 `docs/开源合规/依赖引入规则.md:13-20` 的当前书面结论；
  不得从“当前 node_modules 恰好出现什么”自动生成 allowlist。
- CC-BY 数据许可不得全局放行：仅当 package name 在窄 `DATA_PACKAGE_NAMES`（当前为 `caniuse-lite`）
  且声明是规则允许的 CC-BY 系时通过；新包名先 fail-closed 交 human 核验用途与署名保留。

将缺字段例外改为精确 `name@version` map，并让 lookup 函数也可单测。现有四个例外的 version 要从各自
`package.json`/LICENSE 重新确认；任何对不上版本的包都必须当 UNKNOWN。

**Verify**:

```bash
node --input-type=module -e "import { evaluateLicenseDeclaration } from './scripts/license-policy.mjs'; const c={name:'fixture',version:'1.0.0'}; if(!evaluateLicenseDeclaration('MIT OR GPL-2.0-only',c).allowed) process.exit(1); if(evaluateLicenseDeclaration('MIT AND GPL-2.0-only',c).allowed) process.exit(1); if(evaluateLicenseDeclaration('UNLICENSED',c).allowed) process.exit(1)"
```

预期：exit 0；证明 OR 可选、AND 全满足、未许可 fail-closed 三个核心语义。

### Step 3: 先用表驱动测试锁定政策边界

创建 `tests/license-policy.test.mjs`，沿用 `node:test` / `node:assert/strict`，至少覆盖：

1. 单一允许项：MIT。
2. 允许 OR 禁止：`MIT OR GPL-2.0-only` 允许。
3. 禁止 OR 未知：拒绝。
4. `MIT AND Zlib`：结果必须与 Step 0 后的书面规则一致。
5. `MIT AND 未列项`：拒绝。
6. `UNLICENSED`、`UNKNOWN`、空字符串、缺字段：拒绝。
7. 语法错误和自定义文本：拒绝，不 crash。
8. object/array legacy 形态。
9. 精确 `name@version` 的 known-no-field 命中允许；同名不同版本拒绝。
10. 现有 `(BSD-3-Clause OR GPL-2.0)` 经允许分支通过。
11. `caniuse-lite` 的 CC-BY 数据许可允许；相同许可放在任意其他 package name 时拒绝。

把 `package.json` 的 `test:unit` 扩展为同时运行 `tests/*.test.ts` 和 `tests/*.test.mjs`，不要删除既有
domain tests。

**Verify**: `node --test tests/license-policy.test.mjs && pnpm test:unit` → 两条均 exit 0，全部测试通过。

### Step 4: 让扫描器使用纯政策求值器并给出可操作报告

修改 `scripts/check-licenses.mjs`：

- 保留全 `.pnpm` 树扫描与缺目录 exit 2。
- 删除 blacklist/candidate split；每个 package 调用 Step 2 的 evaluator。
- violation 至少记录 `name@version`、许可证类型与 reason；不得打印 package 文件的其他字段。
- 输出按 `name@version` 排序，保证本地/CI 可复现。
- 任何 JSON 解析失败也计为 violation，不得 `catch { continue }` 静默跳过。
- 成功时才输出兼容总数；UNKNOWN、INVALID、未获准或 forbidden 任一存在均 exit 1。

**Verify**:

```bash
pnpm check:licenses
node --test tests/license-policy.test.mjs
```

预期：两条 exit 0。若第一条首次暴露新的未列许可证，按 STOP 条件报告，不得新增例外。

### Step 5: 跑完整小程序静态门禁

```bash
pnpm typecheck
pnpm test:unit
pnpm check:licenses
git diff --check
git status --short
```

**Verify**: 前四条 exit 0；`git status --short` 只列 Scope 中实现文件及
`advisor-plans/README.md`。特别不得出现 `miniprogram/project.config.json` 的新 diff；若执行前已有该
用户改动，它应保持字节级不变。

## Test plan

- `miniprogram/tests/license-policy.test.mjs` 是纯政策层回归，必须覆盖 allow、deny、unknown、OR、AND、
  legacy object/array 和精确版本例外。
- scanner 集成由 `pnpm check:licenses` 覆盖当前全依赖树；不要在测试中复制整个 node_modules。
- 对 scanner 的 JSON 解析失败，可在测试中调用导出的单 package 评估函数，不要破坏真实安装树。
- 现有 `miniprogram/tests/domain.test.ts` 必须继续通过。

## Done criteria

- [ ] human 对 Zlib 的书面裁定已存在，代码 allowlist 与其逐项一致。
- [ ] `spdx-expression-parse` 固定为 `5.0.0`，registry metadata 为 MIT。
- [ ] `node --test tests/license-policy.test.mjs` exit 0。
- [ ] `pnpm test:unit`、`pnpm typecheck`、`pnpm check:licenses` 全部 exit 0。
- [ ] `rg -n "BLACKLIST|isBlacklisted|split\(/\\s\+OR" miniprogram/scripts/check-licenses.mjs` 无命中。
- [ ] `rg -n "UNLICENSED|UNKNOWN|MIT AND Zlib|GPL-2.0" miniprogram/tests/license-policy.test.mjs` 命中对应回归用例。
- [ ] `git diff --check` exit 0，且没有 Scope 外的新改动。
- [ ] `advisor-plans/README.md` 的 001 状态已更新。

## STOP conditions

立即停止并报告，不要 improvisation，如果：

- Zlib 仍未在 issue/持续规则中获明确结论。
- `spdx-expression-parse@5.0.0` 的版本或 license metadata 不再是预期值。
- 严格扫描发现任何持续规则未列出的现有 license；报告 `package@version` 和 license 类型，不要自行加例外。
- 正确实现需要修改 backend/web 检查器或删除 E2E 工具链。
- `KNOWN_NO_FIELD` 的 package LICENSE/registry 证据与当前注释不一致。
- 任一步验证在一次合理修正后仍失败，或需要触碰 Scope 外文件。

## Maintenance notes

- 未来更新 allowlist 必须先更新持续规则，再更新 evaluator 与测试；不要反向从安装树生成政策。
- reviewer 重点检查 SPDX AST 的 AND/OR 递归语义、unknown 是否真正 fail-closed，以及 known-no-field 是否含版本。
- 每次新增依赖仍需人工查看 direct package license；机器 gate 是最终兜底，不替代引入者责任。
