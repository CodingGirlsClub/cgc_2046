defmodule Cgc2046.Mcp.PublicInitiativeToolsTest do
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Mcp.Tools.{GetPublicInitiative, ListPublicInitiatives}

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp open_initiative(admin, slug) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{name: "MCP public", slug: slug, created_by: admin.id})
      |> Ash.create!(actor: admin)

    for {key, value} <- [
          {:deposit, %{enabled: false}},
          {:age_gate, %{min_age: 18}},
          {:min_participants, %{count: 8}},
          {:deadline_rule, %{hours_before_start: 72}}
        ] do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: false
      })
      |> Ash.create!(actor: admin)
    end

    initiative |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)
  end

  test "public initiative MCP tools expose public projection and reject draft" do
    admin = Fixtures.platform_admin("mcp-public-initiative")
    initiative = open_initiative(admin, "mcp-public-initiative")
    outsider = Fixtures.register_user("mcp-public-outsider")
    frame = Frame.new(current_user: outsider)

    assert {:reply, _, _} = reply = ListPublicInitiatives.execute(%{}, frame)
    assert Enum.any?(decode(reply)["initiatives"], &(&1["slug"] == initiative.slug))

    assert {:reply, _, _} =
             detail = GetPublicInitiative.execute(%{"slug" => initiative.slug}, frame)

    detail_row = decode(detail)
    assert detail_row["slug"] == initiative.slug

    # 运营取投放链接的出口（Patch 3）：公开页绝对链接随工具结果返回，与
    # public_url/1 同值（相对路径 / 别的 base 都算不合格）
    assert detail_row["url"] == Cgc2046.Initiatives.Public.public_url(initiative.slug)
  end

  test "公开工具不泄露规则值/锁态（#596 权限不扩大：预览读面只有 Owner/Admin 面）" do
    admin = Fixtures.platform_admin("mcp-public-privacy-admin")
    initiative = open_initiative(admin, "mcp-public-privacy")
    frame = Frame.new(current_user: Fixtures.register_user("mcp-public-privacy-outsider"))

    assert {:reply, _, _} = list_reply = ListPublicInitiatives.execute(%{}, frame)

    row =
      Enum.find(decode(list_reply)["initiatives"], &(&1["slug"] == initiative.slug))

    refute Map.has_key?(row, "rules")
    refute Map.has_key?(row, "locked")
    refute Map.has_key?(row, "missing_rules")

    assert {:reply, %{content: [content]}, _} =
             GetPublicInitiative.execute(%{"slug" => initiative.slug}, frame)

    for leak <- ["rules", "locked", "amount_cents", "min_age", "hours_before_start"] do
      refute content["text"] =~ leak, "公开读面泄露了规则信息：#{leak}"
    end
  end
end
