# backend（Phoenix + Ash）

API 后端：AshGraphql 提供 GraphQL（`web/` 与 `miniprogram/` 的数据面），anubis_mcp 在 `/mcp` 提供 MCP server。没有项目级 HTML / LiveView 模板——前端是 `web/` 的 Next.js，仅有的 LiveView 来自 AshAdmin 与 LiveDashboard。

## 验证与测试

- 改完所有内容跑 `mix precommit`，修掉它报的问题。
- 调试测试失败用 `mix test test/my_test.exs` 或 `mix test --failed`；用任何 mix task 前先 `mix help task_name` 读选项。`mix deps.clean --all` 几乎永远不需要。
- 测试里用 `start_supervised!/1` 起进程（保证用例间清理）；不用 `Process.sleep/1` / `Process.alive?/1`——等进程结束用 `Process.monitor/1` + `assert_receive {:DOWN, ^ref, :process, ^pid, :normal}`，等进程处理完既有消息用 `_ = :sys.get_state(pid)`。
- **worktree 自动隔离数据库，不用设环境变量**：在附属 git worktree 里运行时，`config/worktree_suffix.exs` 按分支名（detached HEAD 用 worktree 目录名）给库名加后缀，dev 库 `cgc_2046_dev_<slug>`、测试库 `cgc_2046_test_<slug>`；主 checkout 与 CI 不加后缀。共用一个库时，同机多个 worktree 并发跑测会互相看到对方的写入与行锁，表现为随机 `DBConnection` 超时/死锁/`StaleRecord`——所以测试要在自己的 worktree 里跑。测试库由 `mix test` 别名的 `ecto.create`/`ecto.migrate` 自动建好；dev 库由 `scripts/worktree/setup-worktree.sh`（或 `mix setup`）建好。

## 契约同步（改一处就要走完全链）

- **错误码契约（#241）**：业务错误 code 单源 = domain 层 `domain_error_code` 显式子句与 `code: "..."` 字面量，AST 提取生成 `priv/error_codes_contract.json`。新增/改名 code 后运行 `mix cgc2046.gen_error_codes_contract` 再生成（CI `--check` + 测试守卫新鲜度）；用户可见的 code 同步补 `web/messages/*.json` errors namespace 与 `miniprogram/src/domain/error-copy.ts` 文案（两端 contract test 断言键 ⊆ 契约）。需要文案的 reason 不得依赖兜底动态拼接——先显式子句化。
- **教研内容契约四层同步（#677 复盘）**：改 `lib/cgc_2046/curriculum/content.ex` 形状契约（含新增字段、收紧校验、调整嵌套位置）时，四层必须同 PR 过一遍：① `lib/cgc_2046/mcp/playbooks.ex` 教研起草规则 ② MCP 工具 description（`save_course_content` 等）③ 入库校验（ContentValidation）④ 发布门禁（PrepGate）。教学面（①②）必须写**嵌套位置与完整形状**（如「checklist 嵌在 story 内，不是卡顶层」），只列字段清单不点位置，agent 会按直觉填错；校验层错误文案必须透出具体违规（`shape_violations`/`objective_violations` 并入 message），折叠成一句通用文案会让调用方失去自纠能力。

## Ash / Elixir 约定

- 自己发 HTTP 请求一律用 `Req`，**不要**用 `:httpoison` / `:tesla` / `:httpc`。Tesla 只出现在 wechat / alipay SDK 的接缝里（`lib/cgc_2046/integrations/wechat/requester.ex` 是 SDK 要求的 Tesla requester；`lib/cgc_2046/payments/providers/` 等处匹配的 `%Tesla.Env{}` 是 SDK 返回值）——SDK 接缝以外别用。
- **业务数据层是 Ash resource，不是裸 Ecto schema / changeset**：changeset 取值用 `Ash.Changeset.get_attribute/2` / `get_argument/2`（struct 默认不实现 Access，`changeset[:field]` 取不到）；服务端设定的字段（actor、归属等）不进 action 的 `accept`，在 change 里显式设置——防止调用方伪造。
- Ash `:atom` 类型默认走 `String.to_existing_atom/1`，对用户输入安全；**禁止**在 Ash resource 的 `:atom` 字段/参数上开 `constraints [unsafe_to_atom?: true]`（会退回 `String.to_atom/1`，造成 atom 表污染/内存泄漏）；需要任意字符串时改用 `:string` + 显式校验。同理不要对用户输入用 `String.to_atom/1`。
- 日期时间用标准库（`Time` / `Date` / `DateTime` / `Calendar`），别加依赖（`date_time_parser` 是解析场景的例外）。
- Elixir 语义易错点：列表不支持 `mylist[i]`（用 `Enum.at/2`、模式匹配或 `List`）；`if` / `case` / `cond` 内部的重绑定不会逃逸出块，要把表达式结果绑到变量上；一个文件不嵌套多个模块（易致循环依赖）。
- 命名：谓词函数不以 `is_` 开头、以问号结尾，`is_thing` 留给 guard。
- `DynamicSupervisor` / `Registry` 等 OTP 原语在 child spec 里必须给 `name:`，之后按名字调用。并发遍历用 `Task.async_stream/3`（带背压），多数场景要传 `timeout: :infinity`。
- Phoenix router 的 `scope` 已带 alias 前缀，路由模块名别再重复写前缀，也不需要自己 `alias`。`Phoenix.View` 已从 Phoenix 移除，不要用。

## 数据库迁移纪律

- 用 `mix ecto.gen.migration migration_name_using_underscores` 生成迁移文件（时间戳与约定才对）。`seeds.exs` 里记得 `import Ecto.Query` 及其他支撑模块。
- **Snapshot 同步**：本 repo 走手写 migration 路线，`priv/resource_snapshots/repo/` 是 Ash 工具链的追踪镜像而非 source of truth。改 resource attribute 后须跑 `mix ash_postgres.generate_migrations --snapshots-only` 同步 snapshot，否则 `--check` 会报 pending codegen。CI 门禁已落地：`../.github/workflows/ci.yml` backend job 跑 `mix ash_postgres.generate_migrations --check`，snapshot 滞后会在 PR 阶段被拦红。
- **identity 索引名守卫**（#611）：`mix ash_postgres.generate_migrations --check` 比对的是 snapshot，**不比对 DB**——手写 migration 的索引命名漂移它看不见；全仓守卫 `test/cgc_2046/identity_index_guard_test.exs` 从 resource identity 推导 `identity_index_names[name] || "<table>_<identity>_index"` 查 `pg_indexes`（含 `indisunique`），命名漂移与「新增 identity 忘建索引」都在此红；改名类迁移须声明 `@renames` 并导出 `renames/0`，才能被 `@tag :migration_probe` 探针自动发现并重放。
- **FK on_delete 纪律**（#724）：DB 侧 FK 的 `ON DELETE` 由手写 migration 决定，resource 侧必须在 `postgres do references do reference(:rel, on_delete: :delete | :nilify) end` 逐列对齐——**未声明 = 生成迁移不写 ON DELETE 子句 = NO ACTION**，所以「DB 是 CASCADE/SET NULL 而 DSL 未声明」的列在 snapshot 里记 `null`，未来 generator 一旦触碰该列就会生成 NO ACTION 版 `modify` 造成行为回退（#721 的 `assigned_by` 即此类）。`--check` 只比 snapshot 不比 DB，抓不到这种漂移：全仓守卫 `test/cgc_2046/fk_on_delete_guard_test.exs` 从 belongs_to/references 推导期望 `confdeltype` 查 `pg_constraint`（双向 + `ignore?: true` 反向），另有两张**报备清单**需随现状维护——`@db_only_fks`（DB 有 FK、resource 无 relationship）与 `@no_db_fk_relationships`（resource 有 relationship、DB 无 FK）。新增/改动 FK 时三处同步：migration、resource `references`、snapshot（`--snapshots-only`）；纯追平（SQL 无变更）时**不写 migration**，`--snapshots-only` 即可。
- **活表迁移并发纪律**（016 审计立项）：对**已存在且在生产增长的表**加索引，一律 `@disable_ddl_transaction true` + `create index(..., concurrently: true)`（失败残留 INVALID 索引需手工清理）；加约束走 NOT VALID + VALIDATE 两段式（样板 `priv/repo/migrations/20260902000000_add_occupancy_nonnegative_check.exs`）；大表回填与 DDL 拆开、分批。新表/空表不受限。反例：`20260906000003_add_workflow_run_subject_scope.exs`（三索引 + 逐行回填同事务）。
- **CHECK 上线三段式**（#634）：加 CHECK 前先**只读普查存量**（违规行必须先回填——NOT VALID 约束对存量行不扫描，但该行此后每次 UPDATE 都会被拦）；脏数据环境下用 `NOT VALID` 上线（上线即对新写入生效）；`VALIDATE CONSTRAINT` **永远单开一条迁移**（大表全表校验独占窗口，不与 DDL/回填混在一起）。
