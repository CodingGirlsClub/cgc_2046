# 金句墙第一批验收

范围：新增微信端原生金句墙；原「闪念间」增加一个入口；个人公开分享卡增加「看更多声音」。原有找回、卡片、长廊和许愿流程沿用。新用户许愿、许愿树与圆梦线属于后续批次。

## 人工验收（本批通过后才进入下一批）

微信开发者工具打开本 worktree 的 `miniprogram/`。当前构建连接本地隔离后端，内容全部为合成示例，不是历史用户数据。

| 步骤 | 操作 | 预期 |
| --- | --- | --- |
| 1 | 进入「闪念间」，点击「金句墙」入口 | 入口清楚；原有长廊保留；无需登录可读墙 |
| 2 | 查看地图和正文，上一句／下一句／随便听一听 | 句子、署名、地图城市一起切换；长句可读 |
| 3 | 点击城市，或用固定的「全部城市」面板选择城市 | 只显示该城市金句；选择「全部」可清除筛选 |
| 4 | 点赞、离开再回来、取消点赞 | 数量和本人状态回显；点赞不突然换句 |
| 5 | 查看署名旁的「分享」和「分享整墙」和页尾出口 | 单句链接打开对应句子；整墙链接不锁定句子；「找回」回到现有闪念间 |

重点反馈：入口是否突兀、地图高度、正文大小、换句操作是否顺手。微信好友会话内的真实转发和真机显示仍需人工验收；自动化只验证原生分享回调和落地路由，不代发消息。

## 可重复验证

在 `miniprogram/` 执行，微信开发者工具需已登录并授权 `Codex`：

```bash
CGC_E2E_MOCK=true ./node_modules/.bin/taro build --type weapp
wechatide -c Codex simulator_refresh --project "$PWD"
node e2e/flashback-voices.e2e.mjs
```

Mock 验证 18 项：匿名阅读、赞/取消、前后换句、随机、城市筛选、单句/整墙分享、热门列表外单句、撤回、网络错误/重试、原长廊入口和关闭的个人分享卡出口。工具每次调用至少间隔 1.5 秒，遵守 DevTools 60 次/分钟限制。

真实接口验收仅使用 `codex/mp-voices-batch-1` 的隔离开发数据库。首次在该 worktree 的 `backend/` 创建、迁移数据库后，执行一次合成数据脚本：

```bash
mix ecto.create
mix ecto.migrate
mix run ../miniprogram/e2e/fixtures/voices.exs
PORT=4107 mix phx.server
```

另一个终端在 `miniprogram/`：

```bash
CGC_E2E_MOCK=false CGC_GRAPHQL_ENDPOINT=http://127.0.0.1:4107/api/graphql ./node_modules/.bin/taro build --type weapp
wechatide -c Codex simulator_refresh --project "$PWD"
node e2e/flashback-voices.e2e.mjs --live
```

真实验证覆盖 HTTP 内容对照、赞/取消入库、重入后的本人状态、城市筛选、分享定位、失效链接、现有入口；冷/热启动的入口决策由纯函数回归测试覆盖，微信会话真实唤起留待人工验收。证据输出到忽略入库的 `e2e/artifacts/voices/`：`result.txt`、`live-result.txt`、截图。

其他检查：`npm run test:unit`、`tsc --noEmit`、codegen 新鲜度、三端构建、依赖许可及裁剪端零导流；后端 `mix precommit`。本批服务端给公开金句列表增加可选城市筛选，并提供仅含公开金句所在城市的目录；两者均保持已有授权/撤下过滤，不受热门 60 条截断影响。

本地接口地址仅供模拟器验收，手机无法直接使用电脑的回环地址。没有上传体验版或发布。


## 本轮排版反馈

- 图例沿用当前 Web 文案：「青绿 · 山河来处」「金线 · 句长成树」。
- 原主分享按钮改为「随便听一听」，单句分享移到署名右侧、主按钮上方，无深色底。
- 授权说明为一行：「经本人选择并授权公开，赞是一份共鸣，无需登录。」
- 正文 `42rpx / 1.6`，自然高度，不截断、不折叠、不按长度缩字。没有新增任何字数上限。

390px 宽模拟器实测：正文宽 350px、实际字号 21px、行高 33.6px。32 / 51 / 84 / 130 个字符（含标点）分别占 2 / 4 / 6 / 9 行。建议内容优先 30～60 字；60～80 字仍可读，超过 80 字更接近短段落。保留地图时，约 30 字能让主要操作留在首屏，约 50 字需要轻滑，不承诺所有内容和操作都挤进首屏。换行、英文、标点和设备宽度会影响实际行数。

布局样例首次在隔离 backend 执行 `mix run ../miniprogram/e2e/fixtures/voices-layout.exs`，随后在 miniprogram 执行 `node e2e/voices-layout.mjs`，验证原文完整、正文与控件不重叠、分享在随机按钮上方、说明单行，输出几何测量和截图到 `e2e/artifacts/voices/layout/`。


## 30 个城市交互

金句墙专用 `flashbackVoiceCities` 按拼音列出有公开金句的城市，与全国城市表单名单分开。授权关闭、单句/授权撤下、档案删除后不计入，不依赖热门 60 条。

城市条横滑，右侧「全部城市」固定；底部 4 列面板和横滑条共享筛选状态；选择城市后关闭面板并自动定位选中项；换句不改变筛选。点击「随便听一听」仍执行全墙随机浏览并回到「全部」。

本地 30 城验收：先在隔离 backend 执行 `mix run ../miniprogram/e2e/fixtures/voices-cities.exs`，小程序使用真实本地接口构建，然后在 miniprogram 执行 `node e2e/voices-cities.mjs`。该脚本以原生点击、滚动和数值断言验证，结束停在 WeChatIDE 城市面板，不生成截图。验收以 WeChatIDE 为准。
