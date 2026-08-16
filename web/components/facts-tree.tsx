"use client";

/**
 * facts 递归渲染（#40 通用兜底；plan 020 U4 起从 workflows 页抽出共享）：
 * map → 键值行（值嵌套则缩进子树）；list → 编号列表；scalar → 文本。
 * sub_workflow 嵌套 map 自然缩进。React 文本节点渲染，无 dangerouslySetInnerHTML。
 */

export default function FactsTree({ data }: { data: unknown }) {
	if (data === null || data === undefined) return null;

	if (Array.isArray(data)) {
		return (
			<ul className="workflows-facts-list">
				{data.map((item, index) => (
					<li key={index}>
						<span className="workflows-facts-index">{index + 1}.</span>
						<FactsTree data={item} />
					</li>
				))}
			</ul>
		);
	}

	if (typeof data === "object") {
		const entries = Object.entries(data as Record<string, unknown>);
		if (entries.length === 0) return <span className="workflows-facts-empty">—</span>;
		return (
			<ul className="workflows-facts-map">
				{entries.map(([key, value]) => (
					<li key={key} className="workflows-facts-row">
						<span className="workflows-facts-key">{key}</span>
						<span className="workflows-facts-value">
							<FactsTree data={value} />
						</span>
					</li>
				))}
			</ul>
		);
	}

	return <span>{String(data)}</span>;
}
