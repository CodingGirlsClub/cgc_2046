import { describe, it, expect, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import Scatter from "./scatter";
import type { FlashbackScatterPhoto } from "@/lib/graphql/flashback";

/**
 * scatter 宝丽来「owner 标注」的姓氏口径（视觉审计 2026-09 D14）：
 *
 * payload 的 surname 字段就是姓本体（R12 隐名不隐姓：名字本就不下信道），
 * 复姓（欧阳/司马/上官）原实现在 scatter.tsx:67 把（photo.surname,
 * photo.surname）传给 surnameMasked——函数首分支（fullName.length >
 * surname.length）永远不成立，落入 chars[0]+★ 兜底，「欧阳」被渲染成「欧*」。
 * 正确形：直接渲染 surname 本身——单字姓无损（「李」）复姓完整（「欧阳」）。
 */

function photoOf(surname: string): FlashbackScatterPhoto[] {
	return [
		{
			photoKey: "p-mine",
			label: "2013 · 杭州",
			dateStamp: "2013 06 15",
			isMine: true,
			surname,
		},
		{
			photoKey: "p-other",
			label: "2015 · 上海",
			dateStamp: "2015 10 24",
			isMine: false,
			surname: "王",
		},
	];
}

afterEach(() => {
	cleanup();
});

describe("Scatter owner 标注的姓氏渲染（D14）", () => {
	// owner 标注只在 picked 照片后出现（picked 为受控 prop）
	it("复姓「欧阳」完整渲染为「欧阳 的照片」，不被折成「欧*」", () => {
		render(<Scatter photos={photoOf("欧阳")} picked={0} onPick={() => {}} />);
		expect(screen.getByText("欧阳 的照片")).toBeInTheDocument();
	});

	it("单字姓不变（「李 的照片」）", () => {
		render(<Scatter photos={photoOf("李")} picked={0} onPick={() => {}} />);
		expect(screen.getByText("李 的照片")).toBeInTheDocument();
	});
});
