import { describe, it, expect, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminOpenClackyPage from "./page";

afterEach(cleanup);

describe("/admin/openclacky OpenClacky 入口", () => {
	it("显示描述文案与重定向链接", () => {
		render(<AdminOpenClackyPage />);

		expect(screen.getByRole("heading", { name: "OpenClacky" })).toBeInTheDocument();
		expect(screen.getByText(/独立服务器|独立认证/i)).toBeInTheDocument();
		expect(
			screen.getByRole("link", { name: /oc\.codingirlsclub\.com|前往 OpenClacky|打开 OpenClacky/i }),
		).toHaveAttribute("href", "https://oc.codingirlsclub.com");
	});
});
