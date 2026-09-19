defmodule Cgc2046.Mcp.AdminWishToolsTest do
  @moduledoc """
  许愿治理四工具（U9/KTD5）：门控 fail-closed、私有可见、列表无联系方式/
  详情带、两段式删除（reason 校验/幂等/摘要回显）、软删单源（KTD4）。
  """

  use Cgc2046.DataCase, async: false

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Flashback.{Wishes}

  alias Cgc2046.Mcp.Tools.{
    AdminGetWish,
    AdminListWishes,
    AdminSoftDeleteWish,
    AdminSoftDeleteWishComment
  }

  defp create_archive do
    Cgc2046.Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "wish-tools-#{System.unique_integer([:positive])}",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, overrides \\ %{}) do
    Cgc2046.Flashback.Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: archive.id,
          full_name: "王小明",
          surname: "王",
          city: "北京",
          participation: :attended,
          email: "w@example.com",
          phone: "13900000001"
        },
        overrides
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp admin, do: Fixtures.platform_admin("wish-admin")

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp run_ok(tool, params, user) do
    {:reply, _, _} = reply = tool.execute(params, Frame.new(current_user: user))
    {:ok, decode(reply)}
  end

  describe "门控（R19 fail-closed）" do
    test "无 MCP 身份 → unauthenticated（业务 fun 不执行）" do
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AdminListWishes.execute(%{}, Frame.new())

      assert msg =~ "unauthenticated"
    end

    test "非平台管理员 → forbidden" do
      member = Fixtures.register_user("wish-member")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AdminListWishes.execute(%{}, Frame.new(current_user: member))

      assert msg =~ "forbidden"
    end
  end

  describe "admin_list_wishes（R18）" do
    test "全部许愿含私有；visibility 过滤；列表无联系方式" do
      archive = create_archive()
      p = create_person(archive)
      {:ok, pub} = Wishes.create_wish(p.id, "公开愿望", "public")
      {:ok, _priv} = Wishes.create_wish(p.id, "私有愿望", "private")

      {:ok, result} = run_ok(AdminListWishes, %{}, admin())
      assert result["total_count"] == 2
      vis = result["wishes"] |> Enum.map(& &1["visibility"]) |> Enum.sort()
      assert vis == ["private", "public"]

      {:ok, only_pub} = run_ok(AdminListWishes, %{"visibility" => "public"}, admin())
      assert [%{"id" => pub_id}] = only_pub["wishes"]
      assert pub_id == pub.id

      row = hd(result["wishes"])
      refute Map.has_key?(row, "email")
      refute Map.has_key?(row["wisher"], "email")
      refute Map.has_key?(row["wisher"], "phone")
    end

    test "软删许愿不出现" do
      archive = create_archive()
      p = create_person(archive)
      {:ok, wish} = Wishes.create_wish(p.id, "将删", "public")
      {:ok, _} = Wishes.soft_delete_wish(wish.id, p.id)

      {:ok, result} = run_ok(AdminListWishes, %{}, admin())
      assert result["total_count"] == 0
    end
  end

  describe "admin_get_wish（R18 详情面）" do
    test "详情带联系方式与留言流；已删可按 id 读回 deleted_at" do
      archive = create_archive()
      p = create_person(archive)
      other = create_person(archive, %{full_name: "李雷", surname: "李"})
      {:ok, wish} = Wishes.create_wish(p.id, "一起出一本书", "public")
      {:ok, _} = Wishes.add_comment(other.id, wish.id, "算我一个")

      {:ok, detail} = run_ok(AdminGetWish, %{"wish_id" => wish.id}, admin())
      assert detail["wisher"]["email"] == "w@example.com"
      assert [%{"content" => "算我一个", "commenter_masked" => "李*"}] = detail["comments"]
      assert is_nil(detail["deleted_at"])

      {:ok, _} = Wishes.soft_delete_wish(wish.id, p.id)
      {:ok, detail2} = run_ok(AdminGetWish, %{"wish_id" => wish.id}, admin())
      assert detail2["deleted_at"] != nil
    end

    test "不存在 id → not found" do
      assert {:error, %Anubis.MCP.Error{message: m}, _} =
               AdminGetWish.execute(
                 %{"wish_id" => Ecto.UUID.generate()},
                 Frame.new(current_user: admin())
               )

      assert m =~ "wish not found"
    end
  end

  describe "admin_soft_delete_wish（两段式）" do
    test "无/空白 reason → 快速失败；确认段走 KTD4 单源软删" do
      archive = create_archive()
      p = create_person(archive)
      {:ok, wish} = Wishes.create_wish(p.id, "待治理", "public")
      actor = admin()

      assert {:error, %Anubis.MCP.Error{message: e1}, _} =
               AdminSoftDeleteWish.execute(
                 %{"wish_id" => wish.id, "reason" => "  "},
                 Frame.new(current_user: actor)
               )

      assert e1 =~ "reason"

      assert {:ok, pending} =
               run_ok(AdminSoftDeleteWish, %{"wish_id" => wish.id, "reason" => "测试治理删除"}, actor)

      assert pending["status"] == "needs_confirmation"
      assert pending["summary"] =~ "待治理"
      assert pending["summary"] =~ "测试治理删除"

      assert {:ok, confirmed} =
               AdminSoftDeleteWish.execute_confirmed(actor, %{
                 "wish_id" => wish.id,
                 "reason" => "测试治理删除"
               })

      assert confirmed["deleted_at"] || confirmed[:deleted_at]

      {:ok, result} = run_ok(AdminListWishes, %{}, actor)
      assert result["total_count"] == 0
    end

    test "已删愿望再删 → already deleted（不建 pending）" do
      archive = create_archive()
      p = create_person(archive)
      {:ok, wish} = Wishes.create_wish(p.id, "已删", "public")
      {:ok, _} = Wishes.soft_delete_wish(wish.id, p.id)

      assert {:error, %Anubis.MCP.Error{message: e}, _} =
               AdminSoftDeleteWish.execute(
                 %{"wish_id" => wish.id, "reason" => "再删"},
                 Frame.new(current_user: admin())
               )

      assert e =~ "already deleted"
    end
  end

  describe "admin_soft_delete_wish_comment（两段式）" do
    test "留言删除走同一域函数；重复确认幂等" do
      archive = create_archive()
      owner = create_person(archive)
      commenter = create_person(archive, %{full_name: "李雷", surname: "李"})
      {:ok, wish} = Wishes.create_wish(owner.id, "有留言的愿", "public")
      {:ok, [comment | _]} = Wishes.add_comment(commenter.id, wish.id, "待删留言")
      actor = admin()

      {:ok, pending} =
        run_ok(AdminSoftDeleteWishComment, %{"comment_id" => comment.id, "reason" => "治理"}, actor)

      assert pending["status"] == "needs_confirmation"

      assert {:ok, result} =
               AdminSoftDeleteWishComment.execute_confirmed(actor, %{"comment_id" => comment.id})

      assert result[:remaining_comment_count] == 0 || result["remaining_comment_count"] == 0

      # 幂等重放：已删留言不再重复处理（软删函数对已删行返回 {:error, not_found} → 幂等分支）
      assert {:ok, replay} =
               AdminSoftDeleteWishComment.execute_confirmed(actor, %{"comment_id" => comment.id})

      assert Map.get(replay, :already_deleted) || Map.get(replay, "already_deleted") ||
               Map.get(replay, :deleted_at) || Map.get(replay, "deleted_at")
    end
  end
end
