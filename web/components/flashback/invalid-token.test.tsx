import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import InvalidToken from "./invalid-token";
const { auth } = vi.hoisted(() => ({ auth: vi.fn() }));
vi.mock("@/lib/auth-provider", () => ({ useAuthed: auth }));
vi.mock("@/i18n/navigation", () => ({ usePathname: () => "/flashback/enter", Link: ({ href, children, ...rest }: React.ComponentProps<"a">) => <a href={href} {...rest}>{children}</a> }));
afterEach(cleanup);
describe("已收好链接的下一步", () => {
 it("未登录时登录链接回跳长廊", () => {
  auth.mockReturnValue({ authed: false, confirmed: true });
  render(<InvalidToken reason="flashback_token_claimed" />);
  expect(screen.getByRole("link", { name: "去登录" })).toHaveAttribute("href", "/login?next=%2Fflashback%2Fcapsule");
 });
 it("已登录时直接进入自己的长廊", () => {
  auth.mockReturnValue({ authed: true, confirmed: true });
  render(<InvalidToken reason="flashback_token_claimed" />);
  expect(screen.getByRole("link", { name: "进入我的时间长廊" })).toHaveAttribute("href", "/flashback/capsule");
  expect(screen.queryByRole("link", { name: "去登录" })).not.toBeInTheDocument();
 });
});
