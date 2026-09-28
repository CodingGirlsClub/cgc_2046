# cgc-play

心流学习世界的终端游戏进程：在 Herdr 右窗格里渲染地点插画（Kitty Graphics，经 OpenTUI）与关卡 HUD，经本地 Unix socket 与 `cgc-2046` plugin 的 `cgc-play.ts` extension 交接。设计与范围见 #1005，本包实现 #1006。

## 分工

- **游戏进程（本包）**：拥有规则——关卡顺序、手关卡的确定性判定、情境状态。不调模型、不持凭证。
- **agent（OMP 左窗格）**：口头关卡的提问与判定，经 `game_apply` 回写结果；只能做两种合法动作（换情境 / 回写当前口头关卡结果），其余被引擎拒绝。

## 使用

```bash
bun install
bun test                 # 引擎 / schema / 协议 / socket
bun run start            # 载入内置的潜水课 c21「急救甲板」
bun run start -- --location path/to/location.json   # 载入其他地点（图片相对 JSON 所在目录）
bun run build            # 单文件可执行 dist/cgc-play
```

OMP 侧：装好 `cgc-2046` plugin 后，在 Herdr 里输入 `/cgc play`。开发时用 `CGC_PLAY_BIN=<dist/cgc-play 的绝对路径>` 指向本地构建。

需要支持 Kitty Graphics 的终端（Ghostty、kitty、WezTerm）才能看到插画；其他终端由 OpenTUI 降级为色块。

## 地点定义（schema v0）

一张卡 = 一个地点，关卡数 ≤ 该卡 checklist 条数。字段见 `src/location.ts`，样例见 `fixtures/c21/location.json`。

- `hand` 关卡：`kind` 为 `sequence`（按序排列 `answer`）或 `select`（选出全部 `answer`）；`distractors` 带解释与教材锚点，可选 `consequence` 指向一个情境状态（后果可挽回：改正即恢复）。
- `mouth` 关卡：`judge_questions` 是给 agent 的原子判据问题。

## socket 协议（NDJSON，`~/.cgc2046/play.sock`，0600）

| 方向 | 消息 |
|---|---|
| 请求 | `{"id":1,"op":"state"}` |
| 请求 | `{"id":2,"op":"apply","scene_state":"worse"}` 或 `{"id":3,"op":"apply","stage_result":{"stage":"c21-3","met":true}}`（二选一） |
| 应答 | `{"id":…,"ok":true,"state"?:…}` / `{"id":…,"ok":false,"error":"…"}` |
| 事件 | `{"ev":"mouth_stage","location","checklist","prompt","judge_questions"}`、`{"ev":"location_complete","location"}` |

## 占位素材

`fixtures/c21/*.png` 是程序生成的几何占位图，只用于验证渲染链路；正式插画由教研出图（#1011）。
