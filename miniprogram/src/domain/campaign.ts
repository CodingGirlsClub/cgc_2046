/**
 * campaign 页（R19，微信端专属）与发现页入口卡的落地动作单源：三入口跳转目标、
 * 品牌邮箱复制。文案与内容留在页面（静态营销页），判据与调起落在本模块——小程序
 * 没有页面渲染测试，逻辑必须下沉 domain（AGENTS.md）。
 *
 * Taro 作为参数注入（同 domain/entry 的两条启动路径）：纯函数测试打不到「谁按哪个
 * 入口调了什么」。
 */

import { buildInitiativeSharePath } from './share-route'

/**
 * campaign 落地 Initiative：slug 由上线检查单（plan R16）创建，发布后不可改
 * （ADR-0014）——集中在这里，改一处即可。
 */
export const CAMPAIGN_INITIATIVE_SLUG = 'hackerstart1024'

/** 招募流页面路径（U10 实现；本单元只引用路径，不创建页面） */
export const VOLUNTEER_APPLY_PATH = '/pages/volunteer-apply/index'

/** campaign 页自身（发现页入口卡的落点；仅在微信端页清单登记，见 src/app.config.ts） */
export const CAMPAIGN_PAGE_PATH = '/pages/campaign/index'

/** 品牌合作收件邮箱（与 web 端 R3 的 mailto 同址；小程序出口 = 复制而非 mailto） */
export const CAMPAIGN_BRAND_EMAIL = 'partners@codingirlsclub.com'

/** 三入口定死：参加一场 / 成为志愿者 / 品牌合作 */
export type CampaignEntryKey = 'join' | 'volunteer' | 'brand'

/** 入口跳转目标；null = 无页面可跳（brand 走页内复制邮箱） */
export function campaignEntryUrl(key: CampaignEntryKey): string | null {
  switch (key) {
    case 'join': return buildInitiativeSharePath(CAMPAIGN_INITIATIVE_SLUG)
    case 'volunteer': return VOLUNTEER_APPLY_PATH
    case 'brand': return null
  }
}

/** 注入面：只取用到的三个方法（真 Taro 结构兼容，测试可传假实现） */
export interface CampaignTaro {
  navigateTo: (option: { url: string }) => unknown
  setClipboardData: (option: { data: string }) => Promise<unknown>
  showToast: (option: { title: string; icon: 'none' }) => unknown
}

/** 发现页入口卡 → campaign 页 */
export function openCampaignPage(taro: CampaignTaro): void {
  void taro.navigateTo({ url: CAMPAIGN_PAGE_PATH })
}

/**
 * 三入口的唯一落地口：join / volunteer 走 navigateTo；brand 复制邮箱。
 *
 * 小程序没有 web-view 业务域名，对外出口 = 剪贴板（先例 pages/openclacky）：
 * 复制成功由平台自带「内容已复制」toast，只有失败才自己提示。
 */
export function openCampaignEntry(taro: CampaignTaro, key: CampaignEntryKey): void {
  const url = campaignEntryUrl(key)
  if (url) {
    void taro.navigateTo({ url })
    return
  }
  void taro.setClipboardData({ data: CAMPAIGN_BRAND_EMAIL }).catch(() => {
    taro.showToast({ title: '复制失败，请手动记录', icon: 'none' })
  })
}
