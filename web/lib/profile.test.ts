import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  MOCK_CURRENT_PROFILE,
  fetchCurrentProfile,
  updateCurrentProfile,
  fetchProfileRoleSummary,
} from "./profile";
import { MOCK_WORKSPACES } from "./workspaces";

/**
 * 个人资料数据源测试（#69）。
 * USE_MOCK 模式下：fetchCurrentProfile 返回 mock、updateCurrentProfile 内存更新、
 * fetchProfileRoleSummary 复用 fetchMyWorkspaces（MOCK_WORKSPACES myRoleNames）。
 */

beforeEach(() => {
  // 重置 mock 内存（每次从原始值开始）
  MOCK_CURRENT_PROFILE.displayName = "小美";
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("lib/profile (#69)", () => {
  it("fetchCurrentProfile（mock）：返回当前用户资料", async () => {
    const p = await fetchCurrentProfile();
    expect(p.id).toBe("u_0202");
    expect(p.email).toBe("xiaomei@example.com");
    expect(p.displayName).toBe("小美");
    expect(p.isPlatformAdmin).toBe(false);
  });

  it("updateCurrentProfile（mock）：展示名保存后内存更新，重新 fetch 拿到新值", async () => {
    const updated = await updateCurrentProfile({ displayName: "小美酱" });
    expect(updated.displayName).toBe("小美酱");
    // 再次 fetch 应拿到更新后的值（内存 mock 已更新）
    const again = await fetchCurrentProfile();
    expect(again.displayName).toBe("小美酱");
  });

  it("updateCurrentProfile（mock）：空/undefined displayName 不覆盖现有展示名", async () => {
    await updateCurrentProfile({ displayName: "" });
    const p = await fetchCurrentProfile();
    expect(p.displayName).toBe("小美");
  });

  it("fetchProfileRoleSummary：返回各 Workspace 的角色并集（来自 myRoleNames）", async () => {
    const roles = await fetchProfileRoleSummary();
    expect(roles).toHaveLength(MOCK_WORKSPACES.length);
    const academy = roles.find((r) => r.workspaceSlug === "cgc-academy");
    expect(academy?.workspaceName).toBe("CGC 线上学院");
    expect(academy?.myRoleNames).toEqual(["admin"]);
    const sponsor = roles.find((r) => r.workspaceSlug === "cgc-sponsor-hub");
    expect(sponsor?.myRoleNames).toEqual([]);
  });
});
