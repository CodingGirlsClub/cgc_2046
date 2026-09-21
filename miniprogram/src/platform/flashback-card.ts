import Taro from '@tarojs/taro'
import {
  recordCardLayout,
  recordCardModel,
  summaryCardLayout,
  summaryCardModel,
  type FlashbackCardMode,
  type RecordCardModel
} from '@/domain/flashback'
import type { FlashbackMyCard } from '@/domain/models'

/** 卡片离屏画布 id（页面需渲染 `<Canvas id=canvasId canvasId=canvasId type="2d" />`）。
 *  四态共用同一节点：`canvas.width/height` 是**画布像素**，与 CSS 尺寸无关——
 *  记录卡可超出 CSS 的 600×800 并正确导出长图（导出参数用画布尺寸）。 */
export const CARD_CANVAS_ID = 'fbShareCanvas'

const SERIF = "'Kaiti SC', 'STKaiti', 'Noto Serif SC', serif"

/** 摘要卡固定 3:4 竖版（R14 分享默认物）；记录卡尺寸由内容算出（见 recordCardLayout） */
const SUMMARY_W = 600
const SUMMARY_H = 800

type Ctx = CanvasRenderingContext2D

/** 节点查询 → 定画布尺寸 → 纸底/内框 → 自定义绘制 → 导出 → 存相册（含权限引导）。
 *  抛错语义：权限被拒走 showModal 引导设置；其余错误 toast。
 *  `truncated` = 内容超出画布上限被截尾（记录态）——保存成功文案据此变化，
 *  不让用户拿到一张缺尾巴的图却毫无察觉。 */
async function renderAndSave(W: number, H: number, draw: (ctx: Ctx) => void, truncated = false): Promise<void> {
  const query = Taro.createSelectorQuery()
  const node = await new Promise<{ node: unknown; width: number; height: number }>((resolve, reject) => {
    query
      .select(`#${CARD_CANVAS_ID}`)
      .fields({ node: true, size: true }, (res: { node?: unknown; width?: number; height?: number }) => {
        if (res?.node) resolve(res as { node: unknown; width: number; height: number })
        else reject(new Error('画布未就绪'))
      })
      .exec()
  })
  const canvas = node.node as { getContext: (t: '2d') => Ctx; width: number; height: number }
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')

  // 纸底 + 内框
  ctx.fillStyle = '#f6f2e8'
  ctx.fillRect(0, 0, W, H)
  ctx.strokeStyle = 'rgba(43,39,35,0.25)'
  ctx.lineWidth = 2
  ctx.strokeRect(24, 24, W - 48, H - 48)

  draw(ctx)

  const res = await Taro.canvasToTempFilePath({
    canvas: canvas as never,
    x: 0,
    y: 0,
    width: W,
    height: H,
    destWidth: W,
    destHeight: H
  })
  try {
    await Taro.saveImageToPhotosAlbum({ filePath: res.tempFilePath })
    Taro.showToast({
      title: truncated ? '已保存到相册（尾部有省略）' : '已保存到相册',
      icon: truncated ? 'none' : 'success'
    })
  } catch (error) {
    const text = `${error instanceof Error ? error.message : ''} ${String((error as { errMsg?: string } | null)?.errMsg ?? '')}`
    if (/auth|deny|denied|权限/i.test(text)) {
      Taro.showModal({
        title: '需要相册权限',
        content: '请在设置中允许「保存到相册」后重试',
        confirmText: '去设置',
        success: ({ confirm }) => {
          if (confirm) void Taro.openSetting({})
        }
      })
    } else {
      Taro.showToast({ title: '保存失败，请重试', icon: 'none' })
    }
  }
}

/** 摘要卡（金句版式，居中）：R14 定稿的分享默认物 */
function drawSummary(ctx: Ctx, me: FlashbackMyCard): void {
  const model = summaryCardModel(me)
  const layout = summaryCardLayout(model, SUMMARY_W, SUMMARY_H)

  ctx.textAlign = 'center'
  ctx.textBaseline = 'top'

  ctx.fillStyle = '#2b2723'
  ctx.font = `600 22px ${SERIF}`
  ctx.fillText('IN A FLASH · 闪念间', SUMMARY_W / 2, layout.kickerTop)
  ctx.fillStyle = 'rgba(43,39,35,0.7)'
  ctx.font = `20px ${SERIF}`
  ctx.fillText(model.stamp || '当年', SUMMARY_W / 2, layout.stampTop)

  ctx.fillStyle = '#2b2723'
  ctx.font = `italic 30px ${SERIF}`
  layout.quoteLines.forEach((line, index) => ctx.fillText(line, SUMMARY_W / 2, layout.quoteTop + index * layout.quoteLineHeight))

  if (layout.todayLines.length) {
    ctx.strokeStyle = 'rgba(43,39,35,0.25)'
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(140, layout.dividerY)
    ctx.lineTo(SUMMARY_W - 140, layout.dividerY)
    ctx.stroke()
    ctx.fillStyle = 'rgba(43,39,35,0.85)'
    ctx.font = `22px ${SERIF}`
    layout.todayLines.forEach((line, index) =>
      ctx.fillText(line, SUMMARY_W / 2, layout.todayTop + index * layout.todayLineHeight)
    )
  }

  ctx.fillStyle = 'rgba(43,39,35,0.5)'
  ctx.font = `16px ${SERIF}`
  ctx.fillText(model.footer, SUMMARY_W / 2, layout.footerTop)
}

/** 记录卡（题干 + 逐句，左对齐）：动态高度、内容完整；雾句画灰块——
 *  与预览（`rvFog`）和校友墙（`viewFog`）同语言，不丢句子。 */
function drawRecord(ctx: Ctx, model: RecordCardModel, layout: ReturnType<typeof recordCardLayout>): void {
  const { W } = layout
  const pad = 60

  ctx.textBaseline = 'top'
  ctx.textAlign = 'center'
  ctx.fillStyle = '#2b2723'
  ctx.font = `600 22px ${SERIF}`
  ctx.fillText('IN A FLASH · 闪念间', W / 2, layout.kickerTop)
  ctx.fillStyle = 'rgba(43,39,35,0.7)'
  ctx.font = `20px ${SERIF}`
  ctx.fillText(model.stamp || '当年', W / 2, layout.stampTop)

  // 正文左对齐（长文阅读；摘要卡的居中版式留给金句）
  ctx.textAlign = 'left'
  for (const block of layout.blocks) {
    ctx.fillStyle = 'rgba(43,39,35,0.55)'
    ctx.font = `20px ${SERIF}`
    ctx.fillText(block.title, pad, block.titleTop)
    for (const line of block.lines) {
      if (line.fogged) {
        ctx.font = `26px ${SERIF}`
        const w = Math.min(W - pad * 2, Math.max(48, ctx.measureText(line.text).width))
        ctx.fillStyle = 'rgba(43,39,35,0.2)'
        const top = line.top + 5
        const h = 26
        const r = 7
        ctx.beginPath()
        ctx.moveTo(pad + r, top)
        ctx.lineTo(pad + w - r, top)
        ctx.arcTo(pad + w, top, pad + w, top + r, r)
        ctx.lineTo(pad + w, top + h - r)
        ctx.arcTo(pad + w, top + h, pad + w - r, top + h, r)
        ctx.lineTo(pad + r, top + h)
        ctx.arcTo(pad, top + h, pad, top + h - r, r)
        ctx.lineTo(pad, top + r)
        ctx.arcTo(pad, top, pad + r, top, r)
        ctx.closePath()
        ctx.fill()
      } else {
        ctx.fillStyle = '#2b2723'
        ctx.font = `26px ${SERIF}`
        ctx.fillText(line.text, pad, line.top)
      }
    }
  }

  ctx.strokeStyle = 'rgba(43,39,35,0.25)'
  ctx.lineWidth = 2
  ctx.beginPath()
  ctx.moveTo(140, layout.dividerY)
  ctx.lineTo(W - 140, layout.dividerY)
  ctx.stroke()
  ctx.textAlign = 'center'
  ctx.fillStyle = 'rgba(43,39,35,0.5)'
  ctx.font = `16px ${SERIF}`
  ctx.fillText(model.footer, W / 2, layout.footerTop)
}

/** 保存卡片到相册（四态）。
 *
 *  - `summary`：金句版式，固定 600×800（为朋友圈/小红书设计）；
 *  - `today` / `past` / `both`：记录版式，高度由内容算出（完整保留，
 *    超上限截断——`recordCardLayout` 的 `truncated` 供调用方提示）。
 */
export async function saveFlashbackCard(me: FlashbackMyCard, mode: FlashbackCardMode = 'summary'): Promise<void> {
  if (mode === 'summary') {
    await renderAndSave(SUMMARY_W, SUMMARY_H, (ctx) => drawSummary(ctx, me))
    return
  }
  const model = recordCardModel(me, mode)
  const layout = recordCardLayout(model)
  await renderAndSave(layout.W, layout.H, (ctx) => drawRecord(ctx, model, layout), layout.truncated)
}
