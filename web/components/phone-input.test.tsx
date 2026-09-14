import { describe, it, expect } from "vitest";
import { fireEvent, screen } from "@testing-library/react";
import { useState } from "react";
import { render } from "@/test-utils";
import PhoneInput, { composeE164, isValidPhone } from "./phone-input";

describe("composeE164 / isValidPhone（E.164 产出与校验）", () => {
	it("国家区号 + 本机号 → E.164 规范形；剥非数字与长途前缀 0", () => {
		expect(composeE164("CN", "138 0013-8000")).toBe("+8613800138000");
		expect(composeE164("US", "415-555-2671")).toBe("+14155552671");
		expect(composeE164("GB", "07911 123456")).toBe("+447911123456");
		expect(composeE164("CN", "")).toBe("");
	});

	it("isValidPhone：规范形可验，垃圾输入与空串拒绝", () => {
		expect(isValidPhone("+8613800138000")).toBe(true);
		expect(isValidPhone("+14155552671")).toBe(true);
		expect(isValidPhone("+86123")).toBe(false);
		expect(isValidPhone("")).toBe(false);
	});
});

/** 受控挂载：PhoneInput 产出经父组件 state 回流，output 展示最终 E.164。 */
function Harness() {
	const [value, setValue] = useState("");
	return (
		<>
			<PhoneInput id="p" value={value} onChange={setValue} />
			<output data-testid="e164">{value}</output>
		</>
	);
}

describe("PhoneInput（国家/地区选择 + 本机号输入）", () => {
	it("输入实时产出 +86 规范形（zh 默认 CN），selector 有无障碍标签", () => {
		render(<Harness />);

		expect(screen.getByLabelText("国家/地区")).toBeInTheDocument();
		fireEvent.change(screen.getByRole("textbox"), {
			target: { value: "13800138000" },
		});
		expect(screen.getByTestId("e164")).toHaveTextContent("+8613800138000");
	});

	it("切换国家/地区：既有数字重组为新区号 E.164，输入框回显不变", () => {
		render(<Harness />);

		fireEvent.change(screen.getByRole("textbox"), {
			target: { value: "13800138000" },
		});
		fireEvent.change(screen.getByLabelText("国家/地区"), {
			target: { value: "US" },
		});

		expect(screen.getByTestId("e164")).toHaveTextContent("+113800138000");
		expect(screen.getByRole("textbox")).toHaveValue("13800138000");
	});
});
