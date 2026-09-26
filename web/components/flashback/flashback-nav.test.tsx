import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import FlashbackNav from "./flashback-nav";
const { auth } = vi.hoisted(() => ({ auth: vi.fn() }));
vi.mock("@/lib/auth-provider", () => ({ useAuthed: auth }));
vi.mock("@/i18n/navigation", () => ({ usePathname: () => "/flashback", Link: ({ href, children, ...rest }: React.ComponentProps<"a">) => <a href={href} {...rest}>{children}</a> }));
afterEach(cleanup);
describe("闪念间公共导航", () => {
 it("访客能登录后回到时间长廊，切换金句墙和许愿树保留城市", () => {
  auth.mockReturnValue({ authed: false, confirmed: true });
  render(<FlashbackNav active="voices" city="上海"><button>Share</button></FlashbackNav>);
  expect(screen.getByRole("link", { name: "登录" })).toHaveAttribute("href", "/login?next=%2Fflashback%2Fcapsule");
  expect(screen.getByRole("link", { name: "金句墙" })).toHaveAttribute("aria-current", "page");
  expect(screen.getByRole("link", { name: "许愿树" })).toHaveAttribute("href", "/flashback/wishes?city=%E4%B8%8A%E6%B5%B7");
  expect(screen.getByRole("link", { name: "闪念间" })).toHaveAttribute("href", "/flashback");
  expect(screen.getByRole("button", { name: "Share" })).toBeInTheDocument();
 });
 it("所有已登录用户都有时间长廊入口，不查询是否绑定", () => {
  auth.mockReturnValue({ authed: true, confirmed: true });
  render(<FlashbackNav />);
  expect(screen.getByRole("link", { name: "我的时间长廊" })).toHaveAttribute("href", "/flashback/capsule");
  expect(screen.queryByRole("link", { name: "登录" })).not.toBeInTheDocument();
 });
 it("登录态尚未确认时不闪现登录入口", () => {
  auth.mockReturnValue({ authed: false, confirmed: false });
  render(<FlashbackNav />);
  expect(screen.queryByRole("link", { name: "登录" })).not.toBeInTheDocument();
 });
});
