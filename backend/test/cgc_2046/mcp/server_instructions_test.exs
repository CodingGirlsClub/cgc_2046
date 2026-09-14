defmodule Cgc2046.Mcp.ServerInstructionsTest do
  @moduledoc """
  MCP server instructions（U6/KTD4）：使用协议的**平台单源**。

  - 内容：非空，且逐条包含关键协议条目——先按名称选择工作台、playbook-first、
    确认纪律（two-tool 流程 + 「无人应答即取消」）、凭证纪律、401/429 不重试；
  - 生效：经受测 `/mcp` endpoint 的 initialize 真响应里可见（宿主据此把协议注入
    模型上下文，随平台更新即时生效）。

  单源的另一半——学习空间包内资产不含协议类条目——属 U7 的包校验断言，此处不做。
  """
  # async: false —— initialize 经真路由建 anubis 会话（任务进程需要 sandbox
  # shared 模式，与 mcp_readonly_tools_test 同口径）。
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.Server
  alias Cgc2046.Mcp.Token
  alias Cgc2046.OAuthFixtures

  test "instructions 非空且逐条包含关键协议条目" do
    instructions = Server.server_instructions()

    assert is_binary(instructions)
    assert String.trim(instructions) != ""

    # 一、先按名称选择工作台
    assert instructions =~ "先按名称"
    assert instructions =~ "list_my_workspaces"
    assert instructions =~ "get_workspace_context"

    # 二、playbook-first
    assert instructions =~ "get_role_playbook"

    # 三、确认纪律：two-tool 流程 + 无人应答即取消
    assert instructions =~ "needs_confirmation"
    assert instructions =~ "pending_id"
    assert instructions =~ "confirm_operation"
    assert instructions =~ "cancel_operation"
    assert instructions =~ "无人应答"
    assert instructions =~ "按取消处理"

    # 四、凭证纪律：不读宿主凭证存储、不回显凭证
    assert instructions =~ "不读取"
    assert instructions =~ "凭证"
    assert instructions =~ "不回显"

    # 五、401/429 不重试
    assert instructions =~ "401"
    assert instructions =~ "429"
    assert instructions =~ "不重试"
  end

  test "真 endpoint 的 initialize 响应可见同一份 instructions" do
    user = Fixtures.register_user("instructions-endpoint")

    conn = OAuthFixtures.post_mcp(issue_plain_token(user), OAuthFixtures.initialize_body())

    assert conn.status == 200

    assert %{"result" => result} = Jason.decode!(conn.resp_body)
    assert result["serverInfo"]["name"] == "cgc-2046"
    assert result["instructions"] == Server.server_instructions()
  end

  defp issue_plain_token(user) do
    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:issue, %{name: "server instructions test"}, actor: user)
      |> Ash.create()

    token.__metadata__[:plain_token]
  end
end
