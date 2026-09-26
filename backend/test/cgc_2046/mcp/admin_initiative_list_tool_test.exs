defmodule Cgc2046.Mcp.AdminInitiativeListToolTest do
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Initiatives.Initiative
  alias Cgc2046.Mcp.Tools.AdminListInitiatives

  defp decode({:reply, response, _frame}), do: Jason.decode!(hd(response.content)["text"])

  test "status 白名单过滤生效；未知值返回明确错误而不是抛异常" do
    admin = Fixtures.platform_admin("mcp-admin-init-list")
    frame = Frame.new(current_user: admin)

    Initiative
    |> Ash.Changeset.for_create(:create, %{
      name: "List draft",
      slug: "mcp-admin-init-list",
      created_by: admin.id
    })
    |> Ash.create!(actor: admin)

    assert {:reply, _, _} = reply = AdminListInitiatives.execute(%{"status" => "draft"}, frame)
    rows = decode(reply)["initiatives"]
    assert rows != []
    assert Enum.all?(rows, &(&1["status"] == "draft"))

    assert {:reply, _, _} = all = AdminListInitiatives.execute(%{}, frame)
    assert decode(all)["count"] >= length(rows)

    # 修复前：String.to_existing_atom("nope") 直接抛 ArgumentError 把调用打崩
    assert {:error, error, _frame} = AdminListInitiatives.execute(%{"status" => "nope"}, frame)
    assert error.message =~ "invalid status"
    assert error.message =~ "draft | open | closed | cancelled"
  end
end
