# 学习空间发布与 OAuth 授权运维

面向对象：发布负责人、平台管理员、客服排查者。架构决策见 ADR-0013（`docs/adr/0013-mcp-oauth-authorization-server.md`）；宿主侧行为实测见 `docs/plans/2026-09-15-u2-host-spike-report.md`。

## 0. 事实索引

| 项 | 值 | 出处 |
|---|---|---|
| 学习空间包源目录 | `learn-space/` | 仓库 |
| 打包脚本 | `learn-space/bin/pack` | 仓库脚本（CI `learn-space` job 与 deploy 均直接调用） |
| 版本文件 | `learn-space/VERSION`（当前 `0.1.0`） | 同上 |
| 分发包下载地址 | `https://api.codingirlsclub.com/ext/learn-space.zip` | deploy 产物 |
| 三键版本 JSON | `https://api.codingirlsclub.com/ext/learn-space.json`（`version` / `download_path` / `sha256`） | `.github/workflows/deploy.yml`「Build learn-space distribution artifacts」 |
| 静态面白名单 | `backend/lib/cgc_2046_web.ex` 的 `static_paths` 含 `ext` | 同上 |
| 客户端固定目录 | macOS `~/Documents/CGC-2046`；Windows `%USERPROFILE%\Documents\CGC-2046` | `web/components/agent-connect-sections.tsx` |
| 授权回调 | `http://127.0.0.1:19876/mcp/oauth/callback`（端口由宿主决定） | U2 ② 实测；`OAuthClient.packaged_redirect_uris/0` |
| 授权服务器 issuer | `https://codingirlsclub.com`（裸域） | `backend/config/deploy.yml` `OAUTH2_ISSUER_URL` |
| MCP 资源 | `https://api.codingirlsclub.com/mcp` | `OAUTH2_RESOURCE_URL` |
| 签名密钥 env | `OAUTH2_SIGNING_SECRET`（GitHub production environment secret） | `.github/workflows/deploy.yml` |
| 协议路径（主域） | `/oauth`、`/.well-known/oauth-authorization-server` → 后端 oauth role | `backend/config/deploy.yml` |
| 引导页 | `/{locale}/w/{slug}/settings/integrations/agents/opencode` | `web/app/[locale]/w/[slug]/settings/integrations/agents/opencode/page.tsx` |
| 授权管理（工作台） | `/{locale}/w/{slug}/settings/integrations/agents/mcp`（连接令牌 + 已授权应用） | 同目录 `mcp/page.tsx` |
| 授权管理（用户级） | `/{locale}/settings/account/connections` | `web/app/[locale]/settings/account/connections/page.tsx` |
| 平台管理面 | `https://codingirlsclub.com/ops/admin`（platform admin） | `backend/lib/cgc_2046_web/router.ex` 的 `/ops/admin` |

---

## 1. 学习空间包发布

### 1.1 触发与产物链

1. `learn-space/**` 有变更时，deploy workflow 的变更检测把 `backend=true`——学习空间与扩展分发产物都寄生在 backend 镜像（`priv/static/ext/`），改动必须重建镜像，否则线上 `/ext/*` 停在旧版。
2. CI（PR 阶段）跑 `learn-space` job：`bin/pack`。打包脚本自带禁入项扫描与**清单全等校验**，失败即非零退出。
3. deploy（main）在 `kamal deploy` 之前跑「Build learn-space distribution artifacts」：`bin/pack` → 拷 zip 到 `backend/priv/static/ext/` → 用 `learn-space/VERSION` 与所拷 zip 的 sha256 生成 `learn-space.json` → 断言 zip 非空、json 的 `version` 非空。
4. kamal 在 runner 本地构建镜像（`COPY backend/ .` 把产物带进 build stage），release 运行时经 `Plug.Static` 在 `/ext/*` 服务。

**三键契约不得增减**：`version`（= `learn-space/VERSION` 原文）、`download_path`（恒为 `/ext/learn-space.zip`）、`sha256`（所分发 zip 的字节哈希）。包内自检以此三键为完整性锚点。

**sha 稳定性**：`bin/pack` 已归一化 zip 时间戳——同内容重建产出同一 sha，用户手上的旧包对新发布的 JSON 做校验仍一致；只有内容变化才会换 sha，而内容变化时必须 bump VERSION（见上）。

### 1.2 版本纪律（VERSION bump）

**包内容有任何变更（新增/修改/删除文件，含回退到旧内容）都必须 bump `learn-space/VERSION`。** 首期为人工纪律（对照：扩展侧已有自动门禁 `openclacky-ext/cgc-2046/bin/check-version-bump`，学习空间尚无对应脚本）。

原因：会话内自检（`/cgc-status`）拿本地 `VERSION` 与线上三键 JSON 的 `version` 比对来判断「是否有新版」，引导页也把当前发布版本展示给用户。内容变了但版本号不变 → 已下载的用户不会收到任何提示，静默停在旧包；回退内容时若沿用新版本号，已下载新版的用户会停在错误内容上。扩展侧的同款事故（版本号未 bump 导致用户静默停在旧构建）正是那里加了自动门禁 `openclacky-ext/cgc-2046/bin/check-version-bump` 的原因；学习空间首期以本手册的人工纪律替代。

### 1.3 发布前本地检查（可在任意 macOS/Linux 上执行）

```sh
# 1) 打包（输出清单校验结果与 version/sha256）
learn-space/bin/pack
# 例：packed: …/learn-space/dist/learn-space.zip (manifest OK: 8 files)
#     version=0.1.0 sha256=ab5cb5da…59e1f

# 2) 清单核验：zip 条目集必须等于「git 跟踪且未被忽略的 learn-space 文件」
#    （排除 dist/ 与 bin/——构建脚本不进包；顶层目录固定为 CGC-2046/）
unzip -Z1 learn-space/dist/learn-space.zip | grep -v '/$' | LC_ALL=C sort
git -C . ls-files learn-space | grep -v '^learn-space/dist/' | grep -v '^learn-space/bin/' \
  | sed 's|^learn-space/|CGC-2046/|' | LC_ALL=C sort

# 3) 三键 JSON 的本地复算（CI 用的同一条命令）
shasum -a 256 learn-space/dist/learn-space.zip   # Linux/CI 用 sha256sum
```

打包失败的三种典型输出与含义：

- `pack: forbidden content found, aborting` —— 包内出现了禁入形态：宿主原语错名（`ask_user` / `auto_reply`）、平台协议条目关键词（`playbook-first` / `get_role_playbook`）、凭证形态（`client_secret` / `Bearer ` / `PRIVATE KEY` / `cgc_<64hex>`）。**不要改扫描规则绕过**：这些形态进包意味着单源纪律或凭证纪律被破坏（协议文本归平台 instructions/playbook，凭证不进包）。
- `pack: tracked file missing` —— 有 git 跟踪的文件在工作区不存在（删了没 `git rm`）。
- `pack: manifest mismatch` —— zip 条目集与期望集不等（多打的产物、被 gitignore 误排、打包中途改动）。脚本会删掉坏 zip 并非零退出。

### 1.4 发布后核验

```sh
# 1) 三键 JSON 可取、键集合正确
curl -s https://api.codingirlsclub.com/ext/learn-space.json | jq -c .
# 期望：{"version":"…","download_path":"/ext/learn-space.zip","sha256":"…"}

# 2) 下载产物与 JSON 的 sha256 一致
curl -sO https://api.codingirlsclub.com/ext/learn-space.zip && shasum -a 256 learn-space.zip

# 3) 用户侧自查（会话内）：报告连接状态、账号、工作台数量、学习空间版本与完整性结论
#    /cgc-status
```

> 当前状态（2026-09-15）：分支尚未合入 main，生产 `/ext/learn-space.json` 与 `/ext/learn-space.zip` 均返回 404；上述命令在首次部署后才有期望输出。

### 1.5 回滚

- 分发产物随 backend 镜像走：**回滚包内容 = 恢复 `learn-space/` 内容 → bump `VERSION` → 重新走一次发布**（`kamal rollback` 回退镜像只会连带回退 backend 全部代码，不用于单回退包）。
- 已下载旧包的用户在下一次自检时会看到「有新版」，不需要额外通知。
- zip 与 json 必须同批生成：手工挑包（只换 zip 不换 json，或反之）会让用户自检报「包已损坏或被改动」。

---

## 2. RC 依赖升级与回退

### 2.1 现状（`backend/mix.exs` / `backend/mix.lock`）

| 依赖 | 约束 | 锁定版本 |
|---|---|---|
| `ash_authentication` | `~> 5.0-rc` | `5.0.0-rc.13` |
| `ash_authentication_phoenix` | `~> 3.0-rc` | `3.0.0-rc.10` |
| `ash_authentication_oauth2_server` | `~> 0.3.1` | `0.3.1` |

三条都在生产栈里；前两条升级前是稳定版 `4.14.2` / `2.17.2`（约束分别为 `~> 4.14` / `~> 2.4`），OAuth 库是本次随升级新增的依赖。OAuth 库强依赖 `ash_authentication ~> 5.0-rc`，因此**RC 与 OAuth 面是同生共死的**——这条决定了 §2.4 的回退口径。

### 2.2 升级步骤

1. 改 `backend/mix.exs` 约束或跑 `mix deps.update <包名>`，只动本计划范围内的依赖（不做顺带升级）。
2. 本地跑完 §2.3 的全部门禁。
3. push 到 `develop`：CI 的 `deps-image` job（仅 push 事件）按 `sha256sum mix.lock | cut -c1-16` 计算 tag，检查 TCR 里当前 `mix.lock` 对应的 amd64 镜像是否存在，缺失即就地构建推送。
4. **`mix.lock` 变更必须等 CI `deps-image` job 绿后再合入 main**；合并一律 merge commit。deploy 侧保留 fallback 构建（镜像缺失时现场建，代价是部署时长可达 45 分钟以上，job 超时 90 分钟）。
5. 破坏性变更核对：RC 的主要破坏面是动作类型与错误传播语义（如邮件发送失败由静默改为抛出）；升级后重点看认证与邮件相关测试。

### 2.3 门禁（backend，逐条）

```sh
cd backend
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix cgc2046.gen_rbac_contract --check
mix cgc2046.gen_error_codes_contract --check
mix cgc2046.check_licenses        # 新依赖的许可证门禁
mix hex.audit                     # 依赖 advisory
mix ash_postgres.generate_migrations --check
mix test
```

### 2.4 回退口径

- **不建议把「回退到稳定版」当作故障处置**：回到 `4.14.2` / `2.17.2` 必须同时移除 `ash_authentication_oauth2_server` 与整套 OAuth 面（双凭证、授权页、管理面、包内配置全部失效），是产品级回退而非依赖回退。
- 首选处置：**pin 到上一个可用的 rc**（改 `mix.lock` 对应条目或降约束到具体 rc 版本）→ 跑 §2.3 门禁 → 等 `deps-image` 绿 → 重新部署。RC 出阻塞缺陷时，计划中记录的备选路径是自建最小授权服务器（见 ADR-0013 §6），同样不走 4.14。
- 回退前的证据留存：记录失败的 CI run、报错栈、复现步骤，作为是否转自建路径的判据。

### 2.5 数据库面

- OAuth 表由迁移 `20260914172930_create_oauth2_server_tables.exs` 建立（授权码、刷新链、同意行、client）。
- 部署钩子 `backend/.kamal/hooks/pre-deploy` 在切流前跑 `Cgc2046.Release.migrate` 与 `Cgc2046.Release.seed`（seeds 幂等，重跑安全；预注册的打包 client 由 seeds 保证存在 → 首公里不依赖 DCR）。
- `kamal rollback` 时钩子检测到 `KAMAL_COMMAND=rollback` 会直接退出，**不做**迁移与 seed：回滚旧镜像时新表原样保留，旧代码不引用它们，无反向迁移需要。

---

## 3. 授权故障排查

### 3.1 症状速查

| 症状（用户或宿主侧看到） | 归因 | 处置 |
|---|---|---|
| 会话里首次调用后没有出现授权页 | 模型未就绪，或配置写入后没重启宿主 | 确认模型能正常回复；完全退出宿主再重开，重新打开学习空间 |
| 宿主显示 `needs authentication`（宿主状态词） | 从未授权，或凭证已被清（撤销 / 刷新失败） | 按引导页第④步重新授权；会话内 `/cgc-status` 复核 |
| 浏览器出现授权页，用户点了拒绝 | 用户拒绝（`access_denied`） | 宿主报 `Authentication failed: user_denied`（平台文案经 `error_description` 直达用户）；用户可重试 |
| 浏览器一直显示「等待授权」且始终没有结果 | 回调端口 `127.0.0.1:19876` 被占用 | 宿主**不会**报端口错误、不换端口（U2 ② 实测：静默挂起）→ 关掉其它正在等待授权的工具，或重启宿主后重新打开学习空间；等待超时后重开即可再次发起 |
| 刷新被拒后宿主要求重新授权 | 刷新失败返回 `invalid_grant`（撤销、闲置过期、重用检测）→ 宿主清凭证 | 重新授权（见 3.2 撤销后重建） |
| 授权页直接报 `invalid_target` | 授权请求的 `resource` 与平台配置不一致（包内 URL 与平台 `OAUTH2_RESOURCE_URL` 不同值） | 核对 §0 的两处 URL 同值，见 ADR-0013 §3.1 |
| 宿主一直在用旧凭证、OAuth 从不触发 | 宿主全局配置里存在同名 `cgc-2046` 条目并带静态 `Authorization` 头——配置是字段级深合并，全局头会继承进项目条目 | 见 3.3「继承静态头」 |
| 429 `rate_limited` | 失败节流或注册配额 | 不重试，按 `Retry-After` 稍后再试（成功调用不计数） |

### 3.2 逐项处置

**撤销后重建授权（闭环）**

1. 用户在 web 撤销：工作台 MCP 页「已授权应用」或用户级「连接与授权」页（两步确认）。撤销 = 整链失效 + 撤回同意行 → 下一次调用即 401，且重新授权必须重过同意页。
2. 宿主下一次调用得到 401（带 `resource_metadata` 发现头）→ 尝试刷新 → 得到 `invalid_grant` → 清凭证 → 转「需要授权」。
3. 用户在会话里重新触发，或回引导页第④步重新授权；同意页会再次展示账号、能力与回调地址。

**宿主的幂等恢复组合**（当状态不一致、需要强制重建凭证时）

```sh
opencode mcp list        # 看状态：connected / needs authentication / failed
opencode mcp logout      # 清掉本机凭证
opencode mcp auth        # 重新走授权
```

注意：`opencode mcp auth` 在**已有凭证**时会弹确认提示（非交互终端下会挂起），所以恢复组合固定为「先 logout 再 auth」。

**429 与节流面**

- 失败认证节流：按 remote_ip 计失败次数，默认 20 次 / 15 分钟，超限 429 + `Retry-After: 900`；**成功认证不计数、不受节流影响**（避免 NAT 后正常用户被旁人拖累，也避免堵死宿主的 401→刷新自愈序列）。
- 分桶：OAuth 失败与静态 token 失败各用一个 key；注册配额另算（默认 10 次 / 小时 / IP）。
- 只读排查：登录主域看 429 是否集中在某个出口 IP（NAT 共享出口是已知形态）。

**时钟**

平台侧对令牌 `exp` / `nbf` 允许 30 秒偏差（库默认）。用户机系统时间严重错乱不在平台可控范围，若怀疑此项，让用户在宿主会话内重试并核对本机时间。

### 3.3 排查面

**「继承静态头」自查（复现 U2 ④ 的字段级深合并）**

```sh
cd ~/Documents/CGC-2046            # Windows: %USERPROFILE%\Documents\CGC-2046
opencode debug config | jq -c '.mcp["cgc-2046"], .permission'
```

- 正常（干净机器）：条目里只有 `type` / `url` / `oauth.clientId`，**没有** `headers`；`permission` 含 `cgc_2046_confirm_operation: "ask"` 与 `read` / `external_directory` 下对宿主凭证目录的 `deny`。
- 异常：出现 `headers.Authorization`（来源是全局 `~/.config/opencode/opencode.json` 里的同名旧条目）→ 宿主会一直走静态 token，OAuth 永远不会触发。处置：在用户确认下删除全局配置里的同名条目（或改其名），重启宿主后重新打开学习空间。

**凭证存放位置**

```sh
opencode debug paths     # data = ~/.local/share/opencode（凭证文件 mcp-auth.json 在此，0600）
```

凭证按 OS 用户共享，与工作台无关。共用电脑的卸载口径见 §5。

**平台侧可见面**

- web：工作台 MCP 页与用户级「连接与授权」页并列展示连接令牌与已授权应用；授权状态派生为 `active`（可用）/ `idle_expired`（闲置超窗）/ `revoked`（已撤销）/ `pending`（已同意未换凭证），并显示最近使用时间。撤销后 web 即时反映（无推送通道，宿主在下一次调用时才得到 401）。
- ops：`https://codingirlsclub.com/ops/admin`（platform admin）可查 `accounts` 资源组下的 OAuth 客户端、授权码、刷新令牌链与同意行；刷新链每行一条令牌，撤销粒度为链。
- 归因：工具调用日志带 `credential_type`（`:oauth` / `:token`），可据以区分两条路径的实际使用。

---

## 4. `OAUTH2_SIGNING_SECRET` 轮换

### 4.1 影响面（按代码核实）

该密钥有两处用途：签发/校验 access token（HS256），以及签署同意页的表单令牌。

| 面 | 轮换后行为 |
|---|---|
| 在途 access token（TTL 1 小时） | 立即验签失败 → 401 + 发现头 → 宿主刷新 → 无交互恢复（U2 ③ 实测：401→刷新约 1 秒） |
| 刷新令牌链 | **不受影响**：刷新令牌是不透明随机串，落库只存哈希，与签名密钥无关 → 不需要全体用户重新授权 |
| 进行中的同意页 | 表单令牌失效 → 该次授权需从宿主重新发起（用户在浏览器看到错误后重试即可） |

结论：轮换是**低风险常规操作**，不需要停机窗口，也不需要通知用户重新授权；只需避开正在做首次接入的用户高峰期。

### 4.2 步骤

```sh
cd backend && mix phx.gen.secret    # 生成新值；与会话密钥不同值（启动自检强制）
```

1. 更新 GitHub **production environment** 的 secret `OAUTH2_SIGNING_SECRET`（deploy workflow 的 `.kamal/secrets` 名单已含该键，且对 46 项做非空断言——漏配会在 kamal 之前红，旧容器继续服务）。
2. 合并到 main 触发 Deploy；pre-deploy 钩子会带着新密钥起容器跑 migrate/seed，随后切流。
3. 观察：切流后短期出现 401（属预期自愈路径），不应出现持续 401；平台日志无验签失败堆积；web「已授权应用」仍显示 `active`，最近使用时间继续推进。
4. 记录轮换日期与操作人（沿用 `docs/运维/私有教研Playbook部署.md` 的密钥维护记录方式）。旧值不需要保留期：新值部署成功且宿主恢复正常即视为轮换完成。

### 4.3 禁止事项

- 不得复用 `TOKEN_SIGNING_SECRET` 或 `SECRET_KEY_BASE`：启动自检 `Cgc2046.Oauth2Server.validate_secrets!/0` 会 raise，部署在切流前失败。
- 不得留空：`config/runtime.exs` 对三个 OAuth 值缺失即 raise（不设默认值，避免静默用错域名或复用密钥）。
- 不要为「让所有宿主强制重新授权」而轮换密钥：它的副作用是在途同意流程被打断，且做不到强制（刷新链与密钥无关）。要强制失效用 web 撤销。

---

## 5. 共用电脑：三步卸载口径

**三步缺一不可**，顺序建议如下：

1. **删除学习空间目录**——`~/Documents/CGC-2046`（Windows `%USERPROFILE%\Documents\CGC-2046`）。这是项目级作用域，删目录不影响宿主的全局配置与其他用途；但只是删掉了本地入口。
2. **web 撤销授权**——工作台 MCP 页「已授权应用」或用户级「连接与授权」页，两步确认撤销。撤销即时生效：下一次平台调用即 401，且重新授权必须重新过同意页（同意行已撤回）。
3. **宿主登出**——退出宿主账号/会话（或直接换 OS 账号使用）。宿主的凭证库按 OS 用户共享（`~/.local/share/opencode/mcp-auth.json`），不登出则下一位使用者可直接继承凭证继续调用。

只做第 1 步的后果：平台侧凭证仍有效，任何拿到该机器的人都能继续以本人身份调用平台（直到对方主动撤销或闲置超窗）。只做第 2 步的后果：本地入口还在，下一次打开会重新发起授权，新的授权对象是当时的登录用户。

引导与包内文案的现状（2026-09-15 核实）：包内 `learn-space/README.md` 的「卸载」小节已覆盖第 1、2 步；第 3 步（宿主登出）与共用电脑提示**尚未**写入包内 README 或引导页文案——口径以本节为准，客服与运维按三步回复；包内/引导文案的补齐记为待办（属 U7/U8 资产，不属本手册范围）。

---

## 6. 首次发布与例行发布检查清单

**首次发布（OAuth 面）**

- [ ] GitHub production environment secrets 含 `OAUTH2_SIGNING_SECRET`（非空，且不与 `TOKEN_SIGNING_SECRET` / `SECRET_KEY_BASE` 同值）。
- [ ] `backend/config/deploy.yml` 的 `OAUTH2_ISSUER_URL`（裸域 web 域）与 `OAUTH2_RESOURCE_URL`（api 域 `/mcp`）与包内 `learn-space/opencode.json` 的 `mcp.cgc-2046.url` **同值**（ADR-0013 §3.1）。
- [ ] 主域 `/oauth` 与 `/.well-known/oauth-authorization-server` 路径路由生效（oauth role），登录 cookie 能到达授权页。
- [ ] 迁移已应用、seeds 已跑（pre-deploy 钩子日志可见），打包预注册 client 已落库。
- [ ] `https://api.codingirlsclub.com/.well-known/oauth-protected-resource` 可取且 `resource` 与配置同值。
- [ ] 真机走完五步旅程（安装 → 模型 → 打开学习空间 → 授权 → 验证），macOS 与 Windows 各一次。

**例行发布（学习空间包）**

- [ ] 包内容变更已 bump `learn-space/VERSION`。
- [ ] `learn-space/bin/pack` 本地通过（清单全等 + 禁入项为零）。
- [ ] 发布后三键 JSON 可取、zip 的 sha256 与 JSON 一致（§1.4）。
- [ ] `mix.lock` 有变更时，CI `deps-image` job 已绿再合 main。

**例行发布（backend / 无包变更）**

- [ ] `mix.lock` 无变更时不需要处理 deps 镜像；有变更按上一条。
- [ ] OAuth 面变更（授权、撤销、活跃性回查、密钥）需走一次真机走查：授权 → 调用 → 撤销 → 重新授权。
