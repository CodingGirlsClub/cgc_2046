import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { gql } from "@apollo/client";
import { MockedProvider } from "@apollo/client/testing/react";
import Home from "@/app/page";

const PING = gql`
  query Ping {
    ping
  }
`;

// 接缝 2:Apollo mock 组件测试 —— Next.js 独立运行时,不与后端联调。
// MockedProvider 拦截 PING 查询并返回确定数据,验证组件外部行为
// (标题/探针文案/连通成功态)。
function renderHome() {
  return render(
    <MockedProvider
      mocks={[{ request: { query: PING }, result: { data: { ping: "pong" } } }]}
    >
      <Home />
    </MockedProvider>,
  );
}

describe("T01 前端测试基建 smoke", () => {
  it("渲染首页标题", () => {
    renderHome();
    expect(
      screen.getByRole("heading", { name: "CGC 2046" }),
    ).toBeInTheDocument();
  });

  it("展示后端连通性探针文案与连通成功态", async () => {
    renderHome();
    expect(screen.getByText("Backend GraphQL connectivity")).toBeInTheDocument();
    expect(await screen.findByText("Connected — ping: pong")).toBeInTheDocument();
  });
});
