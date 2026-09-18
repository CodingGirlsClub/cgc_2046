defmodule Cgc2046.Recruitment.CohortTest do
  @moduledoc """
  招募批次数据面与 policy 边界（R8/KTD2；Covers AE9）。

  - 「同一 workspace 至多一个 open」由 DB 部分唯一索引承载（并发安全），
    第二个 open 落稳定 code，非 open 的 draft/closed 不受限；
  - 读面：匿名只见 open（公开申请页面），Owner/Admin 见全量；
  - 写面：限 Owner/Admin ∪ platform_admin。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Recruitment.RecruitmentCohort

  setup do
    # workspace 创建限 platform_admin（Workspace create policy），故库主是 platform_admin；
    # Owner 另由 add_member 授予 [:owner]，用于验证 WorkspaceActorIsOwnerOrAdmin 分支
    creator = Fixtures.platform_admin("cohort-creator")
    workspace = Fixtures.create_workspace(creator)

    owner = Fixtures.register_user("cohort-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    volunteer = Fixtures.register_user("cohort-volunteer")
    Fixtures.add_member(workspace, volunteer, [:volunteer])

    %{
      creator: creator,
      workspace: workspace,
      owner: owner,
      volunteer: volunteer,
      outsider: Fixtures.register_user("cohort-outsider")
    }
  end

  describe "至多一个 open（AE9）" do
    test "已有一个 open 批次再开放第二个 → 被拒（稳定 code）；关闭旧批后开放成功", ctx do
      %{workspace: ws, owner: owner} = ctx

      first = create_cohort(ws, owner, %{name: "第 1 批"})
      assert {:ok, open_first} = open_cohort(first, ws.id, owner)
      assert open_first.status == :open

      # draft 不受唯一 open 约束（若 identity 误按 workspace_id 全量 eager check，
      # 这里就会被「has already been taken」误拒）
      second = create_cohort(ws, owner, %{name: "第 2 批"})
      assert second.status == :draft

      assert {:error, %Ash.Error.Invalid{errors: errors}} = open_cohort(second, ws.id, owner)

      assert Enum.any?(
               errors,
               &match?(%BusinessError{code: "recruitment_cohort_open_conflict"}, &1)
             ),
             "expected recruitment_cohort_open_conflict, got: #{inspect(errors)}"

      # 失败不落状态（原行仍是 draft）
      assert Ash.get!(RecruitmentCohort, second.id, tenant: ws.id, authorize?: false).status ==
               :draft

      assert {:ok, closed} = close_cohort(open_first, ws.id, owner)
      assert closed.status == :closed

      assert {:ok, opened_second} = open_cohort(second, ws.id, owner)
      assert opened_second.status == :open
    end

    test "唯一 open 按 workspace 隔离：他台 open 批次不阻塞本台", ctx do
      %{creator: creator, owner: owner} = ctx

      other_ws = Fixtures.create_workspace(creator, %{slug: "cohort-other-ws"})
      other_owner = Fixtures.register_user("cohort-other-owner")
      Fixtures.add_member(other_ws, other_owner, [:owner])

      open_cohort(create_cohort(ctx.workspace, owner), ctx.workspace.id, owner)

      assert {:ok, other} =
               open_cohort(create_cohort(other_ws, other_owner), other_ws.id, other_owner)

      assert other.status == :open
    end
  end

  describe "读面（KTD2）" do
    test "匿名只见 open 批次；非 open 不出现在结果里", ctx do
      %{workspace: ws, owner: owner} = ctx

      draft = create_cohort(ws, owner, %{name: "草稿批次"})

      opened =
        create_cohort(ws, owner, %{name: "开放批次"})
        |> then(&open_cohort(&1, ws.id, owner))
        |> elem(1)

      assert {:ok, anonymous} = Ash.read(RecruitmentCohort, tenant: ws.id, actor: nil)
      assert Enum.map(anonymous, & &1.id) == [opened.id]
      refute draft.id in Enum.map(anonymous, & &1.id)

      # 管理面见全量（draft 可见）
      assert {:ok, admin_view} = Ash.read(RecruitmentCohort, tenant: ws.id, actor: owner)
      assert Enum.sort(Enum.map(admin_view, & &1.id)) == Enum.sort([draft.id, opened.id])
    end

    test "tenants 隔离：他台租户读不到本台批次，全局读只见 open", ctx do
      %{creator: creator, workspace: ws, owner: owner} = ctx

      other_ws = Fixtures.create_workspace(creator, %{slug: "cohort-read-other-ws"})

      draft = create_cohort(ws, owner, %{name: "本台草稿"})

      opened =
        create_cohort(ws, owner, %{name: "本台开放"})
        |> then(&open_cohort(&1, ws.id, owner))
        |> elem(1)

      assert {:ok, []} = Ash.read(RecruitmentCohort, tenant: other_ws.id, actor: owner)

      assert {:ok, global} = Ash.read(RecruitmentCohort, actor: nil)
      global_ids = Enum.map(global, & &1.id)
      assert opened.id in global_ids
      refute draft.id in global_ids
    end
  end

  describe "写面（KTD2）" do
    test "普通成员与匿名不可创建；Owner 与 platform_admin 可创建", ctx do
      %{creator: creator, workspace: ws, owner: owner, volunteer: volunteer} = ctx

      assert {:error, %Ash.Error.Forbidden{}} =
               RecruitmentCohort
               |> Ash.Changeset.for_create(:create, cohort_attrs(), tenant: ws.id)
               |> Ash.create(tenant: ws.id, actor: volunteer)

      assert {:error, %Ash.Error.Forbidden{}} =
               RecruitmentCohort
               |> Ash.Changeset.for_create(:create, cohort_attrs(), tenant: ws.id)
               |> Ash.create(tenant: ws.id, actor: nil)

      assert {:ok, by_owner} = create_cohort_result(ws, owner)
      assert by_owner.status == :draft

      assert {:ok, by_admin} = create_cohort_result(ws, creator)
      assert by_admin.status == :draft
    end

    test "普通成员不可开放/关闭批次", ctx do
      %{workspace: ws, owner: owner, volunteer: volunteer} = ctx

      cohort = create_cohort(ws, owner, %{name: "权限批次"})

      assert {:error, %Ash.Error.Forbidden{}} = open_cohort(cohort, ws.id, volunteer)
      assert {:ok, _} = open_cohort(cohort, ws.id, owner)
      assert {:error, %Ash.Error.Forbidden{}} = close_cohort(cohort, ws.id, volunteer)
    end

    test "Owner 可改批次信息（名称/截止）；普通成员不可", ctx do
      %{workspace: ws, owner: owner, volunteer: volunteer} = ctx

      cohort = create_cohort(ws, owner, %{name: "旧名"})

      assert {:ok, updated} =
               cohort
               |> Ash.Changeset.for_update(:update, %{name: "新名"}, tenant: ws.id)
               |> Ash.update(tenant: ws.id, actor: owner)

      assert updated.name == "新名"

      assert {:error, %Ash.Error.Forbidden{}} =
               updated
               |> Ash.Changeset.for_update(:update, %{name: "篡改"}, tenant: ws.id)
               |> Ash.update(tenant: ws.id, actor: volunteer)

      assert Ash.get!(RecruitmentCohort, cohort.id, tenant: ws.id, authorize?: false).name == "新名"
    end

    test "他台 Owner 不可写本台批次（policy 按目标租户判定，不按 actor 全局身份）", ctx do
      %{creator: creator, workspace: ws, owner: owner} = ctx

      other_ws = Fixtures.create_workspace(creator, %{slug: "cohort-write-other-ws"})
      other_owner = Fixtures.register_user("cohort-other-ws-owner")
      Fixtures.add_member(other_ws, other_owner, [:owner])

      cohort = create_cohort(ws, owner, %{name: "本台批次"})

      assert {:error, %Ash.Error.Forbidden{}} = open_cohort(cohort, ws.id, other_owner)
    end
  end

  defp cohort_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        name: "测试批次",
        apply_deadline_at: DateTime.add(DateTime.utc_now(), 14, :day)
      },
      attrs
    )
  end

  defp create_cohort_result(workspace, actor, attrs \\ %{}) do
    RecruitmentCohort
    |> Ash.Changeset.for_create(:create, cohort_attrs(attrs), tenant: workspace.id)
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  defp create_cohort(workspace, actor, attrs \\ %{}) do
    {:ok, cohort} = create_cohort_result(workspace, actor, attrs)
    cohort
  end

  defp open_cohort(cohort, tenant, actor) do
    cohort
    |> Ash.Changeset.for_update(:open, %{}, tenant: tenant)
    |> Ash.update(tenant: tenant, actor: actor)
  end

  defp close_cohort(cohort, tenant, actor) do
    cohort
    |> Ash.Changeset.for_update(:close, %{}, tenant: tenant)
    |> Ash.update(tenant: tenant, actor: actor)
  end
end
