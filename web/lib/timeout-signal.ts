/**
 * 请求超时 signal（15s）：超时后 abort，Apollo 报 AbortError → 调用方落错误态。
 *
 * #23 引入（工作流轮询），核销提交等现场交互复用：网络挂起时让按钮回到可重试，
 * 而不是永停「提交中」。
 */

const REQUEST_TIMEOUT_MS = 15_000;

export function timeoutSignal(): AbortSignal {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
	// 请求完成时清理定时器（signal 不保留引用，GC 回收时定时器随之清除）
	controller.signal.addEventListener(
		"abort",
		() => clearTimeout(timer),
		{ once: true },
	);
	return controller.signal;
}
