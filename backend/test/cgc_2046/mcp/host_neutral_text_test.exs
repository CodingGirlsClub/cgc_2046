defmodule Cgc2046.Mcp.HostNeutralTextTest do
  @moduledoc """
  宿主中立不变量（U6/KTD4）：平台对 agent 的文本不得点名任何宿主的工具原语。

  denylist 双向覆盖已接入的两个宿主：

  - OpenClacky：`ask_user`（提问/确认原语）与 `auto_reply`（其无人应答标记）；
  - opencode 1.18.30：`question`（内置工具注册名，tool layer `tool/question`）。

  被检文本一律取自**运行时接口**——`Playbooks.fetch/1` 的返回、确认提示构造函数
  `Response.to_response/2` 的输出、`Server.server_instructions/0`、服务器实际注册的
  工具名与描述——而不是源码文件字符串扫描：源码注释与实现细节不属「平台对 agent
  的文本」，不该被误伤。

  反面同样钉住：宿主本地资产（openclacky-ext 的 agent prompt）仍具名其原语——
  平台中立 ≠ 宿主资产中立，具名归宿主。
  """
  use ExUnit.Case, async: true

  alias Cgc2046.Mcp.Playbooks
  alias Cgc2046.Mcp.Server
  alias Cgc2046.Mcp.Tools.Response

  # {用途, 模式, 样本}——样本为中立化前的平台原文（含各宿主原语），用于防空转：
  # 模式若不匹配任何真实宿主原语，下面的不变量断言会退化为恒真，这里先自证模式有效。
  @host_primitives [
    {"OpenClacky 提问/确认原语", ~r/\bask_user\b/, "再用宿主内置 ask_user 弹可点击卡片"},
    {"OpenClacky 无人应答标记", ~r/\bauto_reply\b/,
     "ask_user 结果出现 auto_reply（无人在场）一律 cancel_operation"},
    {"opencode 提问/确认原语", ~r/\bquestion\b/i, "多个 pending 则每个 pending 一个 question"}
  ]

  @openclacky_agent_prompts ~w(cgc-assistant cgc-tutor cgc-admin)

  test "denylist 模式各自命中其宿主原语样本（防空转）" do
    for {label, pattern, sample} <- @host_primitives do
      assert Regex.match?(pattern, sample), "denylist 模式对 #{label} 失配：#{inspect(pattern)}"
    end
  end

  test "四角色 playbook 运行文本不含任何宿主原语名" do
    for role <- Playbooks.roles() do
      assert {:ok, playbook} = Playbooks.fetch(role)
      assert_host_neutral(playbook.content, "playbook #{role}")
    end
  end

  test "确认提示运行文本不含任何宿主原语名，且确认流语义不变" do
    hint = confirmation_hint()

    assert_host_neutral(hint, "确认提示 hint")
    assert hint =~ "confirm_operation"
    assert hint =~ "cancel_operation"
    # 无人应答即取消（KTD4 明确保留的语义）
    assert hint =~ "按取消处理"
  end

  test "管理侧 playbook 的确认流语义未随中立化丢失" do
    for role <- [:workspace_admin, :platform_admin] do
      assert {:ok, playbook} = Playbooks.fetch(role)

      assert playbook.content =~ "confirm_operation",
             "#{role} playbook 丢失 confirm_operation 指示"

      assert playbook.content =~ "cancel_operation",
             "#{role} playbook 丢失 cancel_operation 指示"

      assert playbook.content =~ "无人应答", "#{role} playbook 丢失「无人应答即取消」纪律"
    end
  end

  test "server instructions 不含任何宿主原语名" do
    assert_host_neutral(Server.server_instructions(), "server instructions")
  end

  test "服务器注册的工具名与描述不含任何宿主原语名" do
    tools = Server.__components__(:tool)

    assert tools != [], "工具注册表为空，扫描失效"

    for tool <- tools do
      assert_host_neutral(tool.name, "工具名 #{tool.name}")
      assert_host_neutral(tool.description || "", "工具描述 #{tool.name}")
    end
  end

  test "OpenClacky 宿主资产仍具名其提问原语（平台中立不动宿主资产）" do
    for agent <- @openclacky_agent_prompts do
      path =
        Path.expand(
          "../../../../openclacky-ext/cgc-2046/agents/#{agent}/system_prompt.md",
          __DIR__
        )

      assert File.exists?(path), "宿主 asset 缺失：#{path}"
      assert File.read!(path) =~ "ask_user", "#{agent} 宿主 prompt 不再具名 ask_user"
    end
  end

  defp confirmation_hint do
    {:reply, response, _frame} =
      Response.to_response(
        {:needs_confirmation, %{pending_id: "pending-1", summary: "将创建工作台"}},
        Anubis.Server.Frame.new()
      )

    [%{"text" => text}] = response.content
    Jason.decode!(text)["hint"]
  end

  defp assert_host_neutral(text, context) do
    for {label, pattern, _sample} <- @host_primitives do
      refute Regex.match?(pattern, text),
             "#{context} 点名了宿主原语（#{label}，模式 #{inspect(pattern)}）：\n#{text}"
    end
  end
end
