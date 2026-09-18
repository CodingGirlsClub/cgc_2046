defmodule Cgc2046.Recruitment.ApplicationTest do
  @moduledoc """
  志愿者申请数据面与 policy 边界（R8/KTD2；Covers AE2）。

  - 同批一份：identity `[:user_id, :cohort_id]`，换职位不重置（AE2 前半）；
  - 下一批可换职位再申（AE2 后半）；
  - 读面：本人 ∪ Owner/Admin ∪ platform_admin；create 限本人（user_id 不可伪造）。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Recruitment.{RecruitmentCohort, VolunteerApplication}

  require Ash.Query

  setup do
    creator = Fixtures.platform_admin("application-creator")
    workspace = Fixtures.create_workspace(creator)

    owner = Fixtures.register_user("application-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    applicant = Fixtures.register_user("application-applicant")
    Fixtures.add_member(workspace, applicant, [:volunteer])

    peer = Fixtures.register_user("application-peer")
    Fixtures.add_member(workspace, peer, [:volunteer])

    cohort = create_cohort(workspace, owner, "第 1 批")

    %{
      creator: creator,
      workspace: workspace,
      owner: owner,
      applicant: applicant,
      peer: peer,
      cohort: cohort
    }
  end

  describe "同批一份（AE2）" do
    test "同批第二份申请（换职位）被拒（稳定 code）；换批次再申成功", ctx do
      %{workspace: ws, owner: owner, applicant: applicant, cohort: cohort} = ctx

      assert {:ok, first} = apply(ws, applicant, cohort, %{position: :event_moderator})
      assert first.status == :submitted
      assert first.workspace_id == ws.id
      assert first.user_id == applicant.id

      # 换职位仍是同一批次同一人 → 拒
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               apply(ws, applicant, cohort, %{position: :tutor})

      assert Enum.any?(
               errors,
               &match?(%BusinessError{code: "volunteer_application_already_submitted"}, &1)
             ),
             "expected volunteer_application_already_submitted, got: #{inspect(errors)}"

      # 仅落一份
      assert [%{id: id, position: :event_moderator}] =
               VolunteerApplication
               |> Ash.Query.filter(user_id == ^applicant.id)
               |> Ash.read!(authorize?: false)

      assert id == first.id

      # 下一批可换职位再申（AE2 后半）：同台至多一个 open，先关第 1 批
      close_cohort(ws, owner, cohort)
      next_cohort = create_cohort(ws, owner, "第 2 批")
      assert {:ok, second} = apply(ws, applicant, next_cohort, %{position: :tutor})
      assert second.cohort_id == next_cohort.id
      assert second.position == :tutor
    end

    test "同批他人申请不受影响（唯一性按 (user_id, cohort_id) 而非批次）", ctx do
      %{workspace: ws, applicant: applicant, peer: peer, cohort: cohort} = ctx

      assert {:ok, _} = apply(ws, applicant, cohort, %{position: :event_moderator})
      assert {:ok, peer_application} = apply(ws, peer, cohort, %{position: :coach})
      assert peer_application.user_id == peer.id
    end
  end

  describe "写入面（KTD2）" do
    test "user_id 不进 accept 通道（伪造输入直接被拒）；正常路径 user_id = actor", ctx do
      %{workspace: ws, applicant: applicant, peer: peer, cohort: cohort} = ctx

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               VolunteerApplication
               |> Ash.Changeset.for_create(
                 :create,
                 %{cohort_id: cohort.id, position: :coach, user_id: peer.id},
                 tenant: ws.id
               )
               |> Ash.create(tenant: ws.id, actor: applicant)

      assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{}, &1)),
             "expected NoSuchInput for :user_id, got: #{inspect(errors)}"

      # 代他人提交不可达：user_id 唯一来源是 actor
      assert {:ok, application} = apply(ws, applicant, cohort, %{position: :coach})
      assert application.user_id == applicant.id
    end

    test "匿名提交被拒", ctx do
      %{workspace: ws, cohort: cohort} = ctx

      assert {:error, %Ash.Error.Forbidden{}} =
               VolunteerApplication
               |> Ash.Changeset.for_create(
                 :create,
                 %{cohort_id: cohort.id, position: :tutor},
                 tenant: ws.id
               )
               |> Ash.create(tenant: ws.id, actor: nil)
    end

    test "职位枚举约束：未知职位被拒", ctx do
      %{workspace: ws, applicant: applicant, cohort: cohort} = ctx

      assert {:error, %Ash.Error.Invalid{}} =
               VolunteerApplication
               |> Ash.Changeset.for_create(
                 :create,
                 %{cohort_id: cohort.id, position: "chapter_host"},
                 tenant: ws.id
               )
               |> Ash.create(tenant: ws.id, actor: applicant)
    end
  end

  describe "读面（KTD2：本人 ∪ Owner/Admin ∪ platform_admin）" do
    test "本人可读；同台普通成员与匿名读不到他人申请；Owner/Admin 读全台", ctx do
      %{
        workspace: ws,
        owner: owner,
        creator: creator,
        applicant: applicant,
        peer: peer,
        cohort: cohort
      } =
        ctx

      {:ok, application} = apply(ws, applicant, cohort, %{position: :event_moderator})

      assert {:ok, [mine]} = Ash.read(VolunteerApplication, tenant: ws.id, actor: applicant)
      assert mine.id == application.id

      assert {:ok, []} = Ash.read(VolunteerApplication, tenant: ws.id, actor: peer)

      # 匿名：actor 锚定的读面无可满足分支 → Forbidden（不是空集）
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(VolunteerApplication, tenant: ws.id, actor: nil)

      assert {:ok, [by_owner]} = Ash.read(VolunteerApplication, tenant: ws.id, actor: owner)
      assert by_owner.id == application.id

      assert {:ok, [by_admin]} = Ash.read(VolunteerApplication, tenant: ws.id, actor: creator)
      assert by_admin.id == application.id
    end

    test "他人不可读取本记录（严格单条读）", ctx do
      %{workspace: ws, applicant: applicant, peer: peer, cohort: cohort} = ctx

      {:ok, application} = apply(ws, applicant, cohort, %{position: :event_moderator})

      refute match?(
               {:ok, %VolunteerApplication{}},
               Ash.get(VolunteerApplication, application.id, tenant: ws.id, actor: peer)
             )
    end

    test "tenant 隔离：他台读不到本台申请", ctx do
      %{workspace: ws, creator: creator, applicant: applicant, cohort: cohort} = ctx

      {:ok, _} = apply(ws, applicant, cohort, %{position: :tutor})

      other_ws = Fixtures.create_workspace(creator, %{slug: "application-other-ws"})
      assert {:ok, []} = Ash.read(VolunteerApplication, tenant: other_ws.id, actor: creator)
    end
  end

  defp close_cohort(workspace, actor, cohort) do
    {:ok, closed} =
      cohort
      |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    closed
  end

  # 申请用例的批次一律 open（R8：仅 open 批次接收申请；draft 拒绝是行为契约）
  defp create_cohort(workspace, actor, name) do
    {:ok, cohort} =
      RecruitmentCohort
      |> Ash.Changeset.for_create(
        :create,
        %{name: name, apply_deadline_at: DateTime.add(DateTime.utc_now(), 14, :day)},
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    {:ok, opened} =
      cohort
      |> Ash.Changeset.for_update(:open, %{}, tenant: workspace.id, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    opened
  end

  defp apply(workspace, actor, cohort, attrs) do
    attrs =
      Map.merge(
        %{
          cohort_id: cohort.id,
          city: "上海",
          heard_about_us: "公众号",
          has_internal_referrer: false,
          message: "希望参与"
        },
        attrs
      )

    VolunteerApplication
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create(tenant: workspace.id, actor: actor)
  end
end
