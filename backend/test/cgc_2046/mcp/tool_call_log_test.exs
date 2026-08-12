defmodule Cgc2046.Mcp.ToolCallLogTest do
  @moduledoc """
  工具调用审计（D9 / D-D8）资源行为测试。
  写入由 tool wrapper 以 authorize?: false 系统调用；默认不对 actor 开放读（切片 F 再开放）。
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.AccountsFixtures, as: Fixtures

  test "log 落库成功：字段完整" do
    user = Fixtures.register_user("log-1")

    assert {:ok, log} =
             ToolCallLog
             |> Ash.Changeset.for_create(
               :log,
               %{
                 user_id: user.id,
                 tool: "get_workspace_context",
                 params: %{"workspace_id" => "ws-1"},
                 result_status: :ok,
                 latency_ms: 12
               },
               authorize?: false
             )
             |> Ash.create()

    assert log.tool == "get_workspace_context"
    assert log.result_status == :ok
    assert log.params == %{"workspace_id" => "ws-1"}
    assert log.latency_ms == 12
    assert is_nil(log.pending_operation_id)
  end

  test "needs_confirmation 状态可挂 pending_operation_id" do
    user = Fixtures.register_user("log-2")
    pending_id = Ecto.UUID.generate()

    assert {:ok, log} =
             ToolCallLog
             |> Ash.Changeset.for_create(
               :log,
               %{
                 user_id: user.id,
                 tool: "create_invitation",
                 params: %{},
                 result_status: :needs_confirmation,
                 pending_operation_id: pending_id
               },
               authorize?: false
             )
             |> Ash.create()

    assert log.pending_operation_id == pending_id
  end

  test "error 状态可带错误摘要" do
    user = Fixtures.register_user("log-3")

    assert {:ok, log} =
             ToolCallLog
             |> Ash.Changeset.for_create(
               :log,
               %{
                 user_id: user.id,
                 tool: "save_step_output",
                 params: %{},
                 result_status: :forbidden,
                 error_message: "not a workspace member"
               },
               authorize?: false
             )
             |> Ash.create()

    assert log.error_message == "not a workspace member"
  end

  test "非法 result_status 被拒绝" do
    user = Fixtures.register_user("log-4")

    assert {:error, _} =
             ToolCallLog
             |> Ash.Changeset.for_create(
               :log,
               %{user_id: user.id, tool: "x", params: %{}, result_status: :bogus},
               authorize?: false
             )
             |> Ash.create()
  end

  test "默认 actor 不可读（切片 F 再开放）" do
    user = Fixtures.register_user("log-5")

    {:ok, _} =
      ToolCallLog
      |> Ash.Changeset.for_create(
        :log,
        %{user_id: user.id, tool: "x", params: %{}, result_status: :ok},
        authorize?: false
      )
      |> Ash.create()

    assert {:error, %Ash.Error.Forbidden{}} = ToolCallLog |> Ash.read(actor: user)
  end
end
