"use client";

/**
 * #836 回响卡（公开树 + 成员面长廊共用）。
 *
 * - 署名固定为「主办方」(i18n),显示首次发布时间
 * - 被更正过(status=corrected)显示「已更正」标记
 * - 正文纯文本,保留换行;不解析 HTML 或链接
 * - 默认展示最新一条;多条时提供「全部 N 条回响」展开,按时间正序
 * - 无回响时父组件不渲染本卡(本组件假定有 latestEcho/echoCount>0)
 * - 文案不暗示「愿望已实现」(R20)
 */
import { useTranslations } from "next-intl";
import { formatDateTime } from "@/lib/format";
import type { FlashbackPublicWishEcho } from "@/lib/graphql/flashback";
import styles from "./wish-echo-card.module.css";

interface WishEchoCardProps {
	/** 最新一条可见回响(#834 latestEcho)。非空才有意义。 */
	latest: FlashbackPublicWishEcho;
	/** 全部可见回响,按首次发布时间正序(#834 echoes)。 */
	echoes: FlashbackPublicWishEcho[];
	/** 展开状态由父组件控制(读会话内存即可,后端不持久) */
	expanded: boolean;
	onToggleExpanded: () => void;
}

export function WishEchoCard({
	latest,
	echoes,
	expanded,
	onToggleExpanded,
}: WishEchoCardProps) {
	const t = useTranslations("flashback.echoCard");
	const total = echoes.length;

	return (
		<section
			className={styles.card}
			data-testid="fb-wish-echo-card"
			aria-label={t("regionLabel")}
		>
			{!expanded && <EchoRow echo={latest} t={t} />}
			{total > 1 && (
				<button
					type="button"
					className={styles.toggle}
					aria-expanded={expanded}
					aria-label={expanded ? t("collapse") : t("expandLabel", { count: total })}
					onClick={onToggleExpanded}
					data-testid="fb-wish-echo-toggle"
				>
					{expanded ? t("collapse") : t("expandLabel", { count: total })}
				</button>
			)}
			{expanded && (
				<ol className={styles.list} data-testid="fb-wish-echo-list">
					{echoes.map((echo) => (
						<li key={echo.id}>
							<EchoRow echo={echo} t={t} />
						</li>
					))}
				</ol>
			)}
		</section>
	);
}

interface EchoRowProps {
	echo: FlashbackPublicWishEcho;
	t: ReturnType<typeof useTranslations>;
}

function EchoRow({ echo, t }: EchoRowProps) {
	const corrected = echo.status === "corrected";
	return (
		<article className={styles.echo} data-testid="fb-wish-echo" data-status={echo.status}>
			<header className={styles.header}>
				<span className={styles.byline}>{t("byline")}</span>
				<time className={styles.time} dateTime={echo.publishedAt}>
					{formatDateTime(echo.publishedAt)}
				</time>
				{corrected && (
					<span className={styles.corrected} data-testid="fb-wish-echo-corrected">
						{t("correctedBadge")}
					</span>
				)}
			</header>
			<p className={styles.body} data-testid="fb-wish-echo-body">
				{echo.content}
			</p>
		</article>
	);
}
