# 山河渐醒：Web 交互原型

已确认视觉：中国地图、青绿山水、金色连接、从黑夜进入白昼。此目录为 throwaway 原型，不接生产业务；原型验证的是阅读、探索和操作是否顺畅。

## 启动

在本工作区 `web/` 下使用 Node 24+：

```bash
pnpm install --frozen-lockfile
BACKEND_URL=http://localhost:4000 pnpm dev --port 3998
```

原型内容不请求业务 API。上层应用保留原有 provider。

- 首次进入：`http://localhost:3998/prototype/voices-wall/river-dawn`
- 白昼金句墙：`http://localhost:3998/prototype/voices-wall/river-dawn?intro=0`
- 白昼许愿树：`http://localhost:3998/prototype/voices-wall/river-dawn?view=wishes&intro=0`
- 分享直达：`http://localhost:3998/prototype/voices-wall/river-dawn?view=voices&entry=share&item=q4`

桌面底部可开启 390px 手机预览；浏览器实际缩窄时同样进入移动布局。底部提供首次进入、四幕分镜和分享直达。分镜按钮可停在指定画面，重播会恢复自动播放。

## 已覆盖的旅程

- 约 6.4 秒昼夜开场，可跳过、重播、选帧、通过点城市中断；系统减少动态效果时直接进入白昼。
- 分享链接直接定位指定合成句子；返回或刷新已带 `intro=0` 的 URL 不再播放开场。
- 真实中国轮廓与城市坐标；沪杭地图点合并操作，城市栏可分别选择上海、杭州。
- 金句逐条浏览，地图跟随内容；本次体验内匿名点赞、取消点赞。
- 金句墙 / 许愿树切换保留城市；全页与单条的链接分享分开。
- 写公开愿望、选择城市与署名，新纸签与正文同步；可撤回。私密演示不进入公开集合。
- 加入期待、可跳过的提醒选择、回响详情、找回入口演示。

## 已知边界

- 12 条金句、6 条初始愿望均为合成示例。浏览、点赞、写愿望、提醒选择均使用内存状态，刷新后重置。
- 分享可以复制真实本地链接，但链接只在能访问此开发服务的设备上可用；新写愿望尚无服务端身份，分享它时只分享许愿树入口并明示原因。
- 找回、账号、活动、报名、通知只有明确标识的演示流程。不会创建真实活动、发送通知、注册账户或报名。
- 传播起点与顺序为示意，不代表经史料核实的活动发源地或传播路径。
- 自然地理骨架来自数据；山体高度与绘画纹理为美术表达。原型没有完成生产地图合规及素材使用条件审查。
- 没有接入小程序运行时，手机模式仅为响应式 Web。开发机帧率不能替代小程序真机性能验收。
- 已选定一种视觉方向，本次不再重做 A/B/C/D 风格变体。旧原型及其 WIP 完整保留在原工作区。

## 实现分层

- `page.tsx`：分享入口参数与 noindex。
- `river-dawn.tsx`：合成内容状态、交互、弹层、可取消的播放循环。
- `map-scene.tsx`：地图、昼夜遮罩、光路和可点击城市、愿望签。
- `geography.ts`：统一地理投影；中国轮廓、城市、河道采用同一坐标转换。
- `river.module.css`：统一 CSS Modules 样式；容器查询覆盖真实窄屏与桌面手机预览。
- `data.ts`：合成数据与四幕文案。

不新增 npm 依赖。SVG 用于真实地图几何、遮罩、连接线及图标；山水插画使用独立生成的位图材质，不把界面截图当背景。

## 素材来源

- `china-geo.json`：阿里云 DataV GeoAtlas `https://geo.datav.aliyun.com/areas_v3/bound/100000_full.json`，下载于 2026-09-21，35 个 feature；保留 `100000_JD`，台湾、海南及南海几何未删除，南海另设插图。
- `rivers.json`：Natural Earth 1:50m rivers/lake centerlines，来源 `https://naciscdn.org/naturalearth/50m/physical/ne_50m_rivers_lake_centerlines.zip`；使用本机已有 GDAL 提取长江、黄河的 5 个河段，不手绘冒充真实水系。
- `terrain.png`：内置 image_gen 生成的山水材质。提示词见 `terrain-prompt.md`。

金色连接是人与内容的示意网络，不是中国水系；青绿河道单独绘制。

## 验证记录

- `pnpm exec eslint 'app/[locale]/prototype/voices-wall/river-dawn'`：通过。
- `pnpm exec tsc --noEmit --pretty false`：通过。
- ego-browser 桌面 1440×1000 与手机 390×800：无横向溢出，移动端金句赞/分享位于首屏。
- 真实浏览器操作：点赞 32→33、换句切换城市、两页保留成都、愿望附议、回响筛选、复制分享链接并重新进入。
- 写入广州合成愿望后地图/正文/纸签一致；撤回后消失；私密愿望不进入公开集合；跳过提醒仍可继续浏览。
- 动画中断与第三幕选帧已验证；观察到自动播放进入白昼，但流畅度尚未通过验收。ego-browser 中 rAF 采样曾超时，静态页 1.2 秒也只采到 2 帧，原因未定。
- 系统减少动态效果分支尚未专项实测；手机许愿动作位置的最后一次 CSS 微调仍需复核。截图并非全部对应最终样式。
- 不编写原型单元测试，不修改后端，不推送分支。

截图在 `evidence/`。下一阶段由用户体验确认动画节奏与阅读操作，再按生产要求重新整理数据契约、授权与分享链路。
