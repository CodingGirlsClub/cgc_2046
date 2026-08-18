import {
	render as rtlRender,
	renderHook as rtlRenderHook,
} from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import type { AbstractIntlMessages } from "next-intl";
import zhCN from "./messages/zh-CN.json";
import en from "./messages/en.json";
import ThemeProvider from "@/lib/theme-provider";

/**
 * 测试专用 render / renderHook：自动包裹 NextIntlClientProvider + ThemeProvider。
 *
 * - NextIntlClientProvider 默认注入 zh-CN messages（i18n Phase 2 起组件抽取 useTranslations，
 *   测试断言文案不变——zh-CN 为 source，渲染结果与硬编码原文一致）。
 * - locale="en" 或传入自定义 messages 可覆盖（语言切换器 / 设置页语言下拉等 en 场景测试）。
 * - ThemeProvider 保留（WorkspaceShell footer 的 ThemeToggle（U3）依赖 useTheme context）。
 * - 其余 RTL 工具（screen / fireEvent / waitFor 等）仍从 @testing-library/react 直接 import。
 */

export type RenderOptions = {
	/** 界面 locale；默认 "zh-CN"。en 场景显式传入 "en"。 */
	locale?: "zh-CN" | "en";
	/** 自定义 messages；缺省按 locale 取 messages/{locale}.json。 */
	messages?: AbstractIntlMessages;
};

const MESSAGES: Record<"zh-CN" | "en", AbstractIntlMessages> = { "zh-CN": zhCN, en };

/**
 * RTL wrapper（供 render 的 rerender 保留 provider 树）。
 */
function providersWrapper(options?: RenderOptions) {
	const locale: "zh-CN" | "en" = options?.locale ?? "zh-CN";
	const messages = options?.messages ?? MESSAGES[locale];
	return ({ children }: { children: React.ReactNode }) => (
		<NextIntlClientProvider locale={locale} messages={messages}>
			<ThemeProvider>{children}</ThemeProvider>
		</NextIntlClientProvider>
	);
}

export function render(ui: React.ReactElement, options?: RenderOptions) {
	return rtlRender(ui, { wrapper: providersWrapper(options) });
}

export function renderHook<Result, Props>(
	hook: (props: Props) => Result,
	options?: RenderOptions & {
		initialProps?: Props;
	},
) {
	const { initialProps, ...providerOptions } = options ?? {};
	return rtlRenderHook(hook, {
		initialProps,
		wrapper: providersWrapper(providerOptions),
	});
}
