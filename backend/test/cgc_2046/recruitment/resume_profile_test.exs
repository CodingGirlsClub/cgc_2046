defmodule Cgc2046.Recruitment.ResumeProfileTest do
  @moduledoc """
  简历档案数据面与 PIPL policy 边界（R9/KTD2；Covers AE5 的档案侧）。

  - 一人一档：identity `[:workspace_id, :user_id]` + `:upsert` 动作（二次上传更新而非新建）；
  - 读面：仅本人 ∪ Owner/Admin ∪ platform_admin（他人读 = 策略过滤后的空集）；
  - 写面：仅本人（他人 update 严格检查 → Forbidden）。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Recruitment.ResumeProfile

  require Ash.Query

  setup do
    creator = Fixtures.platform_admin("resume-creator")
    workspace = Fixtures.create_workspace(creator)

    owner = Fixtures.register_user("resume-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    applicant = Fixtures.register_user("resume-applicant")
    Fixtures.add_member(workspace, applicant, [:volunteer])

    other = Fixtures.register_user("resume-other")
    Fixtures.add_member(workspace, other, [:volunteer])

    %{creator: creator, workspace: workspace, owner: owner, applicant: applicant, other: other}
  end

  describe "一人一档（AE5 数据面）" do
    test "本人二次 upsert 更新而非新建；不同用户/不同台互不干扰", ctx do
      %{workspace: ws, applicant: applicant, other: other} = ctx

      {:ok, first} = upsert(ws, applicant, %{full_name: "张三", contact_email: "zhang@example.com"})
      assert first.workspace_id == ws.id
      assert first.user_id == applicant.id

      {:ok, second} =
        upsert(ws, applicant, %{
          full_name: "张三（更新）",
          contact_email: "zhang2@example.com",
          weekly_hours: 8,
          skills: ["活动运营", "摄影"]
        })

      assert second.id == first.id
      assert second.full_name == "张三（更新）"
      assert second.contact_email == "zhang2@example.com"
      assert second.weekly_hours == 8
      assert second.skills == ["活动运营", "摄影"]

      assert [%{id: id}] =
               ResumeProfile
               |> Ash.Query.filter(user_id == ^applicant.id)
               |> Ash.read!(authorize?: false)

      assert id == first.id

      # 同台另一人 = 另一档
      {:ok, other_profile} =
        upsert(ws, other, %{full_name: "李四", contact_email: "li@example.com"})

      refute other_profile.id == first.id
    end

    test "contact_email 必填（R9：邮件保底通道收件地址）", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      assert {:error, %Ash.Error.Invalid{}} =
               ResumeProfile
               |> Ash.Changeset.for_create(:upsert, %{full_name: "无邮箱"}, tenant: ws.id)
               |> Ash.create(tenant: ws.id, actor: applicant)

      assert {:error, %Ash.Error.Invalid{}} =
               ResumeProfile
               |> Ash.Changeset.for_create(:upsert, %{contact_email: "no-name@example.com"},
                 tenant: ws.id
               )
               |> Ash.create(tenant: ws.id, actor: applicant)
    end

    test "user_id 不进 accept 通道（伪造输入直接被拒）；正常路径 user_id = actor", ctx do
      %{workspace: ws, applicant: applicant, other: other} = ctx

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               ResumeProfile
               |> Ash.Changeset.for_create(
                 :upsert,
                 %{full_name: "伪造", contact_email: "forge@example.com", user_id: other.id},
                 tenant: ws.id
               )
               |> Ash.create(tenant: ws.id, actor: applicant)

      assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{}, &1)),
             "expected NoSuchInput for :user_id, got: #{inspect(errors)}"

      # 伪造他人档案不可达：user_id 唯一来源是 actor
      {:ok, profile} =
        upsert(ws, applicant, %{full_name: "张三", contact_email: "zhang@example.com"})

      assert profile.user_id == applicant.id
    end
  end

  describe "读面（KTD2：仅本人 ∪ Owner/Admin ∪ platform_admin）" do
    test "本人可读；同台普通成员读不到他人档案；匿名读被拒", ctx do
      %{workspace: ws, applicant: applicant, other: other} = ctx

      {:ok, profile} =
        upsert(ws, applicant, %{full_name: "张三", contact_email: "zhang@example.com"})

      assert {:ok, [mine]} = Ash.read(ResumeProfile, tenant: ws.id, actor: applicant)
      assert mine.id == profile.id

      assert {:ok, []} = Ash.read(ResumeProfile, tenant: ws.id, actor: other)

      # 匿名：actor 锚定的读面无可满足分支 → Forbidden（不是空集）
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(ResumeProfile, tenant: ws.id, actor: nil)

      refute match?(
               {:ok, %ResumeProfile{}},
               Ash.get(ResumeProfile, profile.id, tenant: ws.id, actor: other)
             )
    end

    test "Owner/Admin 与 platform_admin 可读全台档案（R13）", ctx do
      %{workspace: ws, owner: owner, creator: creator, applicant: applicant, other: other} = ctx

      {:ok, mine} = upsert(ws, applicant, %{full_name: "张三", contact_email: "zhang@example.com"})
      {:ok, theirs} = upsert(ws, other, %{full_name: "李四", contact_email: "li@example.com"})

      assert {:ok, rows} = Ash.read(ResumeProfile, tenant: ws.id, actor: owner)
      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort([mine.id, theirs.id])

      assert {:ok, admin_rows} = Ash.read(ResumeProfile, tenant: ws.id, actor: creator)
      assert length(admin_rows) == 2

      # 跨台平台管理员：tenant 隔离仍然生效（本台无档案则空）
      other_ws = Fixtures.create_workspace(creator, %{slug: "resume-read-other-ws"})
      assert {:ok, []} = Ash.read(ResumeProfile, tenant: other_ws.id, actor: creator)
    end
  end

  describe "写面（KTD2：仅本人可写）" do
    test "他人 update 被拒；匿名 upsert 被拒", ctx do
      %{workspace: ws, applicant: applicant, other: other} = ctx

      {:ok, profile} =
        upsert(ws, applicant, %{full_name: "张三", contact_email: "zhang@example.com"})

      assert {:error, %Ash.Error.Forbidden{}} =
               profile
               |> Ash.Changeset.for_update(:update, %{full_name: "篡改"}, tenant: ws.id)
               |> Ash.update(tenant: ws.id, actor: other)

      assert Ash.get!(ResumeProfile, profile.id, tenant: ws.id, authorize?: false).full_name ==
               "张三"

      assert {:error, %Ash.Error.Forbidden{}} =
               ResumeProfile
               |> Ash.Changeset.for_create(
                 :upsert,
                 %{full_name: "匿名", contact_email: "anon@example.com"},
                 tenant: ws.id
               )
               |> Ash.create(tenant: ws.id, actor: nil)
    end

    test "本人可更新", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      {:ok, profile} =
        upsert(ws, applicant, %{full_name: "张三", contact_email: "zhang@example.com"})

      assert {:ok, updated} =
               profile
               |> Ash.Changeset.for_update(:update, %{weekly_hours: 5}, tenant: ws.id)
               |> Ash.update(tenant: ws.id, actor: applicant)

      assert updated.weekly_hours == 5
    end
  end

  defp upsert(workspace, actor, attrs) do
    ResumeProfile
    |> Ash.Changeset.for_create(:upsert, attrs, tenant: workspace.id)
    |> Ash.create(tenant: workspace.id, actor: actor)
  end
end
