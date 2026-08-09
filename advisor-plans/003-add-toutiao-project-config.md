# Plan 003: 补齐抖音工程配置并让真实项目标识只留在本机

> **Executor instructions**: 按步骤执行并验证。绝不复制、打印或提交任何真实 AppID/secret；
> `miniprogram/project.config.json` 当前有 operator 的本地改动，必须保持字节级不变。
> 遇到 STOP 条件立即报告，不要猜测平台私有配置文件名。
> 完成后更新 `advisor-plans/README.md` 状态行，除非 reviewer 明确由其维护。
>
> **Drift check（第一条命令）**:
> `git diff --stat f1fd4aa..HEAD -- miniprogram/.gitignore miniprogram/project.tt.json miniprogram/e2e/REAL_DEVICE_CHECKLIST.md miniprogram/e2e/DOUYIN_REDNOTE_CHECKLIST.md`
> 如果任一文件自本方案编写后改变，先对照 “Current state”；不一致即 STOP。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: correctness / DX
- **Planned at**: commit `f1fd4aa`, 2026-08-09

## Why this matters

Taro 的根 `project.config.json` 只服务微信；抖音需要 `project.tt.json`，构建时再输出为目标目录的
`project.config.json`。当前仓库没有抖音配置，清单却让人替换微信配置，因此 `build:tt` 成功也不会生成
可直接导入的抖音工程配置。与此同时，私有配置 ignore 规则末尾多了 `/`，无法保护标准文件。
修复后，三端产物路径由各自模板明确，真实项目标识由开发者工具本机管理，不再污染 tracked 文件。

## Current state

- Taro 4.x 官方“项目配置”明确：微信使用 `project.config.json`，抖音使用 `project.tt.json`：
  <https://docs.taro.zone/docs/project-config>。
- `miniprogram/project.config.json:2,14` 的两个 root 都指向 `dist/weapp/`；该文件不是抖音模板。
  它当前含 operator 的未提交本地项目标识改动，本方案禁止读取/输出其值。
- `miniprogram/project.xhs.json:2,15` 已采用独立 `dist/xhs/` root；新 TT 文件应匹配这种“一平台一模板”结构，
  但不得复制小红书 AppID。
- 当前文件树没有 `miniprogram/project.tt.json`。现有 `pnpm build:tt` 产物也没有
  `miniprogram/dist/tt/project.config.json`；小红书构建则有对应输出。
- `miniprogram/.gitignore:7` 是 `project.private.config.json/`；末尾 `/` 只匹配目录。
- `miniprogram/e2e/REAL_DEVICE_CHECKLIST.md:7` 与
  `miniprogram/e2e/DOUYIN_REDNOTE_CHECKLIST.md:7-10` 都要求直接替换 tracked 配置中的 AppID。
- 现有脚本 `miniprogram/package.json:7-9` 已提供 `build:weapp`、`build:tt`、`build:xhs`；不要新造构建器。

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| 进入包目录 | `cd miniprogram` | 当前目录以 `/miniprogram` 结尾 |
| 保护本地配置 | `tracked_hash_before=$(git hash-object project.config.json)` | exit 0；不要 echo 该文件内容 |
| 抖音构建 | `pnpm build:tt` | exit 0；生成 `dist/tt/project.config.json` |
| 三端构建 | `pnpm build:all` | exit 0 |
| 配置断言 | `jq -e '.miniprogramRoot == "./" and .compileType == "miniprogram"' dist/tt/project.config.json >/dev/null` | exit 0，不输出 AppID |
| ignore 断言 | `git check-ignore -q project.private.config.json` | exit 0 |
| 类型检查 | `pnpm typecheck` | exit 0，无错误 |

## Scope

**In scope**:

- `miniprogram/project.tt.json`（创建；只含非敏感公共模板字段，不含真实 AppID）
- `miniprogram/.gitignore`
- `miniprogram/e2e/REAL_DEVICE_CHECKLIST.md`
- `miniprogram/e2e/DOUYIN_REDNOTE_CHECKLIST.md`
- `advisor-plans/README.md`（只更新状态行）

**Out of scope**:

- `miniprogram/project.config.json`：已有 operator 本地改动，绝不能编辑、格式化或恢复。
- `miniprogram/project.xhs.json`：当前目标路径正确，不复制其中的平台标识。
- 任何真实 AppID、secret、template ID、token 或 `.env` 值。
- 猜测并新增未经平台/Taro 文档确认的 `project.*.private.json` 文件。
- `config/index.ts` 的 release endpoint 校验（单独 finding F15，本方案只修开发者工具工程配置）。
- 业务源码、页面、平台 adapter 和 CI job。

## Git workflow

- Branch: `advisor/003-add-toutiao-project-config`
- 建议单一提交：`fix(miniprogram): 补齐抖音项目配置模板`
- 未经 operator 指示不得 push 或开 PR。

## Steps

### Step 1: 记录但不暴露 operator 配置的内容哈希

在任何编辑前：

```bash
cd miniprogram
tracked_hash_before=$(git hash-object project.config.json)
test -n "$tracked_hash_before"
git status --short
```

**Verify**: 前两条 exit 0；status 可显示既有 `project.config.json` 改动，但不要运行 `git diff` 打印其值。

### Step 2: 创建无真实标识的 `project.tt.json`

创建 `miniprogram/project.tt.json`，目标结构如下；字段顺序跟 `project.xhs.json`，但省略 `appid`：

```json
{
  "miniprogramRoot": "dist/tt/",
  "projectname": "cgc-miniprogram",
  "description": "CGC 小程序（抖音端产物指向 dist/tt）",
  "setting": {
    "es6": false,
    "enhance": false,
    "postcss": true,
    "minified": true,
    "urlCheck": false
  },
  "compileType": "miniprogram",
  "srcMiniprogramRoot": "dist/tt/"
}
```

不要放 placeholder 形似真实标识的字符串；真实 AppID 由开发者工具本机设置。

**Verify**:

```bash
jq -e '.miniprogramRoot == "dist/tt/" and .srcMiniprogramRoot == "dist/tt/" and .compileType == "miniprogram" and (has("appid") | not)' project.tt.json >/dev/null
```

预期：exit 0，无 JSON 输出。

### Step 3: 修正标准私有配置 ignore

把 `miniprogram/.gitignore:7` 从目录规则改为文件规则：

```gitignore
project.private.config.json
```

不要增加宽泛的 `project*.json`，那会把受跟踪的三端公共模板一起隐藏。

**Verify**:

```bash
git check-ignore -v project.private.config.json
git check-ignore -q project.tt.json
test "$?" -ne 0
```

预期：第一条显示 `.gitignore` 的精确文件规则；后两条证明 tracked TT 模板不会被 ignore。

### Step 4: 重写两份真机准备步骤

更新两份 checklist 的“准备”段，明确区分：

- 微信：构建 `pnpm build:weapp`，开发者工具导入 `dist/weapp/`；真实 AppID 仅写入开发者工具支持的本地
  私有配置，操作后用 `git status` 确认 tracked `project.config.json` 未变化。
- 抖音：构建 `pnpm build:tt`，开发者工具导入 `dist/tt/`；Taro 输入模板是 `project.tt.json`，
  构建输出是 `dist/tt/project.config.json`。真实 AppID 只在工具本地设置。
- 小红书：构建 `pnpm build:xhs`，导入 `dist/xhs/`，不要用微信配置。
- checklist 只写 credential 类型与责任边界，不写任何值。

如果任一开发者工具实测要求修改 source tracked config 才能导入，按 STOP 条件记录工具版本和要求，
由 human 决定安全的本地 override；不要先修改 tracked 文件。

**Verify**:

```bash
rg -n "dist/weapp|dist/tt|dist/xhs|project.tt.json|git status" e2e/REAL_DEVICE_CHECKLIST.md e2e/DOUYIN_REDNOTE_CHECKLIST.md
rg -n "替换 .*project\.config\.json|替换 `project\.config\.json`" e2e/REAL_DEVICE_CHECKLIST.md e2e/DOUYIN_REDNOTE_CHECKLIST.md
```

预期：第一条命中各自平台的导入说明；第二条无命中。

### Step 5: 用新鲜产物证明 Taro 读取了 TT 模板

```bash
pnpm build:tt
test -f dist/tt/project.config.json
jq -e '.miniprogramRoot == "./" and .compileType == "miniprogram"' dist/tt/project.config.json >/dev/null
jq -e 'has("appid") | not' dist/tt/project.config.json >/dev/null
pnpm build:xhs
test -f dist/xhs/project.config.json
pnpm typecheck
```

**Verify**: 全部 exit 0。TT 输出存在、root 被 Taro 改写为当前输出目录、没有真实/placeholder AppID；XHS 不回归。

### Step 6: 验证 Scope 与 operator 文件不变

```bash
tracked_hash_after=$(git hash-object project.config.json)
test "$tracked_hash_before" = "$tracked_hash_after"
git diff --check
git status --short
```

**Verify**: hash 比较和 `diff --check` exit 0；status 只增加 Scope 文件。执行前既有的
`project.config.json` 状态可继续存在，但其 blob hash 必须与 Step 1 相同。

## Test plan

- JSON 结构用 `jq -e` 做确定性断言，不把任何 AppID 输出到日志。
- `pnpm build:tt` 是关键集成测试：必须从 root `project.tt.json` 生成
  `dist/tt/project.config.json`。
- `pnpm build:xhs` 验证新增 TT 文件没有改变 XHS 配置选择。
- 微信真实 AppID 与三端开发者工具登录属于 human 真机 gate；本方案只让导入路径和本地配置边界正确。

## Done criteria

- [ ] `test -f miniprogram/project.tt.json` exit 0；该 tracked 文件没有 `appid` key。
- [ ] `pnpm build:tt` exit 0，且 `dist/tt/project.config.json` 存在、root 为 `./`、无 `appid` key。
- [ ] `pnpm build:xhs`、`pnpm typecheck` exit 0。
- [ ] `git check-ignore -q miniprogram/project.private.config.json` 从 repo root exit 0。
- [ ] 两份 checklist 分别写清 `dist/weapp`、`dist/tt`、`dist/xhs` 导入路径，不再要求替换 tracked 配置。
- [ ] `miniprogram/project.config.json` 的 before/after blob hash 相同，任何项目标识值均未出现在日志/提交。
- [ ] `git diff --check` exit 0，无 Scope 外新改动。
- [ ] `advisor-plans/README.md` 的 003 状态已更新。

## STOP conditions

立即停止并报告，如果：

- 当前 Taro 版本不再从 `project.tt.json` 生成 TT `project.config.json`。
- 抖音工具要求一个与 Taro 4.x 官方文档冲突的配置文件名，或必须在 tracked 源文件放真实 AppID。
- TT 输出只有在复制微信/小红书 AppID 后才生成或可导入。
- `project.config.json` 的 blob hash 与 Step 1 不同。
- 修复需要修改 `config/index.ts`、平台业务 adapter、CI 或其他 Scope 外文件。
- 任一步验证在一次合理修正后仍失败。

## Maintenance notes

- 平台新增/升级时先查当前 Taro 官方项目配置映射，再新增模板；不要复用微信文件名猜测。
- reviewer 重点检查 tracked TT 文件无真实标识、ignore 不过宽、checklist 不再教人改 tracked 文件。
- release endpoint/mock/template 的 fail-closed 是 F15，不能因本方案构建成功而宣称发布包已可上架。

