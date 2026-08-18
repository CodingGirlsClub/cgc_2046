import { describe, it, expect } from "vitest";
import { screen } from "@testing-library/react";
import { render } from "@/test-utils";
import SchemaOutputList, {
	parseOutputSchema,
	type OutputSchemaField,
} from "./schema-output-list";

describe("parseOutputSchema（plan 020 U4：宽松校验兼容旧数据）", () => {
	it("数组 → 有序字段列表", () => {
		const fields = parseOutputSchema([
			{ name: "text", type: "string", label: "笔记", optional: false },
			{ name: "extra", label: "补充", optional: true },
		]);
		expect(fields).toEqual([
			{ name: "text", type: "string", label: "笔记", optional: false },
			{ name: "extra", label: "补充", optional: true },
		]);
	});

	it("单字段描述符（含 name 键的对象）→ 单字段列表", () => {
		const fields = parseOutputSchema({
			name: "reading",
			type: "string",
			label: "阅读产出",
			optional: false,
		});
		expect(fields).toEqual([
			{ name: "reading", type: "string", label: "阅读产出", optional: false },
		]);
	});

	it("name → 描述符 映射 → 按对象键序渲染", () => {
		const fields = parseOutputSchema({
			text: { type: "string", label: "正文" },
			reflection: { type: "string", label: "心得", optional: true },
		});
		expect(fields).toEqual([
			{ name: "text", type: "string", label: "正文" },
			{ name: "reflection", type: "string", label: "心得", optional: true },
		]);
	});

	it("缺失/非法/空 → null（调用方回退 FactsTree）", () => {
		expect(parseOutputSchema(null)).toBeNull();
		expect(parseOutputSchema(undefined)).toBeNull();
		expect(parseOutputSchema("x")).toBeNull();
		expect(parseOutputSchema([])).toBeNull();
		expect(parseOutputSchema([{ no_name: 1 }])).toBeNull();
	});
});

describe("SchemaOutputList 渲染矩阵（#93）", () => {
	it("schema 缺失 → 回退 FactsTree（map 键值 + 嵌套）", () => {
		render(<SchemaOutputList output={{ text: "HI", nested: { a: 1 } }} schema={null} />);
		expect(screen.getByText("text")).toBeInTheDocument();
		expect(screen.getByText("HI")).toBeInTheDocument();
		expect(screen.getByText("nested")).toBeInTheDocument();
		expect(screen.getByText("a")).toBeInTheDocument();
		expect(screen.queryByTestId("schema-output-field")).not.toBeInTheDocument();
	});

	it("schema 存在：顺序 + 中文标签 + 值渲染（React 文本节点）", () => {
		const schema: OutputSchemaField[] = [
			{ name: "text", type: "string", label: "笔记内容", optional: false },
			{ name: "reflection", type: "string", label: "心得体会", optional: false },
		];
		render(<SchemaOutputList output={{ text: "读书笔记", reflection: "心得" }} schema={schema} />);

		const fields = screen.getAllByTestId("schema-output-field");
		expect(fields).toHaveLength(2);
		expect(fields[0]).toHaveTextContent("笔记内容");
		expect(fields[0]).toHaveTextContent("读书笔记");
		expect(fields[1]).toHaveTextContent("心得体会");
		expect(fields[1]).toHaveTextContent("心得");
	});

	it("optional 缺失 → 隐藏；optional 有值 → 渲染", () => {
		const schema: OutputSchemaField[] = [
			{ name: "required_field", label: "必填", optional: false },
			{ name: "optional_empty", label: "可选空", optional: true },
			{ name: "optional_filled", label: "可选有值", optional: true },
		];
		render(
			<SchemaOutputList
				output={{ required_field: "x", optional_filled: "y", optional_empty: "" }}
				schema={schema}
			/>
		);

		expect(screen.getByText("必填")).toBeInTheDocument();
		expect(screen.getByText("可选有值")).toBeInTheDocument();
		expect(screen.queryByText("可选空")).not.toBeInTheDocument();
	});

	it("schema 存在但全部字段缺失 → 「—」占位", () => {
		render(
			<SchemaOutputList
				output={{ other: 1 }}
				schema={[{ name: "text", label: "正文", optional: true }]}
			/>
	);
		expect(screen.getByText("—")).toBeInTheDocument();
	});

	it("未声明键 → 「其他」FactsTree 兜底（不丢数据）", () => {
		render(
			<SchemaOutputList
				output={{ text: "hi", extra_key: "保留" }}
				schema={[{ name: "text", label: "正文", optional: false }]}
			/>
	);
		expect(screen.getByText("正文")).toBeInTheDocument();
		expect(screen.getByText("其他")).toBeInTheDocument();
		expect(screen.getByText("extra_key")).toBeInTheDocument();
	});
});
