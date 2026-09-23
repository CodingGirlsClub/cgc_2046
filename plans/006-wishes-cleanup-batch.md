# Plan 006: 许愿树小清理包——死代码、死条件、丢失的城市参数与 schema 注释漂移

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 6cd74306..HEAD -- "web/app/[locale]/flashback/wishes/wishes-wall.tsx" backend/lib/cgc_2046_web/graphql_schema.ex`
> 002 可能已改过 `wishes-wall.tsx`（加载 effect）；以现场代码为准，本计划的改动点与其正交。

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 排在 002 之后执行（同文件 `wishes-wall.tsx`，避免冲突；无逻辑依赖）
- **Category**: tech-debt（清理）
- **Planned at**: commit `6cd74306`, 2026-09-23

## Why this matters

五个互不相关的小噪声，一次清掉：

1. lint 已报的死变量 `current`（`wishes-wall.tsx:193`）。
2. 举报弹层取消后草稿残留——下次打开还挂着上次的补充说明，而提交路径成功时是清空的，行为不对称。
3. 举报提交按钮的 `disabled={reportFree.trim().length > 200}` 是死条件——`textarea` 已有 `maxLength={200}`，该分支恒 false。
4. 面板底部导航里「愿望」自链不带 `?city=`，而同排的「金句墙」链带着——R21 的「双页互跳保留城市」在这条链接上漏了。
5. 后端 `flashback_public_wishes` 的 arg 描述声称「城市过滤（Cities.normalize 短名）」，但 resolver 直传原始值：URL 手改 `?city=成都市` 会得到空树（`w.city == '成都市'` 无匹配），而表单路径同样的输入会被归一成「成都」。注释与实现漂移，实现侧补上归一即可对齐（未知城市保持直传 → 宽容空树，语义不变）。

## Current state

### 前端：`web/app/[locale]/flashback/wishes/wishes-wall.tsx`

死变量（基线 :193；实施时因 418655f8 重构漂移至 :202，已删除——commit 974460b1）：

```tsx
	const current = wishes.find((w) => w.id === currentWishId) ?? wishes[0] ?? null;
```

实际渲染用的全部是 `currentInFilter`（`:196-199`）。整行删除即可。

举报弹层（搜索 `setReportFor` 与 `reportFree`）现状要点：

- `textarea` 有 `maxLength={200}`；
- 提交按钮带死条件（基线 :549；实施时漂移至 :556，已删——commit 974460b1）：

```tsx
					<button
						type="button"
						className={styles.primaryBtn}
						disabled={reportFree.trim().length > 200}
						onClick={submitReport}
					>
```

- 关闭按钮（弹层底部 ghostBtn）：`onClick={() => setReportFor(null)}` —— 不清 `reportFree`；`submitReport` 成功路径则 `setReportFor(null); setReportFree("");`（基线 :310-311；取消按钮实施时漂移至 :560-568，已改为取消即清草稿——commit 974460b1）。

面板底部导航（`panelOps` 内，R21 注释旁）：

```tsx
					<Link className={styles.ghostBtn} href={city ? `/flashback/voices?city=${encodeURIComponent(city)}` : "/flashback/voices"}>
						{t("voicesEntry")} <Icon name="arrow" />
					</Link>
```

而顶部 `header` nav 里当前页链接是裸的（基线 :333；实施时漂移至 :340-346，已带 city——commit 974460b1）：

```tsx
					<Link href="/flashback/wishes" className={styles.activeNav} aria-current="page">
```

### 后端：`backend/lib/cgc_2046_web/graphql_schema.ex`

`:494-521`，`flashback_public_wishes` resolver：

```elixir
      resolve(fn _, args, %{context: context} ->
        # HS-3 双键读面：登录 actor 强制 u: 键 + 入参 a: 设备键合并（期待态
        # 刷新不漂移——mutation 登录态按 u: 记账）；未登录维持入参单键。
        Cgc2046.Flashback.WishPublic.wishes(
          city: args[:city],
          ...
        )
      end)
```

arg 描述（`:496`）：`@desc "城市过滤（Cities.normalize 短名；null = 不过滤）"`。

归一函数已存在：`backend/lib/cgc_2046/flashback/cities.ex:104-133`，`Cities.normalize(input)` 返回 `{:ok, short} | {:error, %{code: ..., candidates: [...]}}`；调用先例见 `wishes.ex:187-194`。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 类型检查 | `cd web && npx tsc --noEmit` | exit 0 |
| 前端测试 | `cd web && pnpm vitest run "app/[locale]/flashback/wishes" components/flashback` | 全部 pass |
| lint | `cd web && npx eslint "app/[locale]/flashback/wishes"` | 0 errors 0 warnings（`current` warning 消失） |
| 后端测试 | `cd backend && mix test test/cgc_2046_web/graphql_flashback_public_wish_viewer_test.exs` | 全部 pass（需要本地 dev 依赖可用；不行则报告） |

## Scope

**In scope**:
- `web/app/[locale]/flashback/wishes/wishes-wall.tsx`（死变量、举报弹层两处、nav 自链）
- `backend/lib/cgc_2046_web/graphql_schema.ex`（`flashback_public_wishes` resolver 内 city 归一）
- `backend/test/cgc_2046_web/graphql_flashback_public_wish_viewer_test.exs`（追加用例——fixture 唯一存在的位置）

**Out of scope**:
- `wish_public.ex` 的 SQL/过滤语义——「城市过滤包含 `city IS NULL` 愿望」（`is_nil(w.city) or w.city == ^city`）疑似有意设计（不因筛选隐藏无期望地的愿望），**保持原样，不要动**；如你想改它，那是 STOP 条件。
- `corridor.tsx` 的 `pileIdx` lint warning——不在本批范围。
- 任何 i18n 文案文件。

## Git workflow

- 当前 worktree 分支继续；commit style：`chore(flashback): wishes cleanup — dead code, report draft reset, city-preserving nav, schema city normalize`
- 只本地 commit，不 push。

## Steps

### Step 1: 前端三处小修（wishes-wall.tsx）

1. 删除 `:193` 整行 `const current = ...`。
2. 举报弹层两处关闭（底部 ghostBtn 关闭按钮；若有其他 `setReportFor(null)` 的取消路径一并处理）改为同时清草稿：

```tsx
							<button
								type="button"
								className={styles.ghostBtn}
								onClick={() => {
									setReportFor(null);
									setReportFree("");
								}}
							>
```

3. 删除提交按钮的 `disabled={reportFree.trim().length > 200}`（`maxLength` 已挡，恒 false 的死条件）。
4. 顶部 nav 自链带城市（与 voices 链接同款三元）：

```tsx
					<Link
						href={city ? `/flashback/wishes?city=${encodeURIComponent(city)}` : "/flashback/wishes"}
						className={styles.activeNav}
						aria-current="page"
					>
```

**Verify**: `cd web && npx tsc --noEmit && npx eslint "app/[locale]/flashback/wishes"` → 均干净，`current` warning 消失。

### Step 2: 后端 resolver 补 city 归一

`graphql_schema.ex` 的 `flashback_public_wishes` resolver 内，把直传改为归一（失败保持原值——与表单路径「未识别拒绝」不同，这里是读面过滤，宽容处理维持现状语义）：

```elixir
      resolve(fn _, args, %{context: context} ->
        # HS-3 双键读面：登录 actor 强制 u: 键 + 入参 a: 设备键合并（期待态
        # 刷新不漂移——mutation 登录态按 u: 记账）；未登录维持入参单键。
        # 城市过滤与表单同源归一（KTD11）：「成都市」→「成都」；未识别值原样
        # 直传——读面宽容，查询结果为空而非报错。
        city =
          case args[:city] do
            nil ->
              nil

            raw when is_binary(raw) ->
              case Cgc2046.Flashback.Cities.normalize(raw) do
                {:ok, short} -> short
                {:error, _} -> raw
              end

            # 防御分支：:string 入参实际只会是 binary|nil；兜底防运行时 CaseClauseError
            other ->
              other
          end

        Cgc2046.Flashback.WishPublic.wishes(
          city: city,
          seed: args[:seed],
          offset: args[:offset],
          limit: args[:limit],
          voter_keys: viewer_voter_keys(context, args[:voter_key])
        )
      end)
```

（`viewer_voter_keys` 等其余参数以现场代码为准，仅 `city:` 一处变化。）

**Verify**: `cd backend && mix deps.get && mix compile --force` → exit 0。注意：`mix compile --warnings-as-errors` 不是可靠的 mix CLI 形态（elixirc 的选项，裸 mix 不同版本行为不一），本计划用 `--force` 全量重编译 + exit 0 判定；要钉警告级别属 mix.exs `elixirc_options` 配置，超出本计划范围。若 `mix deps.get` 拉依赖失败（网络/环境），读日志后报告，不要装全局环境。

### Step 3: 后端回归测试

**宿主文件是 `backend/test/cgc_2046_web/graphql_flashback_public_wish_viewer_test.exs`**——fixture（`listed_wish/2` 在 `:52`、`wishes_query/0` 在 `:75`）只在该文件存在；`graphql_flashback_test.exs` 里没有任何 `flashbackPublicWishes` 用例，写过去不会被执行（这是本计划的验证空头，别犯）。

先读 `graphql_flashback_public_wish_viewer_test.exs:20-79` 学 fixture 手法（person + archive + listed_wish helper + post_graphql）。追加一条：城市全称归一——

- **fixture 关键**：`listed_wish` 不传 `expectedCity` 时 wish 的 city 取自 person 名册城市归一值——所以要建「成都」愿望必须先 `create_person(%{city: "成都"})`（以该文件 person fixture 的实际 helper 签名为准）再 `listed_wish`，别拿默认「北京」fixture 去断言成都。
- **查询关键**：现有 `wishes_query()` 不含 `city` 参数——在本用例内联一个带 `city: $city` 变量的查询（字段集照抄 `wishes_query` 的 selection），或给 helper 加可选参数；二选一，内联优先（不动既有 helper 签名）。
- 断言：`%{"city" => "成都市"}` 查询返回该成都愿望（归一命中）；`%{"city" => "不存在的城市"}` 返回空列表（宽容路径不变）。

**Verify**: `cd backend && mix test test/cgc_2046_web/graphql_flashback_public_wish_viewer_test.exs` → 全 pass（含新用例）。

### Step 4: 前端回归

**Verify**: `cd web && pnpm vitest run "app/[locale]/flashback/wishes" components/flashback` → 全 pass（含 002 追加的乱序用例）。

## Test plan

- 后端 1 条新用例（全称归一命中 + 未知城市宽容空）。
- 前端无新用例（全是行为等价清理）；既有测试守护回归。

## Done criteria

- [ ] `cd web && npx tsc --noEmit` exit 0
- [ ] `cd web && npx eslint "app/[locale]/flashback/wishes"` 0 warnings（`current` 消失）
- [ ] `cd web && pnpm vitest run "app/[locale]/flashback/wishes" components/flashback` 全 pass
- [ ] `cd backend && mix test test/cgc_2046_web/graphql_flashback_public_wish_viewer_test.exs` → 全 pass（含新用例）
- [ ] `grep -n "const current = " "web/app/[locale]/flashback/wishes/wishes-wall.tsx"` 无匹配
- [ ] `grep -n "reportFree.trim().length > 200" "web/app/[locale]/flashback/wishes/wishes-wall.tsx"` 无匹配
- [ ] `git status` 只有 in-scope 三文件
- [ ] `plans/README.md` 状态行更新

## STOP conditions

- 「Current state」任一摘录对不上现场（002/003/004/005 已先行改动）——做等价改动；结构对不上就报告。
- 你想改 `wish_public.ex` 的 `is_nil(w.city) or w.city == ^city` 过滤语义——那是疑似有意设计，STOP。
- 后端测试环境不可用——**仅当 `mix test` 以 exit code 2 退出且 stderr 同时包含 `connection refused` 或 `database .. does not exist` / `database unknown`**（Postgre 连接/库不存在）才算。「DB 连不上等」的「等」字到此为止——任何其它红值得你读日志后再报，不要乱猜原因。
- 测试用例 fixture 找不到（`listed_wish`/`wishes_query` 在所述文件里不存在）——报告，不要自创 fixture。

## Maintenance notes

- 举报弹层若将来升级为独立组件，把「关闭即清草稿」带过去。
- `?city=` 归一在前端入口（`wishes-page.tsx` 解析 searchParams 处）再做一层也可以，但当前后端单点归一已足够，不要重复建设。
- reviewer 重点看：resolver 归一失败分支必须回传原值（不能 return error——读面宽容）。
