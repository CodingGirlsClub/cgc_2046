"use client";

/**
 * plan 020 U4（#93）schema 驱动的步骤产物渲染。
 *
 * schema = output_schema（name/type/label/optional；宽松校验兼容旧数据）：
 * - 数组 → 字段列表（声明顺序即渲染顺序）；
 * - 单字段描述符（含 name 键的对象）→ 单字段列表；
 * - name → 描述符 映射 → 按对象键序渲染；
 * - 解析失败/空 → null（调用方回退 FactsTree）。
 *
 * 渲染：按声明顺序输出 label（缺省用 name）+ 值；optional 且值缺失
 * （undefined/null/空串）→ 隐藏该字段；未声明的多余键追加 FactsTree 兜底不丢数据。
 * React 文本节点渲染，无 dangerouslySetInnerHTML。
 */

import { useTranslations } from "next-intl";
import FactsTree from "@/components/facts-tree";

export interface OutputSchemaField {
	name: string;
	type?: string;
	label?: string;
	optional?: boolean;
}

function normalizeField(raw: unknown): OutputSchemaField | null {
	if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
	const obj = raw as Record<string, unknown>;
	if (typeof obj.name !== "string" || obj.name.length === 0) return null;
	return {
		name: obj.name,
		type: typeof obj.type === "string" ? obj.type : undefined,
		label: typeof obj.label === "string" ? obj.label : undefined,
		optional: typeof obj.optional === "boolean" ? obj.optional : undefined,
	};
}

/** output_schema → 有序字段列表；不可解析返回 null（回退 FactsTree）。 */
export function parseOutputSchema(schema: unknown): OutputSchemaField[] | null {
	if (Array.isArray(schema)) {
		const fields = schema.map(normalizeField).filter((f): f is OutputSchemaField => f !== null);
		return fields.length > 0 ? fields : null;
	}

	if (schema && typeof schema === "object") {
		const obj = schema as Record<string, unknown>;
		// 单字段描述符（含 name 键）
		if (typeof obj.name === "string") {
			return normalizeField(obj) ? [normalizeField(obj)!] : null;
		}
		// name → 描述符 映射（保留对象键序）
		const fields: OutputSchemaField[] = [];
		for (const [name, value] of Object.entries(obj)) {
			if (!value || typeof value !== "object") continue;
			const field = normalizeField({ name, ...(value as Record<string, unknown>) });
			if (field) fields.push(field);
		}
		return fields.length > 0 ? fields : null;
	}

	return null;
}

/** 值缺失判定（optional 隐藏用）：undefined / null / 空串 */
function isMissing(value: unknown): boolean {
	return value === undefined || value === null || value === "";
}

function renderValue(value: unknown) {
	if (isMissing(value)) return null;
	if (typeof value === "object") return <FactsTree data={value} />;
	return <span>{String(value)}</span>;
}

/**
 * schema 驱动产物列表；schema 缺失 → FactsTree 回退。
 * output 为单个值（非对象）且 schema 存在时按字段名无命中处理——回退兜底。
 */
export default function SchemaOutputList({
	output,
	schema,
}: {
	output: unknown;
	schema: unknown;
}) {
	const t = useTranslations("schemaOutput");
	const fields = parseOutputSchema(schema);

	// 回退：schema 缺失/不可解析 → 通用递归渲染（现状 FactsTree）
	if (!fields) {
		return <FactsTree data={output} />;
	}

	const outputMap =
		output && typeof output === "object" && !Array.isArray(output)
			? (output as Record<string, unknown>)
			: {};

	const declaredNames = new Set(fields.map((f) => f.name));
	const rendered = fields.filter((f) => !(f.optional && isMissing(outputMap[f.name])));

	if (rendered.length === 0) {
		// schema 存在但全部字段缺失 → 无产物占位
		return <span className="workflows-facts-empty">—</span>;
	}

	const extraEntries = Object.entries(outputMap).filter(([key]) => !declaredNames.has(key));

	return (
		<ul className="schema-output-list">
			{rendered.map((field) => (
				<li key={field.name} className="schema-output-row" data-testid="schema-output-field">
					<span className="schema-output-label">{field.label ?? field.name}</span>
					<span className="schema-output-value">{renderValue(outputMap[field.name])}</span>
				</li>
			))}
			{extraEntries.length > 0 && (
				<li className="schema-output-row schema-output-row--extra">
					<span className="schema-output-label">{t("otherLabel")}</span>
					<span className="schema-output-value">
						<FactsTree data={Object.fromEntries(extraEntries)} />
					</span>
				</li>
			)}
		</ul>
	);
}
