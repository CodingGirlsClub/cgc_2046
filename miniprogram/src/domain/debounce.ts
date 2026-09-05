/** 通用防抖：等待 wait ms 内无新调用才执行 fn；cancel 丢弃挂起调用。
 * 页面输入搜索用（#355 P2-10），不引第三方库。 */
export interface Debounced<A extends unknown[]> {
  (...args: A): void
  cancel(): void
}

// 模块内部句柄类型（不导出）：DOM 为 number、Node 为 NodeJS.Timeout，此处归一
type TimerHandle = ReturnType<typeof setTimeout>

export function debounce<A extends unknown[]>(fn: (...args: A) => void, wait: number): Debounced<A> {
  let timer: TimerHandle | undefined
  const debounced = (...args: A) => {
    clearTimeout(timer)
    timer = setTimeout(() => {
      timer = undefined
      fn(...args)
    }, wait)
  }
  debounced.cancel = () => {
    clearTimeout(timer)
    timer = undefined
  }
  return debounced
}
