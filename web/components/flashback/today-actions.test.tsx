import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import TodayActions from "./today-actions";
import {
	FLASHBACK_SUBMIT_TODAY,
	FLASHBACK_SEND_TO_WALL,
	FLASHBACK_ADJUST_TODAY_FOG,
	FLASHBACK_RETRACT,
	type FlashbackCapsuleMe,
} from "@/lib/graphql/flashback";

/**
 * 胶囊「我的卡」动作（G2 编辑今天的你 + G3 撤下）组件级测试。
 *
 * 钉住的行为契约：
 * - G2 编辑：预填 me.today 四字段；保存 = 覆盖式 submitToday；已寄出者紧接幂等
 *   sendToWall（墙卡即新内容），未寄出者只存草稿（不发 wall）；失败错误 + 可重试；
 *   成功后轻反馈（已保存）+ 关弹层回胶囊 + onChanged 触发数据刷新；
 * - G3 撤下：已寄出且 token 在场才渲染（登录态无 token 不渲染）；确认弹层取消
 *   零 mutation；确认 → flashbackRetract → 关弹层 + onChanged；失败错误 + 重试；
 * - 无障碍：弹层 dialog 语义 + 焦点（modal-a11y 先例）+ Esc 关闭。
 */

const mutateMock = vi.fn();

vi.mock("@/lib/apollo-client", () => ({
	client: { mutate: (opts: unknown) => mutateMock(opts) },
}));

const meSent: FlashbackCapsuleMe = {
	id: "me-1",
	fullName: "王晓雨",
	surname: "王",
	city: "上海",
	occupationThen: "校对",
	participation: "attended",
	appliedAt: "2012-02-20T11:03:00Z",
	today: {
		nowStatus: "还在写东西",
		want: "想学 AI",
		need: null,
		say: null,
		sentToWallAt: "2026-09-17T00:00:00Z",
	},
	quote: null,
	answers: [],
};

/** 已填草稿未寄出 */
const meDraft: FlashbackCapsuleMe = {
	...meSent,
	today: { nowStatus: "还在写东西", want: null, need: null, say: null, sentToWallAt: null },
};

/** 成功回复（按 doc 分派；失败用例 mockRejectedValueOnce 覆盖） */
function mockMutateOk() {
	mutateMock.mockImplementation(async (opts: { mutation: unknown }) => {
		if (opts.mutation === FLASHBACK_SUBMIT_TODAY) {
			return { data: { flashbackSubmitToday: { today: { sentToWallAt: null } } } };
		}
		if (opts.mutation === FLASHBACK_SEND_TO_WALL) {
			return { data: { flashbackSendToWall: { sentToWallAt: "2026-09-17T00:00:00Z" } } };
		}
		if (opts.mutation === FLASHBACK_RETRACT) {
			return { data: { flashbackRetract: { retracted: true } } };
		}
		if (opts.mutation === FLASHBACK_ADJUST_TODAY_FOG) {
			const variables = (opts as unknown as { variables: { field: string; spans: unknown[] } }).variables;
			return { data: { flashbackAdjustTodayFog: { field: variables.field, fogSpans: variables.spans } } };
		}
		return { data: {} };
	});
}

beforeEach(() => {
	mutateMock.mockReset();
	mockMutateOk();
});

afterEach(() => {
	cleanup();
});

describe("TodayActions · G2 编辑今天的你", () => {
	it("编辑弹层预填 me.today 四字段（空值回落空串）", async () => {
		render(<TodayActions me={meSent} token="tok-1" onChanged={vi.fn()} />);

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));

		expect(await screen.findByRole("dialog")).toBeInTheDocument();
		expect(screen.getByLabelText("现在的我，在做什么")).toHaveValue("还在写东西");
		expect(screen.getByLabelText("想做的事、想学的东西")).toHaveValue("想学 AI");
		expect(screen.getByLabelText(/需要什么帮助/)).toHaveValue("");
		expect(screen.getByLabelText(/想对 CGC \/ 文洋说点什么/)).toHaveValue("");
	});

	it("已寄出者保存序列：submitToday 带原文新值 → 紧接幂等 sendToWall；轻反馈后关弹层并刷新", async () => {
		const onChanged = vi.fn();
		render(<TodayActions me={meSent} token="tok-1" onChanged={onChanged} />);

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));
		fireEvent.change(await screen.findByLabelText("想做的事、想学的东西"), {
			target: { value: "想学 Rust" },
		});
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		// 顺序 + 参数钉死：覆盖式 submit（只带四字段）→ 已寄出再幂等 wall
		await waitFor(() => expect(mutateMock).toHaveBeenCalledTimes(2));
		const [submitCall, wallCall] = mutateMock.mock.calls.map(([opts]) => opts) as [
			{ mutation: unknown; variables: unknown },
			{ mutation: unknown; variables: unknown },
		];
		expect(submitCall.mutation).toBe(FLASHBACK_SUBMIT_TODAY);
		expect(submitCall.variables).toEqual({
			token: "tok-1",
			input: { nowStatus: "还在写东西", want: "想学 Rust", need: "", say: "" },
		});
		expect(wallCall.mutation).toBe(FLASHBACK_SEND_TO_WALL);
		expect(wallCall.variables).toEqual({ token: "tok-1" });

		// 轻反馈 + 回到胶囊视图（弹层关闭）+ 数据刷新
		expect(await screen.findByText("已保存 ✓")).toBeInTheDocument();
		await waitFor(() => expect(onChanged).toHaveBeenCalledTimes(1), { timeout: 2000 });
		expect(screen.queryByTestId("fb-edit-today-dialog")).not.toBeInTheDocument();
	});

	it("未寄出者只存草稿：submitToday 之后不发 sendToWall", async () => {
		const onChanged = vi.fn();
		render(<TodayActions me={meDraft} token="tok-1" onChanged={onChanged} />);

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));
		fireEvent.change(await screen.findByLabelText("现在的我，在做什么"), {
			target: { value: "开始学摄影" },
		});
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		await waitFor(() => expect(onChanged).toHaveBeenCalledTimes(1), { timeout: 2000 });
		expect(mutateMock).toHaveBeenCalledTimes(1);
		const [submitCall] = mutateMock.mock.calls.map(([opts]) => opts) as [
			{ mutation: unknown; variables: unknown },
		];
		expect(submitCall.mutation).toBe(FLASHBACK_SUBMIT_TODAY);
	});

	it("登录态无 token 也可编辑：token 以空值发出（submitToday 双入口走登录会话）", async () => {
		render(<TodayActions me={meSent} token={null} onChanged={vi.fn()} />);

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));
		fireEvent.click(await screen.findByRole("button", { name: "保存" }));

		await waitFor(() => expect(mutateMock).toHaveBeenCalled());
		const [submitCall] = mutateMock.mock.calls.map(([opts]) => opts) as [
			{ mutation: unknown; variables: { token: string | null } },
		];
		expect(submitCall.mutation).toBe(FLASHBACK_SUBMIT_TODAY);
		expect(submitCall.variables.token).toBeNull();
	});

	it("保存失败呈现错误 + 可重试：错误在场、弹层不关，再点保存走通", async () => {
		mutateMock.mockRejectedValueOnce(new Error("network"));
		const onChanged = vi.fn();
		render(<TodayActions me={meSent} token="tok-1" onChanged={onChanged} />);

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));
		fireEvent.click(await screen.findByRole("button", { name: "保存" }));

		expect(await screen.findByRole("alert")).toHaveTextContent(/保存没有成功/);
		expect(screen.getByTestId("fb-edit-today-dialog")).toBeInTheDocument();
		expect(onChanged).not.toHaveBeenCalled();

		// 重试（同一保存钮）
		fireEvent.click(screen.getByRole("button", { name: "保存" }));
		expect(await screen.findByText("已保存 ✓")).toBeInTheDocument();
		await waitFor(() => expect(onChanged).toHaveBeenCalledTimes(1), { timeout: 2000 });
	});

	it("「先不改」与 Esc 都关弹层，零 mutation", async () => {
		render(<TodayActions me={meSent} token="tok-1" onChanged={vi.fn()} />);

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));
		const dialog = await screen.findByTestId("fb-edit-today-dialog");
		expect(dialog).toHaveAttribute("role", "dialog");
		expect(dialog).toHaveAttribute("aria-modal", "true");

		fireEvent.keyDown(dialog.parentElement!, { key: "Escape" });
		expect(screen.queryByTestId("fb-edit-today-dialog")).not.toBeInTheDocument();
		expect(mutateMock).not.toHaveBeenCalled();

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));
		fireEvent.click(await screen.findByRole("button", { name: "先不改" }));
		expect(screen.queryByTestId("fb-edit-today-dialog")).not.toBeInTheDocument();
		expect(mutateMock).not.toHaveBeenCalled();
	});
});

describe("TodayActions · G3 撤下", () => {
	it("渲染门槛：已寄出 + token 在场才渲染撤下；登录态无 token / 未寄出都不渲染，编辑恒在", () => {
		const { unmount } = render(<TodayActions me={meSent} token="tok-1" onChanged={vi.fn()} />);
		expect(screen.getByRole("button", { name: "撤下" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "编辑今天的你" })).toBeInTheDocument();
		unmount();

		const second = render(<TodayActions me={meSent} token={null} onChanged={vi.fn()} />);
		expect(screen.queryByRole("button", { name: "撤下" })).not.toBeInTheDocument();
		expect(screen.getByRole("button", { name: "编辑今天的你" })).toBeInTheDocument();
		second.unmount();

		render(<TodayActions me={meDraft} token="tok-1" onChanged={vi.fn()} />);
		expect(screen.queryByRole("button", { name: "撤下" })).not.toBeInTheDocument();
		expect(screen.getByRole("button", { name: "编辑今天的你" })).toBeInTheDocument();
	});

	it("确认弹层讲清后果；「再想想」取消零 mutation", async () => {
		render(<TodayActions me={meSent} token="tok-1" onChanged={vi.fn()} />);

		fireEvent.click(screen.getByRole("button", { name: "撤下" }));

		expect(await screen.findByTestId("fb-retract-dialog")).toBeInTheDocument();
		expect(screen.getByText(/其他校友看不到了/)).toBeInTheDocument();
		expect(screen.getByText(/随时可重新寄出/)).toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "再想想" }));
		expect(screen.queryByTestId("fb-retract-dialog")).not.toBeInTheDocument();
		expect(mutateMock).not.toHaveBeenCalled();
	});

	it("确认撤下 → flashbackRetract 带 token → 关弹层并刷新（回未寄出态由刷新呈现）", async () => {
		const onChanged = vi.fn();
		render(<TodayActions me={meSent} token="tok-1" onChanged={onChanged} />);

		fireEvent.click(screen.getByRole("button", { name: "撤下" }));
		fireEvent.click(await screen.findByRole("button", { name: "确认撤下" }));

		await waitFor(() => expect(onChanged).toHaveBeenCalledTimes(1));
		expect(mutateMock).toHaveBeenCalledTimes(1);
		const [opts] = mutateMock.mock.calls.map(([call]) => call) as [
			{ mutation: unknown; variables: unknown },
		];
		expect(opts.mutation).toBe(FLASHBACK_RETRACT);
		expect(opts.variables).toEqual({ token: "tok-1" });
		expect(screen.queryByTestId("fb-retract-dialog")).not.toBeInTheDocument();
	});

	it("撤下失败呈现错误 + 重试走通", async () => {
		mutateMock.mockRejectedValueOnce(new Error("network"));
		const onChanged = vi.fn();
		render(<TodayActions me={meSent} token="tok-1" onChanged={onChanged} />);

		fireEvent.click(screen.getByRole("button", { name: "撤下" }));
		fireEvent.click(await screen.findByRole("button", { name: "确认撤下" }));

		expect(await screen.findByRole("alert")).toHaveTextContent(/撤下没有成功/);
		expect(screen.getByTestId("fb-retract-dialog")).toBeInTheDocument();
		expect(onChanged).not.toHaveBeenCalled();

		fireEvent.click(screen.getByRole("button", { name: "确认撤下" }));
		await waitFor(() => expect(onChanged).toHaveBeenCalledTimes(1));
		expect(screen.queryByTestId("fb-retract-dialog")).not.toBeInTheDocument();
	});
});

/** 服务端既有 today 雾版的 me（nowStatus 前 2 字）——盲初值闭环对照组 */
const meFog: FlashbackCapsuleMe = {
	...meSent,
	today: {
		...(meSent.today ?? {}),
		fogSpans: { now: [{ start: 0, len: 2 }] },
	},
};

describe("TodayActions · 编辑弹层的 today 雾编辑（本批闭环）", () => {
	it("服务端既有雾区间预填为雾态（命中句标 fb-review-sentence--fog）", async () => {
		render(<TodayActions me={meFog} token="tok-1" onChanged={vi.fn()} />);

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));
		expect(await screen.findByRole("dialog")).toBeInTheDocument();
		const fogged = [...document.querySelectorAll(".fb-review-sentence--fog")];
		expect(fogged.length).toBeGreaterThan(0);
		// nowStatus=「还在写东西」被 span 覆盖到 → 整句为雾态
		expect(
			fogged.some((b) => (b.textContent || "").includes("还在写东西")),
		).toBe(true);
	});

	it("保存顺序钉死：submitToday → adjustTodayFog(现在的新雾) → sendToWall（不发无序）", async () => {
		render(<TodayActions me={meFog} token="tok-1" onChanged={vi.fn()} />);

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));
		// 再在 want 句把它切成雾（服务端 want 原本无雾；定位只切雾句避开 textarea 同名）
		const wantZone = document.querySelector('[data-testid="fb-edit-fog-want"]') as HTMLElement;
		fireEvent.click(within(wantZone).getByText("想学 AI").closest("button")!);
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		await waitFor(() => expect(mutateMock).toHaveBeenCalledTimes(3));
		const calls = mutateMock.mock.calls.map(([opts]) => opts) as Array<{
			mutation: unknown;
			variables: { token?: string | null; field?: string; spans?: { start: number; len: number }[] };
		}>;
		expect(calls[0].mutation).toBe(FLASHBACK_SUBMIT_TODAY);
		expect(calls[1].mutation).toBe(FLASHBACK_ADJUST_TODAY_FOG);
		expect(calls[2].mutation).toBe(FLASHBACK_SEND_TO_WALL);
		// want 句被切成雾 → adjustTodayFog('want', [该句坐标])
		expect(calls[1].variables?.field).toBe("want");
		const spans = calls[1].variables?.spans ?? [];
		expect(spans).toHaveLength(1);
		expect("想学 AI".slice(spans[0].start, spans[0].start + spans[0].len)).toBe("想学 AI");
	});

	it("没碰雾：不发任何 adjustTodayFog（不打扰不产影变）", async () => {
		render(<TodayActions me={meFog} token="tok-1" onChanged={vi.fn()} />);

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		await waitFor(() => expect(mutateMock).toHaveBeenCalledTimes(2));
		const calls = mutateMock.mock.calls.map(([opts]) => opts) as Array<{ mutation: unknown }>;
		expect(calls.map((c) => c.mutation)).toEqual([
			FLASHBACK_SUBMIT_TODAY,
			FLASHBACK_SEND_TO_WALL,
		]);
	});

	it("adjustTodayFog 失败：不发 sendToWall（避免把用户要求遮蔽的字裸露给校友）+ 错误在场可重试", async () => {
		mutateMock.mockImplementation(async (opts: { mutation: unknown }) => {
			if (opts.mutation === FLASHBACK_SUBMIT_TODAY) {
				return { data: { flashbackSubmitToday: { today: {} } } };
			}
			if (opts.mutation === FLASHBACK_ADJUST_TODAY_FOG) {
				throw new Error("net fail");
			}
			return { data: {} };
		});
		render(<TodayActions me={meFog} token="tok-1" onChanged={vi.fn()} />);

		fireEvent.click(screen.getByRole("button", { name: "编辑今天的你" }));
		const failZone = document.querySelector('[data-testid="fb-edit-fog-want"]') as HTMLElement;
		fireEvent.click(within(failZone).getByText("想学 AI").closest("button")!);
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		const wallCall = mutateMock.mock.calls
			.map(([opts]) => opts)
			.find((opts) => opts.mutation === FLASHBACK_SEND_TO_WALL);
		await screen.findByRole("alert");
		expect(wallCall).toBeUndefined();
	});
});
