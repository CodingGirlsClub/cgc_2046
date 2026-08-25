/**
 * 订单状态轮询编排（R14 修订：2s×30s 快收敛 + 5s 降频续轮到终态）。
 *
 * 从 /orders/[id] 页抽取的共享编排：决策全走 lib/payment.nextPollTick 纯函数
 * （fake timers 测试面在纯函数层），本 hook 只做定时器与累计耗时 state。
 * 订单页与收银模态框（payment-checkout-dialog）共用，保证两处轮询口径一致。
 *
 * 无手动态：pending 永续轮（降频），终态即停；换渠道经 reset 归零重新快频。
 * onTick 需稳定引用（useCallback）——本 hook 的 effect 以 onTick 为依赖，
 * 内联箭头函数会每渲染重排定时器。
 */

import { useCallback, useEffect, useState } from "react";
import { nextPollTick, type OrderPollStatus } from "./payment";

export interface UseOrderPolling {
  /** 累计轮询耗时（ms） */
  pollElapsed: number;
  /** 换渠道后归零重新快频轮询 */
  reset: () => void;
}

export function useOrderPolling(opts: {
  enabled: boolean;
  status: OrderPollStatus;
  onTick: () => unknown;
}): UseOrderPolling {
  const { enabled, status, onTick } = opts;
  const [pollElapsed, setPollElapsed] = useState(0);

  useEffect(() => {
    if (!enabled) return;
    const tick = nextPollTick(pollElapsed, status);
    if (!tick.continue) return;

    const timer = setTimeout(() => {
      void Promise.resolve(onTick()).finally(() => {
        setPollElapsed((e) => e + (tick.delayMs ?? 0));
      });
    }, tick.delayMs ?? 0);

    return () => clearTimeout(timer);
  }, [enabled, pollElapsed, status, onTick]);

  const reset = useCallback(() => {
    setPollElapsed(0);
  }, []);

  return { pollElapsed, reset };
}
