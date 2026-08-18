import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { fireEvent, cleanup } from "@testing-library/react";
import { render } from "@/test-utils";
import { Avatar } from "./profile-avatar";

/**
 * 头像上传校验单测（#018）。
 * jsdom 的 FileReader 不可靠，用可编程 mock 驱动 onload/onerror；
 * 校验分支（MIME / size）在创建 FileReader 之前就短路，直接断言 onError。
 */

interface MockFileReader {
	onload: (() => void) | null;
	onerror: (() => void) | null;
	result: string | ArrayBuffer | null;
	readAsDataURL(): void;
}

let lastReader: MockFileReader | null = null;

/** 可编程 FileReader mock（jsdom 的 FileReader 不可靠）。构造函数显式返回对象，避免 this 别名。 */
function MockFileReader(): MockFileReader {
	const reader: MockFileReader = {
		onload: null,
		onerror: null,
		result: null,
		readAsDataURL() {
			lastReader = reader;
		},
	};
	return reader;
}

function fileOf(type: string, bytes: number, name = "avatar") {
	const ext = type.split("/")[1] ?? "bin";
	return new File([new Uint8Array(bytes)], `${name}.${ext}`, { type });
}

function renderAvatar() {
	const onFile = vi.fn();
	const onError = vi.fn();
	const utils = render(
		<Avatar
			content={{ name: "测试", avatarUrl: null }}
			editable
			onFile={onFile}
			onError={onError}
		/>,
	);
	const input = utils.container.querySelector(
		'input[type="file"]',
	) as HTMLInputElement;
	return { onFile, onError, input };
}

beforeEach(() => {
	lastReader = null;
	vi.stubGlobal("FileReader", MockFileReader);
});

afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

describe("Avatar 头像上传校验 (#018)", () => {
	it("合法 PNG（<2.2MB）：FileReader 读取后 onFile 被调，onError 未调", () => {
		const { onFile, onError, input } = renderAvatar();

		fireEvent.change(input, {
			target: { files: [fileOf("image/png", 1024)] },
		});

		expect(onError).not.toHaveBeenCalled();
		expect(lastReader).not.toBeNull();
		lastReader!.result = "data:image/png;base64,AAAA";
		lastReader!.onload!();
		expect(onFile).toHaveBeenCalledWith("data:image/png;base64,AAAA");
	});

	it("MIME 白名单外（image/bmp）：onError 报格式，onFile 未调，FileReader 未创建", () => {
		const { onFile, onError, input } = renderAvatar();

		fireEvent.change(input, {
			target: { files: [fileOf("image/bmp", 1024)] },
		});

		expect(onError).toHaveBeenCalledWith("仅支持 PNG、JPG、WebP、GIF 格式");
		expect(onFile).not.toHaveBeenCalled();
		expect(lastReader).toBeNull();
	});

	it("超过 2.2MB（3MB PNG）：onError 报大小，onFile 未调", () => {
		const { onFile, onError, input } = renderAvatar();

		fireEvent.change(input, {
			target: { files: [fileOf("image/png", 3 * 1024 * 1024)] },
		});

		expect(onError).toHaveBeenCalledWith("文件大小不能超过 2.2MB");
		expect(onFile).not.toHaveBeenCalled();
	});

	it("FileReader onerror：onError 报读取失败，onFile 未调", () => {
		const { onFile, onError, input } = renderAvatar();

		fireEvent.change(input, {
			target: { files: [fileOf("image/png", 1024)] },
		});

		expect(lastReader).not.toBeNull();
		lastReader!.onerror!();
		expect(onError).toHaveBeenCalledWith("文件读取失败，请重试");
		expect(onFile).not.toHaveBeenCalled();
	});
});
