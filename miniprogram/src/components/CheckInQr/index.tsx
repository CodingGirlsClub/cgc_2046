import { useEffect, useRef, useState } from 'react'
import { Canvas } from '@tarojs/components'
import Taro from '@tarojs/taro'
import QRCode from 'qrcode'

interface Props {
  /** 核销 payload（domain/checkin.buildCheckInPayload 产物） */
  payload: string
  /** canvas 占位边长（px）；二维码本体留白 1 模块 */
  size?: number
}

interface CanvasNode {
  width: number
  height: number
  getContext: (type: '2d') => CanvasRenderingContext2D
}

/**
 * 参与者核销二维码（#508 选项 A）：`qrcode`（MIT）纯 JS 矩阵 + canvas 2d 自绘，
 * 零后端依赖。渲染失败（老基础库无 canvas 2d、节点未就绪重试后仍取不到等）
 * 返回 null——调用方的 6 位文本码照常出示，主理人手输兜底（KTD5「扫码失败补救」）。
 */
export function CheckInQr({ payload, size = 160 }: Props) {
  // id 须页面级唯一（同屏多张报名卡各挂一码）：payload 尾段即核销码，天然区分
  const canvasId = useRef(`checkin-qr-${payload.slice(-6)}-${Math.random().toString(36).slice(2, 8)}`)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    let cancelled = false

    const queryNode = async (): Promise<{ node: CanvasNode; width: number; height: number }> => {
      // 首帧 native canvas 可能尚未就绪：nextTick 后查一次，失败再宽限一拍
      for (let attempt = 0; attempt < 2; attempt += 1) {
        await new Promise((resolvePromise) => {
          if (attempt === 0) Taro.nextTick(resolvePromise)
          else setTimeout(resolvePromise, 300)
        })
        if (cancelled) throw new Error('cancelled')
        const [result] = (await Taro.createSelectorQuery()
          .select(`#${canvasId.current}`)
          .fields({ node: true, size: true })
          .exec()) as unknown as Array<{ node?: CanvasNode; width: number; height: number } | null>
        if (result?.node) return { node: result.node, width: result.width, height: result.height }
      }
      throw new Error('canvas node not found')
    }

    const draw = async () => {
      try {
        const matrix = QRCode.create(payload, { errorCorrectionLevel: 'M' }).modules
        const { node, width, height } = await queryNode()
        if (cancelled) return

        const dpr = Taro.getWindowInfo().pixelRatio || 1
        node.width = width * dpr
        node.height = height * dpr

        const ctx = node.getContext('2d')
        ctx.scale(dpr, dpr)
        ctx.fillStyle = '#ffffff'
        ctx.fillRect(0, 0, width, height)

        const count = matrix.size
        const quiet = 1
        const cell = Math.min(width, height) / (count + quiet * 2)
        ctx.fillStyle = '#000000'
        for (let row = 0; row < count; row += 1) {
          for (let col = 0; col < count; col += 1) {
            if (matrix.get(row, col)) {
              ctx.fillRect((quiet + col) * cell, (quiet + row) * cell, cell, cell)
            }
          }
        }
      } catch {
        if (!cancelled) setFailed(true)
      }
    }

    void draw()
    return () => { cancelled = true }
  }, [payload])

  if (failed) return null
  return (
    <Canvas
      type='2d'
      id={canvasId.current}
      style={{ width: `${size}px`, height: `${size}px` }}
      data-testid='check-in-qr'
    />
  )
}
