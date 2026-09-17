"use client";

import { useCallback, useEffect, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { formatDeadline } from "@/lib/events";
import {
	fetchPublicInitiatives,
	type PublicInitiativeCard,
} from "@/lib/graphql/initiatives";
import PublicCatalogShell from "@/components/public-catalog-shell";

/** /initiatives 公开列表页（R5）：open 与 closed 全量列出（后端已按 open 在前排序）。 */
export default function InitiativeIndex() {
	const t = useTranslations("initiatives");
	const tCommon = useTranslations("common");
	const locale = useLocale();
	const [rows, setRows] = useState<PublicInitiativeCard[] | null>(null);
	const [error, setError] = useState<string | null>(null);
	const [nonce, setNonce] = useState(0);

	const retry = useCallback(() => {
		setRows(null);
		setError(null);
		setNonce((n) => n + 1);
	}, []);

	useEffect(() => {
		let cancelled = false;
		void fetchPublicInitiatives()
			.then((value) => {
				if (!cancelled) setRows(value);
			})
			.catch((reason: unknown) => {
				if (!cancelled)
					setError(reason instanceof Error ? reason.message : String(reason));
			});
		return () => {
			cancelled = true;
		};
	}, [nonce]);

	// #628：cancelled（中止）与 closed（收尾）文案分叉——两者都是留档，但语义不同
	const statusText = (status: string) => {
		switch (status) {
			case "closed": return t("closed");
			case "cancelled": return t("cancelled");
			default: return t("open");
		}
	};

	return (
		<PublicCatalogShell activeKind="initiative">
			<div className="public-catalog-container">
				<header className="public-catalog-heading">
					<div>
						<h1>{t("indexTitle")}</h1>
						<p>{t("indexDesc")}</p>
					</div>
				</header>

				{error ? (
					<div className="public-catalog-state" role="alert">
						<p>
							{t("loadFailed")}：{error}
						</p>
						<button type="button" onClick={retry} className="public-catalog-retry">
							{tCommon("retry")}
						</button>
					</div>
				) : rows === null ? (
					<ul className="public-catalog-grid" aria-hidden="true">
						<li className="public-catalog-skeleton" />
						<li className="public-catalog-skeleton" />
						<li className="public-catalog-skeleton" />
					</ul>
				) : rows.length === 0 ? (
					<p className="public-catalog-state">{t("indexEmpty")}</p>
				) : (
					<ul className="public-catalog-grid">
						{rows.map((initiative) => (
							<li key={initiative.id}>
								<Link
									href={`/initiatives/${initiative.slug}`}
									className="public-catalog-card"
								>
									<span className="public-catalog-card__head">
										<span className="public-catalog-card__title">
											{initiative.name}
										</span>
										<strong>{statusText(initiative.status)}</strong>
									</span>
									{initiative.hashtag ? <span>{initiative.hashtag}</span> : null}
									{initiative.description ? <span>{initiative.description}</span> : null}
									<span>
										{initiative.windowStartsAt
											? `${formatDeadline(initiative.windowStartsAt, tCommon("timeTbd"), locale)} – ${formatDeadline(initiative.windowEndsAt, tCommon("timeTbd"), locale)}`
											: tCommon("timeTbd")}
									</span>
								</Link>
							</li>
						))}
					</ul>
				)}
			</div>
		</PublicCatalogShell>
	);
}
