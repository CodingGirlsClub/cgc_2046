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
 it("not_found 的「去自助找回」带 #recover 锚点（L4）", () => {
  auth.mockReturnValue({ authed: false, confirmed: false });
  render(<InvalidToken reason="flashback_token_not_found" />);
  expect(screen.getByRole("link", { name: "自助找回我的档案" })).toHaveAttribute("href", "/flashback#recover");
 });
 it("已登录时正文不再提示请登录", () => {
  auth.mockReturnValue({ authed: true, confirmed: true });
  render(<InvalidToken reason="flashback_token_claimed" />);
  expect(screen.getByText(/链接已完成使命/).textContent).not.toContain("请登录");
 });
});
