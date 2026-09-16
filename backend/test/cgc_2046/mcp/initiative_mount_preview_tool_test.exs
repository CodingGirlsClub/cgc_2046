defmodule Cgc2046.Mcp.InitiativeMountPreviewToolTest do
  @moduledoc """
  #596 `preview_initiative_mount`：Owner/Admin 可读四规则/锁态；普通成员与非成员
  forbidden（member-only 门 + 工具层 Owner/Admin 判定）；平台管理员非成员不在本面
  （治理读走 admin_get_initiative）。
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.Mcp.Tools.PreviewInitiativeMount
  alias Cgc2046.Mcp.Wrapper

  require Ash.Query

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp open_initiative(admin, slug) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "挂载预览 #{slug}",
        slug: slug,
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    for {key, value, locked} <- [
          {:deposit, %{enabled: true, amount_cents: 6900}, true},
          {:age_gate, %{min_age: 18}, true},
          {:min_participants, %{count: 8}, false},
          {:deadline_rule, %{hours_before_start: 72}, false}
        ] do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: locked
      })
      |> Ash.create!(actor: admin)
    end

    initiative |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)
  end

  test "Owner 读到四规则 map、缺失列表与 initiative 身份" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    admin = Fixtures.platform_admin("mcp-preview-admin")
    initiative = open_initiative(admin, "mcp-preview-open")

    assert {:reply, _, _} =
             reply =
             PreviewInitiativeMount.execute(
               %{"workspace_id" => workspace.id, "initiative_id" => initiative.id},
               frame_for(owner)
             )

    payload = decode(reply)

    assert payload["initiative"] == %{
             "id" => initiative.id,
             "name" => initiative.name,
             "slug" => "mcp-preview-open",
             "status" => "open"
           }

    assert payload["rules"] == %{
             "deposit" => %{
               "value" => %{"enabled" => true, "amount_cents" => 6900},
               "locked" => true
             },
             "age_gate" => %{"value" => %{"min_age" => 18}, "locked" => true},
             "min_participants" => %{"value" => %{"count" => 8}, "locked" => false},
             "deadline_rule" => %{"value" => %{"hours_before_start" => 72}, "locked" => false}
           }

    assert payload["missing_rules"] == []

    [log] =
      ToolCallLog
      |> Ash.Query.filter(user_id == ^owner.id and tool == "preview_initiative_mount")
      |> Ash.read!(authorize?: false)

    assert log.result_status == :ok
  end

  test "普通成员撞工具层判定；非成员撞 member 门" do
    %{workspace: workspace, member: member} = Fixtures.workspace_with_member()
    admin = Fixtures.platform_admin("mcp-preview-authz-admin")
    initiative = open_initiative(admin, "mcp-preview-authz")
    outsider = Fixtures.register_user("mcp-preview-outsider")

    params = %{"workspace_id" => workspace.id, "initiative_id" => initiative.id}

    assert {:error, %Anubis.MCP.Error{message: member_msg}, _} =
             PreviewInitiativeMount.execute(params, frame_for(member))

    assert member_msg =~ "forbidden"
    assert member_msg =~ "owner or admin required to preview initiative rules"

    assert {:error, %Anubis.MCP.Error{message: outsider_msg}, _} =
             PreviewInitiativeMount.execute(params, frame_for(outsider))

    assert outsider_msg =~ "forbidden"
    assert outsider_msg =~ "not a member"

    # 非成员平台管理员：本工具无 platform_admin 豁免，同样撞 member 门
    assert {:error, %Anubis.MCP.Error{message: admin_msg}, _} =
             PreviewInitiativeMount.execute(params, frame_for(admin))

    assert admin_msg =~ "forbidden"
    assert admin_msg =~ "not a member"
  end

  test "不存在的 initiative → not found（Owner 侧）" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()

    assert {:error, %Anubis.MCP.Error{message: message}, _} =
             PreviewInitiativeMount.execute(
               %{"workspace_id" => workspace.id, "initiative_id" => Ecto.UUID.generate()},
               frame_for(owner)
             )

    assert message =~ "initiative not found"
  end

  test "匿名（nil actor）撞 unauthenticated 门，不触达规则读" do
    %{workspace: workspace} = Fixtures.workspace_with_member()

    assert {:error, %Anubis.MCP.Error{message: message}, _} =
             PreviewInitiativeMount.execute(
               %{"workspace_id" => workspace.id, "initiative_id" => Ecto.UUID.generate()},
               Frame.new(current_user: nil)
             )

    assert message =~ "unauthenticated"
  end

  test "规则未配齐：missing_rules 经工具可见（挂载必失败的提前告知）" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    admin = Fixtures.platform_admin("mcp-preview-missing-admin")

    draft =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "未配齐规则",
        slug: "mcp-preview-missing",
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    for {key, value, locked} <- [
          {:deposit, %{enabled: false}, false},
          {:age_gate, %{min_age: 18}, true}
        ] do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: draft.id,
        key: key,
        value: value,
        locked: locked
      })
      |> Ash.create!(actor: admin)
    end

    assert {:reply, _, _} =
             reply =
             PreviewInitiativeMount.execute(
               %{"workspace_id" => workspace.id, "initiative_id" => draft.id},
               frame_for(owner)
             )

    payload = decode(reply)
    assert payload["initiative"]["status"] == "draft"
    assert payload["missing_rules"] == ["min_participants", "deadline_rule"]
    assert Map.keys(payload["rules"]) |> Enum.sort() == ["age_gate", "deposit"]
  end

  test "工具声明 member-only 门（无豁免 meta）" do
    assert Wrapper.gate_family("preview_initiative_mount") == :member_only
  end
end
