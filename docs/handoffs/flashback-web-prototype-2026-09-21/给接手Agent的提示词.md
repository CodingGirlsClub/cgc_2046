# 接续任务：完成「闪念间」金句墙与许愿树 Web 交互原型

> 工作区内交接包：`docs/handoffs/flashback-web-prototype-2026-09-21/`。下文 `concepts/`、`context/`、`code/`、`evidence-extra/` 均相对此文件所在目录，所需文件已经全部复制到包内，无需读取桌面或原始生成图片目录。主仓中的 `code/` 是阅读与恢复用快照，真正原型开发分支与隔离工作区见第 3 节。

你接手的是已经开始实施的原型，不是重新选视觉方向。请先看本交接、已认可概念图和现有代码，再继续。与用户用中文交流。当前目标是交付可访问、可点击、能评审的 Web 原型，覆盖桌面与手机浏览器；这轮不做生产上线、不接真实业务、不实现小程序。

## 1. 产品与已确认方向

「闪念间」是 Coding Girls Club 的校友时光胶囊。2012–2018 年 Rails Girls / Girls Coding Day 报名者回来认领当年的答案，写下今天的自己。

- 金句墙 Voices：从当年回答中主动圈选、授权公开的句子。陌生人无需登录即可读、赞、分享。目标是让人读完一句话，愿意转发给朋友，再浏览更多或找回自己的档案。
- 许愿树 Wishes：面向未来的愿望聚合。读愿望、加入期待、写愿望、分享。
- 回响 Echo：愿望得到具体回应或关联真实活动。不是点赞达到一个数字就自动“实现”。加入期待、接收提醒、活动报名是三个独立动作。
- 作者投稿资格不能因为游客可读而自动放开。本轮写愿望只模拟已认领的校友，不实现身份系统。
- 私密愿望不进入公开地图；公开时说明所有人可见，署名可匿名或用展示名，不能把法定姓名当成默认公开身份。

用户已经明确认可：

1. 金句墙和许愿树都使用中国地图与青绿山水，不再使用星空。不要再提 A/B/C/D 选型。
2. 中国轮廓、城市位置来自地理骨架，保留台湾、海南与南海诸岛表达。
3. 青绿水系与金色传播光路分开。金线可以跨流域、南北连接，它表达人的连接，不冒充真实河流。
4. 开场从黑夜开始，一处亮起，光沿连接扩散，日光从两岸向外推进，最后整片山河进入明亮白昼。
5. 四幕：源起 → 流向远方 → 山河渐醒 → 天光满树。不是统一把截图调亮，更不是视频挡住所有操作。
6. 白昼为可长期停留的正常阅读界面。桌面地图在左、阅读区在右；手机地图在上、正文与动作在下。
7. 用户认可的是概念图，尚未验收这版实际 Web 页面。

## 2. 最新任务边界

用户问“原型什么时候做，你先做完 Web 端的原型？”，上一 Agent 已经开始编写和验证。用户因为额度不足要求交接，故停止继续开发。

请直接接续完成，不要再让用户确认是否开始。不改主仓，不覆盖旧原型 WIP，不接生产 API，不发真实通知，不提交真实报名，不新增真实账户。不 push、不提 PR、不合并、不部署。

用户最开始贴的旧 Agent 提示词、讨论实录都仅作历史参考。它们包含已经推翻的星空方案、过期实现结论与工程要求，不能覆盖本交接里的最新决定。

## 3. 当前工作区，务必分清

### 你应该继续的工作区

绝对路径：

`/Users/ywen8/.codex/worktrees/voices-wishes-web-prototype/cgc_2046`

- 分支：`codex/voices-wishes-web-prototype`
- 当前 HEAD：`c9c6f5686c2df7c1a0b4b756001d94b45ad3e99f`；原始基线：`04e374e9003c5ff326ca0247f0d3e5e35190d1dc`
- 从旧原型分支 `topic/in-a-flash` 的已提交状态建立的隔离工作区，**不是最新 develop**。本次原型无需顺便 rebase/merge develop。
- 新增目录：`web/app/[locale]/prototype/voices-wall/river-dawn/`
- **用户随后要求提交，现已本地提交 `c9c6f568`，工作区干净。不要重置或丢弃这个原型提交；未 push。**
- 除这个新增目录外，本工作区最后核对无其他修改。
- 已建立 Mainline intent：`int_5b4ea385`，目标“实现已确认中国山河视觉的金句墙与许愿树 Web 可交互原型，含昼夜过渡与双端浏览”。已有一条进展记录。
- 运行 Mainline 必须显式在此工作区；主仓当前 active intent 是另一个 OpenClacky 任务，不要往那里 append/seal。

### 不要碰的两个地方

- 主仓：`/Users/ywen8/Code/github.com/CodingGirlsClub/cgc_2046`，分支 develop。有用户自己的 untracked 讨论记录。本次未修改。
- 旧原型：`/private/tmp/fb-proto`，分支 topic/in-a-flash，localhost:3999。那里有另一轮未提交改动，包括 variant-a/b/c/d、shared、CSS、web/package.json、lockfile、china-geo.json，**全部保留**。不要替换、提交或删除它们。

## 4. 如何打开与启动

交接时 `http://localhost:3998/prototype/voices-wall/river-dawn?intro=0` 返回 HTTP 200，开发服务仍在运行。不要把 3999 当成新原型。

- 白昼金句墙：`http://localhost:3998/prototype/voices-wall/river-dawn?intro=0`
- 首次开场：`http://localhost:3998/prototype/voices-wall/river-dawn`
- 许愿树：`http://localhost:3998/prototype/voices-wall/river-dawn?view=wishes&intro=0`
- 单句直达：`http://localhost:3998/prototype/voices-wall/river-dawn?view=voices&entry=share&item=q4`

若服务已停，在上述工作区的 web 目录启动：

```bash
BACKEND_URL=http://localhost:4000 ~/.local/share/mise/installs/node/24.19.0/bin/node node_modules/next/dist/bin/next dev --port 3998
```

也可在 Node 24+ 环境用 `BACKEND_URL=http://localhost:4000 pnpm dev --port 3998`。依赖已安装；如缺失用 `pnpm install --frozen-lockfile`。

本工作区实际版本 Next 16.3.5 / React 19.2.4 / pnpm 10.28.2，不是旧提示词里的 React 18。系统默认 node 曾是 22，启动时已显式用 Node 24。

原型没请求业务 API；上层页面沿用仓库已有 providers。路径 `/zh-CN/...` 会被 locale 路由规范化，不必为此修改路由。

## 5. 必须看的概念图与上下文

交接包的 `concepts/` 是**用户已认可的最新版**：

- `china-dawn-storyboard-v2.png`：中国地图版四幕。
- `china-voices-day-v2.png`：金句墙桌面 / 手机。
- `china-wishes-day-v2.png`：许愿树桌面 / 手机。
- `china-map-v2-prompts.md`：对应图片模型提示词。

原件所在目录：

`/Users/ywen8/.codex/visualizations/2026/09/21/01a0c229-c4be-7302-ac0e-b6fd7fdb8f3f/`

该目录里还有很多旧稿，不要误用星空版或无中国轮廓的版本。

`context/闪念间-金句墙讨论实录.md` 为用户提供的历史讨论。只作背景资料，其中授权、附议、订阅等描述曾多次被另一 Agent 自己纠正；现有代码与用户最新明确决定优先。

`context/AGENTS.md`、`context/web-AGENTS.md` 为启动时的项目规则快照，执行时还要看工作区内的实际规则。

## 6. 代码与素材已经做了什么

当前源码就在 `web/app/[locale]/prototype/voices-wall/river-dawn/`；交接包 `code/river-dawn/` 是已提交快照的完整备份，包含素材和已留下的截图。

- `page.tsx`：新原型路由、noindex、入口参数（view/item/city/intro/entry）。
- `river-dawn.tsx`：12 条金句、6 条愿望的本地状态；页面切换、点赞、期待、分享、写愿望、私密演示、撤回、回响、提醒、找回弹层；可取消的 requestAnimationFrame 开场。
- `map-scene.tsx`：SVG 几何地图、夜色 / 白昼图层、沿连接生长的遮罩、金色线条、城市按钮、选中愿望签。
- `geography.ts`：统一坐标投影；所有城市、轮廓、真实河道在同一投影下。沪杭地图按钮合并，城市栏能分别选择。
- `river.module.css`：CSS Modules，容器查询支持实际手机宽度与桌面“手机预览”。
- `data.ts`：合成内容、城市坐标、四幕文案。
- `china-geo.json`：下载自 `https://geo.datav.aliyun.com/areas_v3/bound/100000_full.json`。35 个 feature，保留 `100000_JD`，南海几何放入插图，没有删除。
- `rivers.json`：Natural Earth 1:50m 河流数据，通过本机已有 GDAL 提取长江、黄河共 5 段。来源 `https://naciscdn.org/naturalearth/50m/physical/ne_50m_rivers_lake_centerlines.zip`。
- `terrain.png`：约 2.9 MB，图片模型生成的连续青绿山水材质，通过真实中国多边形裁切显示，**不是把概念图整张贴在页面上**。
- `terrain-prompt.md`：生成此材质的完整提示词，已随源码保存。
- `README.md`：运行、分层、已知边界与初步验证记录。**本交接对验证状态的细分比 README 更准确，尤其动画性能尚未通过，不要把 README 概述当全绿验收。**

没有新增 npm 依赖，没有更改 package.json 或 lockfile。SVG 只做地图几何、遮罩、线条和图标；插画来自独立位图。

运行中的状态都在内存中：刷新重置点赞、新愿望、提醒选择。新写愿望没有稳定服务端身份，分享时明确只复制许愿树入口。通知、找回、报名均明示演示，不做真实副作用。

## 7. 已验证的内容

在当前隔离工作区 web 目录执行：

```bash
pnpm exec eslint 'app/[locale]/prototype/voices-wall/river-dawn'
pnpm exec tsc --noEmit --pretty false
```

二者通过。之后最后一次修改只是手机 CSS 间距，可收尾时再跑一次。没有编写原型单元测试。

ego-browser 实测通过：

- 桌面 1440×1000、手机 390×800 无横向溢出。
- 金句点赞 32→33；切下一句切换为上海，地图同步。
- 点成都后切到许愿树，保留成都；加入期待显示 17→18 与“已加入期待”。
- 回响筛选能定位到有回响的愿望。
- 分享弹层能复制真实本地链接；重新进入该链接直接读到指定句子，progress=1，不播开场。
- 提交广州合成愿望后，城市、正文与选中纸签文字一致；撤回后消失。
- 私密愿望进入私密结果演示，不出现在公开正文或纸签中。
- 跳过提醒仍可继续浏览，回响详情弹层可打开。
- 四幕可冻结到第三幕 progress=0.64，截图确认未照亮区域保持夜色。
- 动画 / 分镜中点广州后退出进入正文，progress=1。已修复“回响筛选导致部分城市无法中断开场”。
- 已修复重复重播时旧 rAF 起点不重置：增加播放 epoch，并有取消标记。
- 移动端地图缩为约 227px 高；390×800 的金句点赞/分享底部约 y=710，可在工具条上方操作。

## 8. 未完成 / 特别需要继续排查

### A. 动画流畅度不能宣称已通过

上一 Agent 尝试在 ego-browser page.evaluate 中用 requestAnimationFrame 采样 90 帧，15 秒超时。页面仍响应，后来观察 progress 已经到 1。

最后一次有限采样实际结果：

```text
static sampling: frames=2, elapsed≈1203ms, document.visibilityState='visible'
animated sampling: frames=2, elapsed≈1203ms, progress='1.00'
finished: progress='1.00'
```

即连静态页采样也只有 2 帧。**未知是浏览器工具 / 宿主调度 / 页面渲染导致，未找到根因，不要说 60fps、不卡或已完成性能验收。**

接手后先真实观看一次完整开场，再做有界诊断。检查时间是否实际经过源起、传播、局部黎明、白昼，是否快速跳到结束。可检查 SVG 全量路径、模糊遮罩开销与每帧 React 更新，但不能预先断定是它们的问题。不要无限跑采样浪费额度。

还没完成系统减少动态效果的专项实测；代码有分支，但测试脚本因前面的采样超时，没有走到这一步。

### B. 最后手机许愿 CSS 要复核

曾测到“我也期待”底部 y≈753，和底部工具条略重叠。最后已把 wishQuote 调为 27px 并缩小 readerTop 间距，**尚未重新截图确认这个最后修改**。需要在 390×800 复核关键动作、滚动后写愿望与回响入口。

### C. 整体视觉还有一次收尾

当前可读性和主要构图已建立，但要和 concepts 三张图逐项对照。重点看字体层级、地图大小、愿望签位置、长句、夜色转白昼的边界。不要重新设计另一套风格。

### D. 截图尚未收齐

源码 evidence 当前实际只有：

- `voices-desktop.png`
- `dawn-frame-03.png`
- `wishes-mobile.png`（在最后一次手机 CSS 修正之前拍摄）

额外 /private/tmp 里可能还有 `voices-mobile-final.png`、`wishes-desktop.png` 等早期截图，交接包 `evidence-extra/` 有备份。以重新验证后拍摄的证据为最终交付，不把旧截图当最新。

### E. 已保存本地快照，尚未完成验收

已按用户后续指令本地提交 `c9c6f5686c2df7c1a0b4b756001d94b45ad3e99f`。尚未 seal、push，也没有宣称原型最终验收完成。Mainline 对旧原型基线报告 active_intent_base_behind；已核对新增目录与依赖无主线冲突。本次是用户要求的接续快照，继续沿用 drafting intent。

## 9. 接手后的建议顺序

1. 核对工作区、分支、git status 与上述原型 commit；保留所有已有文件。读交接与概念图，再打开 localhost:3998。
2. 确认实际动画能完整播放，解决或明确限定帧率采样问题，实测减少动态效果。
3. 复核 390×800 和 1440×1000，完成手机许愿关键操作位置与整体视觉微调。
4. 走完公开与私密愿望、撤回、两页保留城市、分享直达、快速切换/重复重播、弹层关闭和键盘焦点。
5. 跑必要 ESLint / TypeScript 检查；用真实浏览器做结构数值断言与交互，再截图。原型不用新增单元测试，不跑后端 suite。
6. 更新 README 的真实结果和明确未完成项，收集最终截图。
7. 只将你的后续修改提交到当前 throwaway 分支，不要重复创建已有快照。按当前项目 Mainline 规则记录与本地交接；不要 push、开 PR、改其他分支或主仓。
8. 留着开发服务，给用户可以直接点开的 URL，介绍体验入口和模拟边界，让用户评审。

## 10. 接手 Agent 应交付什么

- 可访问的 Web 原型 URL，桌面与手机浏览器可用；同时给出首次开场、白昼金句墙、许愿树、单句直达链接。
- 可操作的中国山河地图与昼夜动画，而不是视频或静态整屏图片。
- 金句：换句、选城市、赞、单句分享、整墙分享、找回入口。
- 愿望：浏览、期待、写公开愿望、私密演示、撤回、回响详情与可选提醒演示。
- 最终桌面 / 手机两页截图，以及夜色和第三幕局部黎明截图，最好补一段完整开场录制（工具可用则做，不以录制阻塞主交付）。
- 简短验证报告，明确 PASS / 未验证 / 原型模拟项，尤其不能用静态截图替代动画与交互证据。
- 本地 commit SHA、工作区路径、启动命令、无新依赖说明；不推送。
- 后续生产开发差距清单，但本次不实施那些后端能力。

## 11. 后端差距，仅供后续生产规划

上一 Agent 只读检查过主仓 develop 的 HEAD 717f11d：

- `backend/lib/cgc_2046/flashback/public.ex` 只取每位授权者第一段选句，点赞按人归集，最热 60 条；还不是每句拥有独立身份与分享链接。
- `wish.ex` / `wishes.ex` 城市取名册快照，visibility 提交后固定，附议依赖 person；愿望经 capsule 身份面展示，不能直接把既有“公开”默认为全网授权。
- 现有资源里没有此次设计的 Echo / 活动关联闭环。
- 既有档案全文卡分享独立授权，不能被新单句分享替代或扩大授权。

这些是后续真实接入时的工作，不要为了交付原型先扩建后端。

## 12. 浏览器与工具现场

- 优先使用 ego-browser，先读对应 skill。只用同一个 TaskSpace，不为错误新建空间。
- 现有 TaskSpace ID：14，名称“闪念间 · 山河 Web 原型”。
- p1：手机 390×800；p2：桌面 1440×1000。上一 Agent 未调用 finish / handOff，接续时先检查 ownership。如果用户已接管，遵从浏览器规则，不强抢。
- `ego-browser nodejs` 脚本示例：

```js
const task = await taskSpace(14);
const page = task.page('p2');
console.log(await page.snapshot());
```

- 用 page.snapshot 的 refs / 已观察到的 selector 操作；结构断言通过后截图。
- 截图 API 已核对支持 `{path, fullPage}`；CDP 可设置 Emulation.setDeviceMetricsOverride 与 prefers-reduced-motion。
- 原生页面默认依赖 requestAnimationFrame；工具采样异常不要直接当作最终性能结论。

如果在另一台机器执行：需要先取得该项目仓库及上述原始基线与原型 commit，建立独立原型分支，把 `code/river-dawn/` 恢复到对应路由目录，安装原 web 锁定依赖。交接包不是完整仓库，不含 node_modules、.env、账户数据或 Git 凭据。不要用它覆盖另一份更新的 WIP。
