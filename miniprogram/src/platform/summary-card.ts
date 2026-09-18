import Taro from '@tarojs/taro'
import { summaryCardLayout, summaryCardModel } from '@/domain/flashback'
import type { FlashbackMyCard } from '@/domain/models'

/** 摘要卡离屏画布 id（页面需渲染 <Canvas id=canvasId canvasId=canvasId type="2d" />） */
export const SUMMARY_CARD_CANVAS_ID = 'fbShareCanvas'

/**
 * 绘制并保存摘要卡（R14，用户定稿 ③）——旅程终点/我的页共用。
 *
 * 画布尺寸语义定式：node.width/height 是**布局尺寸（CSS px）**，而 canvas 后备
 * 存储默认仅 300×150：必须显式设 canvas.width/height = node.width/height，CSS
 * 尺寸即画布尺寸（600×800 = 3:4，1:1 无缩放，导出区域无歧义），绘制坐标与画布
 * 空间不错位。折行/版式判据在 domain（summaryCardModel/summaryCardLayout，
 * node --test 钉住），这里只按结果绘制。
 *
 * 抛错语义：权限被拒走 showModal 引导设置；其余错误 toast（调用方只管 saving 态）。
 */
export async function saveFlashbackSummaryCard(me: FlashbackMyCard): Promise<void> {
  const model = summaryCardModel(me)
  const query = Taro.createSelectorQuery()
  const node = await new Promise<{ node: unknown; width: number; height: number }>((resolve, reject) => {
    query
      .select(`#${SUMMARY_CARD_CANVAS_ID}`)
      .fields({ node: true, size: true }, (res: { node?: unknown; width?: number; height?: number }) => {
        if (res?.node) resolve(res as { node: unknown; width: number; height: number })
        else reject(new Error('画布未就绪'))
      })
      .exec()
  })
  const canvas = node.node as { getContext: (t: '2d') => CanvasRenderingContext2D; width: number; height: number }
  const W = node.width
  const H = node.height
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')
  const serif = "'Kaiti SC', 'STKaiti', 'Noto Serif SC', serif"

  // 纸底 + 内框
  ctx.fillStyle = '#f6f2e8'
  ctx.fillRect(0, 0, W, H)
  ctx.strokeStyle = 'rgba(43,39,35,0.25)'
  ctx.lineWidth = 2
  ctx.strokeRect(24, 24, W - 48, H - 48)

  ctx.textAlign = 'center'
  ctx.textBaseline = 'top'

  // 版式坐标全部来自 domain（summaryCardLayout：行数与位置，保证在画布内）
  const layout = summaryCardLayout(model, W, H)

  // kicker + 时间戳·城市（原型 F 摘要卡版式）
  ctx.fillStyle = '#2b2723'
  ctx.font = `600 22px ${serif}`
  ctx.fillText('IN A FLASH · 闪念间', W / 2, layout.kickerTop)
  ctx.fillStyle = 'rgba(43,39,35,0.7)'
  ctx.font = `20px ${serif}`
  ctx.fillText(model.stamp || '当年', W / 2, layout.stampTop)

  ctx.fillStyle = '#2b2723'
  ctx.font = `italic 30px ${serif}`
  layout.quoteLines.forEach((line, index) => ctx.fillText(line, W / 2, layout.quoteTop + index * layout.quoteLineHeight))

  if (layout.todayLines.length) {
    ctx.strokeStyle = 'rgba(43,39,35,0.25)'
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(140, layout.dividerY)
    ctx.lineTo(W - 140, layout.dividerY)
    ctx.stroke()
    ctx.fillStyle = 'rgba(43,39,35,0.85)'
    ctx.font = `22px ${serif}`
    layout.todayLines.forEach((line, index) =>
      ctx.fillText(line, W / 2, layout.todayTop + index * layout.todayLineHeight)
    )
  }

  ctx.fillStyle = 'rgba(43,39,35,0.5)'
  ctx.font = `16px ${serif}`
  ctx.fillText(model.footer, W / 2, layout.footerTop)

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
    Taro.showToast({ title: '已保存到相册', icon: 'success' })
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
