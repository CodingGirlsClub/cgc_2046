/**
 * 订单状态轮询编排（R14：2s 间隔 × 30s 总窗，终态即停，超窗转手动态）。
 *
 * 从 /orders/[id] 页抽取的共享编排：决策全走 lib/payment.nextPollTick 纯函数
 * （fake timers 测试面在纯函数层），本 hook 只做定时器与累计耗时 state。
 * 订单页与收银模态框（payment-checkout-dialog）共用，保证两处轮询口径一致。
 *
 * onTick 需稳定引用（useCallback）——本 hook 的 effect 以 onTick 为依赖，
 * 内联箭头函数会每渲染重排定时器。
 */

import { useCallback, useEffect, useState } from "react";
import { POLL_TOTAL_MS, nextPollTick, type OrderPollStatus } from "./payment";

export interface UseOrderPolling {
  /** 累计轮询耗时（ms） */
  pollElapsed: number;
  /** 手动态：超 30s 窗派生。调用方渲染手动刷新入口，reset 恢复自动 */
  manual: boolean;
  /** 累计是否已超 30s 窗 */
  windowExpired: boolean;
  /** 重置累计并恢复自动轮询（换渠道后 / 手动刷新按钮调用） */
  reset: () => void;
}

export function useOrderPolling(opts: {
  enabled: boolean;
  status: OrderPollStatus;
  onTick: () => unknown;
}): UseOrderPolling {
  const { enabled, status, onTick } = opts;
  const [pollElapsed, setPollElapsed] = useState(0);
  const [manualMode, setManualMode] = useState(false);

  const windowExpired = pollElapsed >= POLL_TOTAL_MS;
  const manual = manualMode || windowExpired;

  useEffect(() => {
    if (!enabled || manualMode || windowExpired) return;
    const tick = nextPollTick(pollElapsed, status);
    if (!tick.continue) return;

    const timer = setTimeout(() => {
      void Promise.resolve(onTick()).finally(() => {
        setPollElapsed((e) => e + (tick.delayMs ?? 0));
      });
    }, tick.delayMs ?? 0);

    return () => clearTimeout(timer);
  }, [enabled, pollElapsed, status, onTick, manualMode, windowExpired]);

  const reset = useCallback(() => {
    setPollElapsed(0);
    setManualMode(false);
  }, []);

  return { pollElapsed, manual, windowExpired, reset };
}
