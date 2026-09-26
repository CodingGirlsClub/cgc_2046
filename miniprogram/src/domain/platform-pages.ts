/**
 * 平台页面注册名单唯一真源（P0-4 深链按平台过滤）。
 *
 * 此前两份名单只活在 `app.config.ts`，深链路由（`domain/share-route.ts`）按全量端
 * 页面做目标——裁剪端没注册的页面会让 `navigateTo` 静默失败（分享链接带
 * shareId / quoteId / wishId / token 即中招）。名单移到 domain 后：
 * `app.config.ts` 的 `pages` 声明与深链过滤从同一份读，新增页面只改一处。
 *
 * path 形状与 app.config 原样一致（`pages/...`，无前导斜杠）。
 */

/**
 * 路由平台键——与 `platform/index.ts` `currentPlatform()` / domain
 * `SubscriptionPlatform` 同族词表（`'wechat'` = 微信全量端；构建期
 * `process.env.TARO_ENV === 'weapp'` 在 app.config.ts 映射到本键）。
 */
export type RoutePlatform = 'wechat' | 'tt' | 'xhs'

/** 微信全量端（weapp）注册页面 */
export const WEAPP_PAGES: readonly string[] = [
  'pages/discover/index',
  'pages/initiative-detail/index',
  'pages/event-detail/index',
  'pages/login/index',
  'pages/register-form/index',
  'pages/enrollment-result/index',
  'pages/order-pay/index',
  'pages/privacy/index',
  'pages/my-enrollments/index',
  'pages/workspace/index',
  'pages/profile/index',
  'pages/join/index',
  'pages/openclacky/index',
  // #508-A：主理人现场核销（管理面，裁剪端不挂）
  'pages/check-in/index',
  // R19：campaign 宣传页（微信端专属——发现页入口卡同款分流，见 pages/discover/index）
  'pages/campaign/index',
  // R20/R21：志愿者招募流（微信端专属——campaign 页「成为志愿者」入口的落点；
  // 审核面板不进小程序，管理面在 web）
  'pages/volunteer-apply/index',
  // U9/R28：闪念间主容器=长廊（页内 Tab：时间廊|我的卡，U2 完整化后卡面单源
  // 在 components/MyCard）。旧独立页仅保留给裁剪端（tt/xhs 未注册长廊，diversion
  // 词表限制），微信端不再注册。
  'pages/flashback-journey/index',
  'pages/flashback-corridor/index',
  'pages/flashback-event/index',
  'pages/flashback-today/index',
  // #771：公开卡页（朋友视角）——微信端专属：它只由分享链接进入，裁剪端
  // 无闪念间深度场景，且页内「卡片站外公开」文案含跨端词（check:diversion）
  'pages/flashback-shared-card/index',
  'pages/flashback-voices/index',
  'pages/flashback-wishes/index',
  'pages/flashback-wish-write/index',
  'pages/flashback-my-wishes/index'
]

/** 抖音裁剪端（tt）注册页面 */
export const TT_PAGES: readonly string[] = [
  'pages/discover/index',
  'pages/initiative-detail/index',
  'pages/my-enrollments/index',
  'pages/event-detail/index',
  'pages/login/index',
  'pages/register-form/index',
  'pages/enrollment-result/index',
  'pages/join/index',
  // U9/R28：闪念间回访页（薄壳，渲染 components/MyCard）——tt/xhs 漏斗端注册
  // （成场通知深链与「我的」入口）。首程旅程/长廊/场次页**只在微信全量端注册**：
  // 闪念间深度场景不存在于裁剪端，且页面文案含跨端词（check:diversion）。
  'pages/flashback/index'
]

/**
 * 小红书裁剪端（xhs）注册页面（P0-5 起与 tt 分叉；P2 注册闪念间全家桶）：
 * Tab = 发现 / 闪念间（长廊）/ 我的（与 XHS_TABS 同源口径，「我的」为第三项，
 * 我的报名随之降级为普通页）；隐私页按 D7 变体正文注册（开发者协议 4.3
 * 硬要求，登录页《隐私授权说明》可点开）。
 */
export const XHS_PAGES: readonly string[] = [
  'pages/discover/index',
  'pages/initiative-detail/index',
  'pages/profile-lite/index',
  'pages/my-enrollments/index',
  'pages/event-detail/index',
  'pages/login/index',
  'pages/privacy/index',
  'pages/register-form/index',
  'pages/enrollment-result/index',
  'pages/join/index',
  // P2 闪念间全端：本人面（长廊/首程/场次/今天）+ 公开面（金句墙/许愿树/公开卡）+
  // 写面（写愿望/我的愿望）。组织者与管理页仍不注册（原则①）。
  'pages/flashback-corridor/index',
  'pages/flashback-journey/index',
  'pages/flashback-event/index',
  'pages/flashback-today/index',
  'pages/flashback-voices/index',
  'pages/flashback-wishes/index',
  'pages/flashback-shared-card/index',
  'pages/flashback-wish-write/index',
  'pages/flashback-my-wishes/index',
  // 旧回访薄壳页保留：深链回落目标（platformFallbackRoute）与旧分享链落点
  'pages/flashback/index'
]

export function pagesForPlatform(platform: RoutePlatform): readonly string[] {
  if (platform === 'tt') return TT_PAGES
  if (platform === 'xhs') return XHS_PAGES
  return WEAPP_PAGES
}

/** path（可带前导斜杠 / 尾部 query）是否本端已注册页面 */
export function pageRegistered(path: string, platform: RoutePlatform): boolean {
  const normalized = path.replace(/^\/+/, '').split('?')[0]
  return pagesForPlatform(platform).includes(normalized)
}
