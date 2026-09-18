defmodule Cgc2046Web.Graphql.RecruitmentQueriesTest do
  @moduledoc """
  U5 验收：招募域 GraphQL 契约（申请侧 R10/R11 + 管理侧 R13）经 /api/graphql 端到端。

  覆盖：

  - currentRecruitmentCohort：匿名可读 open 批次；无 open（draft/closed）→ null（AE12
    数据面）；tenant 隔离（他台读不到本台批次）。
  - myResumeProfile / upsertResumeProfile：未登录 unauthorized；一人一档（二次 upsert
    更新同一行）；本人视角（他人档案不露面）。
  - createVolunteerApplication：未登录 unauthorized；成功 → submitted 且 user_id = actor；
    同批重复 → volunteer_application_already_submitted（AE2 数据面）；批次关闭 →
    volunteer_application_cohort_closed；批次不存在 → volunteer_application_cohort_not_found。
  - myVolunteerApplications：本人可见自己的申请，看不到他人（R13 申请人侧读面）。
  - listVolunteerApplications：Owner 全量 + 按批次/职位过滤 + first/after 分页；非管理
    成员 / 非本台 Owner → forbidden；platform_admin 穿透；未登录 unauthorized。
  - 段位流转（advance/assign/reject/cancel）：Owner 可流转；拒绝必带原因（AE3 数据面）、
    取消无必填原因（AE8）；非法段位 → volunteer_application_invalid_transition；
    申请人本人 → forbidden（KTD2 边界）；跨台 id → not_found。
  - 批次管理：create → draft、open → open、第二个 open → recruitment_cohort_open_conflict
    （AE9 数据面）、close 后可再开；非管理成员 forbidden。
  - volunteerApplicationDetail：申请 + 申请人简历档案元数据；无档案 → null；非管理
    forbidden；跨台/不存在 → not_found / null。
  - 简历文件内容列不出 GraphQL 面（`file_data` 不可选——KTD3：文件读写走 U2 专线）。

  行为断言主路径在 test/cgc_2046/recruitment/*（Ash 层），本测试只证明手写 resolver
  的接线、租户/授权门控与错误协议（code 稳定，前端按 code 查文案）。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Recruitment.{RecruitmentCohort, ResumeProfile, VolunteerApplication}

  require Ash.Query

  setup do
    # workspace 创建限 platform_admin（Workspace create policy）
    creator = Fixtures.platform_admin("recq-creator")
    workspace = Fixtures.create_workspace(creator)

    owner = Fixtures.register_user("recq-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    # 普通成员（非管理角色）：管理面边界对照组
    member = Fixtures.register_user("recq-member")
    Fixtures.add_member(workspace, member, [:volunteer])

    # 申请人不是成员（R15：项目分配时才邀请入台）
    applicant = Fixtures.register_user("recq-applicant")

    # 他台 Owner：跨台调用对照组
    other_owner = Fixtures.register_user("recq-other-owner")
    other_workspace = Fixtures.create_workspace(creator)
    Fixtures.add_member(other_workspace, other_owner, [:owner])

    platform_admin = Fixtures.platform_admin("recq-platform-admin")

    %{
      creator: creator,
      workspace: workspace,
      owner: owner,
      owner_token: sign_in_token(owner),
      member: member,
      member_token: sign_in_token(member),
      applicant: applicant,
      applicant_token: sign_in_token(applicant),
      other_owner: other_owner,
      other_owner_token: sign_in_token(other_owner),
      other_workspace: other_workspace,
      platform_admin: platform_admin,
      platform_admin_token: sign_in_token(platform_admin)
    }
  end

  describe "currentRecruitmentCohort（匿名公开读，R10/AE12 数据面）" do
    test "无 open 批次（draft）→ null；开放后返回 open；关闭后回到 null", %{
      workspace: ws,
      owner: owner
    } do
      cohort = create_cohort(ws, owner, %{name: "第 1 批"})

      query = cohort_query(ws.id)

      assert %{"data" => %{"currentRecruitmentCohort" => nil}} =
               build_conn() |> graphql_post(query)

      {:ok, opened} = open_cohort(ws, owner, cohort)
      assert opened.status == :open

      assert %{"data" => %{"currentRecruitmentCohort" => found}} =
               build_conn() |> graphql_post(query)

      assert found["id"] == cohort.id
      assert found["name"] == "第 1 批"
      assert found["status"] == "open"
      assert is_binary(found["applyDeadlineAt"])

      {:ok, _closed} = close_cohort(ws, owner, cohort)

      assert %{"data" => %{"currentRecruitmentCohort" => nil}} =
               build_conn() |> graphql_post(query)
    end

    test "tenant 隔离：他台的 open 批次不出现在本台入口", %{
      workspace: ws,
      other_workspace: other_ws,
      other_owner: other_owner
    } do
      other_cohort = create_cohort(other_ws, other_owner, %{name: "他台批次"})
      {:ok, _opened} = open_cohort(other_ws, other_owner, other_cohort)

      assert %{"data" => %{"currentRecruitmentCohort" => nil}} =
               build_conn() |> graphql_post(cohort_query(ws.id))

      assert %{"data" => %{"currentRecruitmentCohort" => found}} =
               build_conn() |> graphql_post(cohort_query(other_ws.id))

      assert found["id"] == other_cohort.id
    end
  end

  describe "myResumeProfile / upsertResumeProfile（R11 第 1 步）" do
    test "未登录：query 与 mutation 均 unauthorized", %{workspace: ws} do
      assert %{"errors" => [%{"code" => "unauthorized"}]} =
               build_conn()
               |> graphql_post("{ myResumeProfile(workspaceId: \"#{ws.id}\") { id } }")

      assert %{"errors" => [%{"code" => "unauthorized"}]} =
               build_conn()
               |> graphql_post(
                 upsert_resume_mutation(ws.id, %{
                   fullName: "张三",
                   contactEmail: "zhang@example.com"
                 })
               )
    end

    test "一人一档：首次建行，二次 upsert 更新同一行（含技能数组）", %{
      workspace: ws,
      applicant: applicant,
      applicant_token: token
    } do
      assert %{"data" => %{"upsertResumeProfile" => %{"result" => first, "errors" => []}}} =
               build_conn()
               |> graphql_post(
                 upsert_resume_mutation(ws.id, %{
                   fullName: "张三",
                   contactEmail: "zhang@example.com",
                   weeklyHours: 4,
                   skills: ["活动运营"]
                 }),
                 token
               )

      assert first["fullName"] == "张三"
      assert first["contactEmail"] == "zhang@example.com"
      assert first["weeklyHours"] == 4
      assert first["skills"] == ["活动运营"]
      # 文件态在 U2 才接线：本单元投影恒空
      assert first["fileName"] == nil
      assert first["fileSize"] == nil

      assert %{"data" => %{"upsertResumeProfile" => %{"result" => second, "errors" => []}}} =
               build_conn()
               |> graphql_post(
                 upsert_resume_mutation(ws.id, %{
                   fullName: "张三（更新）",
                   contactEmail: "zhang2@example.com",
                   skills: ["活动运营", "摄影"]
                 }),
                 token
               )

      assert second["id"] == first["id"]
      assert second["fullName"] == "张三（更新）"
      assert second["skills"] == ["活动运营", "摄影"]

      # upsert 只覆盖本次提交的字段（缺席字段保持原值，不是回落属性默认）：
      # 本次未传 weeklyHours → 仍是首次的 4。U7 第 1 步表单因此可做增量提交。
      assert second["weeklyHours"] == 4

      # 我的档案入口读回同一行；库里也只有一行
      assert %{"data" => %{"myResumeProfile" => mine}} =
               build_conn()
               |> graphql_post(
                 "{ myResumeProfile(workspaceId: \"#{ws.id}\") { id fullName contactEmail } }",
                 token
               )

      assert mine["id"] == first["id"]

      assert [%ResumeProfile{id: id, full_name: "张三（更新）"}] =
               ResumeProfile
               |> Ash.Query.filter(user_id == ^applicant.id)
               |> Ash.read!(tenant: ws.id, authorize?: false)

      assert id == first["id"]
    end

    test "本人视角：未建档返回 null，他人档案不出面（空集而非 forbidden）", %{
      workspace: ws,
      applicant: applicant,
      applicant_token: applicant_token,
      member_token: member_token
    } do
      assert %{"data" => %{"myResumeProfile" => nil}} =
               build_conn()
               |> graphql_post(
                 "{ myResumeProfile(workspaceId: \"#{ws.id}\") { id } }",
                 applicant_token
               )

      upsert_resume(ws, applicant, %{full_name: "张三", contact_email: "zhang@example.com"})

      # 另一账号读自己的档案：仍是 null（不是读到张三那份）
      assert %{"data" => %{"myResumeProfile" => nil}} =
               build_conn()
               |> graphql_post(
                 "{ myResumeProfile(workspaceId: \"#{ws.id}\") { id } }",
                 member_token
               )
    end

    test "contactEmail 为 schema 级必填（non_null input 字段）", %{
      workspace: ws,
      applicant_token: token
    } do
      assert %{"errors" => errors} =
               build_conn()
               |> graphql_post(upsert_resume_mutation(ws.id, %{fullName: "无名"}), token)

      assert Enum.any?(errors, &String.contains?(&1["message"], "contactEmail"))
    end
  end

  describe "createVolunteerApplication（R11 第 2 步）" do
    test "未登录 → unauthorized（create 限本人，匿名到不了 action）", %{
      workspace: ws,
      owner: owner
    } do
      cohort = open_cohort!(ws, owner)

      assert %{"errors" => [%{"code" => "unauthorized"}]} =
               build_conn()
               |> graphql_post(apply_mutation(ws.id, cohort.id, %{position: "tutor"}))
    end

    test "成功 → submitted、user_id = actor、字段落库", %{
      workspace: ws,
      owner: owner,
      applicant: applicant,
      applicant_token: token
    } do
      cohort = open_cohort!(ws, owner)

      assert %{"data" => %{"createVolunteerApplication" => %{"result" => result, "errors" => []}}} =
               build_conn()
               |> graphql_post(
                 apply_mutation(ws.id, cohort.id, %{
                   position: "tutor",
                   city: "上海",
                   heardAboutUs: "公众号",
                   hasInternalReferrer: true,
                   message: "希望参与"
                 }),
                 token
               )

      assert result["status"] == "submitted"
      assert result["position"] == "tutor"
      assert result["city"] == "上海"
      assert result["hasInternalReferrer"] == true
      assert result["cohortId"] == cohort.id
      # user_id 由 actor 强制填充（不接受客户端传入）
      assert result["userId"] == applicant.id
    end

    test "同批重复申请 → volunteer_application_already_submitted（AE2 数据面）", %{
      workspace: ws,
      owner: owner,
      applicant_token: token
    } do
      cohort = open_cohort!(ws, owner)

      assert %{"data" => %{"createVolunteerApplication" => %{"errors" => []}}} =
               build_conn()
               |> graphql_post(apply_mutation(ws.id, cohort.id, %{position: "tutor"}), token)

      # 换职位也拒（同批一份：职位不是唯一键的一部分）
      assert %{
               "data" => %{
                 "createVolunteerApplication" => %{
                   "result" => nil,
                   "errors" => [%{"code" => "volunteer_application_already_submitted"}]
                 }
               }
             } =
               build_conn()
               |> graphql_post(apply_mutation(ws.id, cohort.id, %{position: "coach"}), token)
    end

    test "批次已关闭 → volunteer_application_cohort_closed；批次不存在 → cohort_not_found", %{
      workspace: ws,
      owner: owner,
      applicant_token: token
    } do
      cohort = open_cohort!(ws, owner)
      {:ok, _closed} = close_cohort(ws, owner, cohort)

      assert %{
               "data" => %{
                 "createVolunteerApplication" => %{
                   "errors" => [%{"code" => "volunteer_application_cohort_closed"}]
                 }
               }
             } =
               build_conn()
               |> graphql_post(apply_mutation(ws.id, cohort.id, %{position: "tutor"}), token)

      assert %{
               "data" => %{
                 "createVolunteerApplication" => %{
                   "errors" => [%{"code" => "volunteer_application_cohort_not_found"}]
                 }
               }
             } =
               build_conn()
               |> graphql_post(
                 apply_mutation(ws.id, Ecto.UUID.generate(), %{position: "tutor"}),
                 token
               )
    end

    test "myVolunteerApplications 只见本人申请", %{
      workspace: ws,
      owner: owner,
      applicant_token: applicant_token,
      member: member
    } do
      cohort = open_cohort!(ws, owner)

      assert %{"data" => %{"createVolunteerApplication" => %{"result" => mine}}} =
               build_conn()
               |> graphql_post(
                 apply_mutation(ws.id, cohort.id, %{position: "tutor"}),
                 applicant_token
               )

      apply_for(ws, member, cohort, %{position: "coach"})

      assert %{"data" => %{"myVolunteerApplications" => [application]}} =
               build_conn()
               |> graphql_post(
                 "{ myVolunteerApplications(workspaceId: \"#{ws.id}\") { id userId status } }",
                 applicant_token
               )

      assert application["id"] == mine["id"]
      assert application["userId"] == mine["userId"]
      assert application["status"] == "submitted"
    end
  end

  describe "listVolunteerApplications（R13 管理列表：门控 + 过滤 + 分页）" do
    test "Owner 全量 + 按职位/批次过滤", %{
      workspace: ws,
      owner: owner,
      owner_token: token,
      applicant: applicant,
      member: member
    } do
      first_cohort = open_cohort!(ws, owner)

      apply_for(ws, applicant, first_cohort, %{position: :tutor})
      apply_for(ws, member, first_cohort, %{position: :coach})

      # 同台至多一个 open：先关第 1 批再开第 2 批（R8：仅 open 批次接收申请）
      {:ok, _} = close_cohort(ws, owner, first_cohort)
      second_cohort = open_cohort!(ws, owner)

      apply_for(ws, applicant, second_cohort, %{position: :tutor})

      assert %{"data" => %{"listVolunteerApplications" => all}} =
               build_conn() |> graphql_post(list_query(ws.id), token)

      assert length(all) == 3

      assert %{"data" => %{"listVolunteerApplications" => tutors}} =
               build_conn()
               |> graphql_post(list_query(ws.id, position: "tutor"), token)

      assert length(tutors) == 2
      assert Enum.all?(tutors, &(&1["position"] == "tutor"))

      assert %{"data" => %{"listVolunteerApplications" => in_cohort}} =
               build_conn()
               |> graphql_post(list_query(ws.id, cohort_id: first_cohort.id), token)

      assert length(in_cohort) == 2
      assert Enum.all?(in_cohort, &(&1["cohortId"] == first_cohort.id))

      # 非枚举职位值：静默忽略过滤（AdminList.maybe_status_filter 既有语义）
      assert %{"data" => %{"listVolunteerApplications" => unfiltered}} =
               build_conn()
               |> graphql_post(list_query(ws.id, position: "no_such_position"), token)

      assert length(unfiltered) == 3
    end

    test "分页：first 限条数、after 为偏移（拼页不重不漏）", %{
      workspace: ws,
      owner: owner,
      owner_token: token,
      applicant: applicant,
      member: member
    } do
      cohort = open_cohort!(ws, owner)

      third = Fixtures.register_user("recq-third")
      apply_for(ws, applicant, cohort, %{position: :tutor})
      apply_for(ws, member, cohort, %{position: :coach})
      apply_for(ws, third, cohort, %{position: :tutor})

      assert %{"data" => %{"listVolunteerApplications" => page1}} =
               build_conn()
               |> graphql_post(list_query(ws.id, first: 2), token)

      assert length(page1) == 2

      assert %{"data" => %{"listVolunteerApplications" => page2}} =
               build_conn()
               |> graphql_post(list_query(ws.id, first: 2, after: "2"), token)

      assert length(page2) == 1

      page1_ids = MapSet.new(page1, & &1["id"])
      page2_ids = MapSet.new(page2, & &1["id"])

      assert MapSet.disjoint?(page1_ids, page2_ids)

      # 两页拼起来 = 本台 3 份申请（不重不漏）
      assert MapSet.size(MapSet.union(page1_ids, page2_ids)) == 3
    end

    test "门控：非管理成员 / 非本台 Owner → forbidden；platform_admin 穿透", %{
      workspace: ws,
      owner: owner,
      member: member,
      member_token: member_token,
      other_owner_token: other_owner_token,
      other_workspace: other_ws,
      platform_admin_token: platform_admin_token,
      applicant: applicant
    } do
      cohort = open_cohort!(ws, owner)
      apply_for(ws, applicant, cohort, %{position: :tutor})
      apply_for(ws, member, cohort, %{position: :coach})

      assert %{"data" => nil, "errors" => [%{"code" => "forbidden"}]} =
               build_conn() |> graphql_post(list_query(ws.id), member_token)

      assert %{"data" => nil, "errors" => [%{"code" => "forbidden"}]} =
               build_conn() |> graphql_post(list_query(ws.id), other_owner_token)

      assert %{"data" => %{"listVolunteerApplications" => rows}} =
               build_conn() |> graphql_post(list_query(ws.id), platform_admin_token)

      assert length(rows) == 2

      # 未登录 → unauthorized（不是 forbidden）
      assert %{"errors" => [%{"code" => "unauthorized"}]} =
               build_conn() |> graphql_post(list_query(ws.id))

      # 本台 Owner 读他台列表 → forbidden（tenant 隔离）
      assert %{"data" => nil, "errors" => [%{"code" => "forbidden"}]} =
               build_conn() |> graphql_post(list_query(other_ws.id), sign_in_token(owner))
    end
  end

  describe "段位流转（R12/R13；KTD2 边界）" do
    test "Owner：submitted → interview → training → assigned（分配带场次与备注）", %{
      workspace: ws,
      owner: owner,
      owner_token: token,
      applicant: applicant
    } do
      cohort = open_cohort!(ws, owner)
      application = apply_for(ws, applicant, cohort, %{position: :tutor})
      event = EventFixtures.create_event(ws, owner)

      assert %{"data" => %{"advanceVolunteerApplicationToInterview" => %{"result" => interview}}} =
               build_conn()
               |> graphql_post(advance_mutation(:interview, ws.id, application.id), token)

      assert interview["status"] == "interview"

      assert %{"data" => %{"advanceVolunteerApplicationToTraining" => %{"result" => training}}} =
               build_conn()
               |> graphql_post(advance_mutation(:training, ws.id, application.id), token)

      assert training["status"] == "training"

      assert %{"data" => %{"assignVolunteerApplication" => %{"result" => assigned}}} =
               build_conn()
               |> graphql_post(
                 assign_mutation(ws.id, application.id, event.id, "Tutor 课程任务"),
                 token
               )

      assert assigned["status"] == "assigned"
      assert assigned["assignedEventId"] == event.id
      assert assigned["assignmentNote"] == "Tutor 课程任务"
      assert is_binary(assigned["assignedAt"])
    end

    test "拒绝必带原因 / 取消无必填原因（AE3、AE8 数据面）", %{
      workspace: ws,
      owner: owner,
      owner_token: token
    } do
      cohort = open_cohort!(ws, owner)

      # 同批一份（identity user_id + cohort_id）⇒ 四个场景各用一位申请人
      [missing, blank, rejected_applicant, canceled_applicant] =
        for prefix <- ~w(recq-reject-missing recq-reject-blank recq-reject-ok recq-cancel) do
          Fixtures.register_user(prefix)
        end

      # 无原因 → 域层稳定 code（必填规则单源在域层，不做 schema 级拦截）
      assert %{
               "data" => %{
                 "rejectVolunteerApplication" => %{
                   "result" => nil,
                   "errors" => [%{"code" => "volunteer_application_rejection_reason_required"}]
                 }
               }
             } =
               build_conn()
               |> graphql_post(
                 reject_mutation(ws.id, apply_for(ws, missing, cohort).id, nil),
                 token
               )

      # 空白原因同判缺失
      assert %{
               "data" => %{
                 "rejectVolunteerApplication" => %{
                   "errors" => [%{"code" => "volunteer_application_rejection_reason_required"}]
                 }
               }
             } =
               build_conn()
               |> graphql_post(
                 reject_mutation(ws.id, apply_for(ws, blank, cohort).id, "  "),
                 token
               )

      # 带原因 → rejected + 原因落库
      assert %{
               "data" => %{
                 "rejectVolunteerApplication" => %{"result" => rejected, "errors" => []}
               }
             } =
               build_conn()
               |> graphql_post(
                 reject_mutation(ws.id, apply_for(ws, rejected_applicant, cohort).id, "经验不匹配"),
                 token
               )

      assert rejected["status"] == "rejected"
      assert rejected["rejectionReason"] == "经验不匹配"

      # canceled 无必填原因（reason 省略即可；与 rejected 的必填约束刻意不同）
      assert %{
               "data" => %{
                 "cancelVolunteerApplication" => %{"result" => canceled, "errors" => []}
               }
             } =
               build_conn()
               |> graphql_post(
                 cancel_mutation(ws.id, apply_for(ws, canceled_applicant, cohort).id),
                 token
               )

      assert canceled["status"] == "canceled"
      assert canceled["rejectionReason"] == nil
    end

    test "非法段位流转 → volunteer_application_invalid_transition", %{
      workspace: ws,
      owner: owner,
      owner_token: token,
      applicant: applicant
    } do
      cohort = open_cohort!(ws, owner)
      application = apply_for(ws, applicant, cohort, %{position: :tutor})

      # submitted 直接 assign（跳过 interview/training）
      assert %{
               "data" => %{
                 "assignVolunteerApplication" => %{
                   "errors" => [%{"code" => "volunteer_application_invalid_transition"}]
                 }
               }
             } =
               build_conn()
               |> graphql_post(assign_mutation(ws.id, application.id, nil, nil), token)
    end

    test "门控：申请人本人 / 非管理成员 → forbidden；跨台 id → not_found", %{
      workspace: ws,
      owner: owner,
      owner_token: owner_token,
      applicant: applicant,
      applicant_token: applicant_token,
      member: member,
      member_token: member_token,
      other_owner: other_owner,
      other_owner_token: other_owner_token,
      other_workspace: other_ws,
      platform_admin_token: platform_admin_token
    } do
      cohort = open_cohort!(ws, owner)
      application = apply_for(ws, applicant, cohort, %{position: :tutor})

      mutation = advance_mutation(:interview, ws.id, application.id)

      assert_field_forbidden(
        build_conn() |> graphql_post(mutation, applicant_token),
        "advanceVolunteerApplicationToInterview"
      )

      assert_field_forbidden(
        build_conn() |> graphql_post(mutation, member_token),
        "advanceVolunteerApplicationToInterview"
      )

      # 跨台：本台申请 id 用他台 workspaceId 调用 → 非本台管理角色，forbidden
      assert_field_forbidden(
        build_conn() |> graphql_post(mutation, other_owner_token),
        "advanceVolunteerApplicationToInterview"
      )

      # platform_admin 穿透管理面（非本台成员，policy 的 PlatformAdmin 分支兜底）
      assert %{
               "data" => %{
                 "advanceVolunteerApplicationToInterview" => %{
                   "result" => %{"status" => "interview"},
                   "errors" => []
                 }
               }
             } =
               build_conn() |> graphql_post(mutation, platform_admin_token)

      # 本台 Owner 拿他台申请 id 在本台 tenant 内流转 → not_found（tenant 隔离，
      # 不泄露跨台存在性）
      other_cohort = open_cohort!(other_ws, other_owner)
      other_application = apply_for(other_ws, member, other_cohort, %{position: :tutor})

      assert %{
               "data" => %{
                 "advanceVolunteerApplicationToInterview" => %{
                   "errors" => [%{"code" => "not_found"}]
                 }
               }
             } =
               build_conn()
               |> graphql_post(
                 advance_mutation(:interview, ws.id, other_application.id),
                 owner_token
               )
    end
  end

  describe "批次管理（R13/批次 CRUD + 唯一 open 约束）" do
    test "create → draft；open → open；第二个 open → 冲突；close 后可再开", %{
      workspace: ws,
      owner_token: token
    } do
      assert %{"data" => %{"createRecruitmentCohort" => %{"result" => first, "errors" => []}}} =
               build_conn()
               |> graphql_post(create_cohort_mutation(ws.id, "第 1 批"), token)

      assert first["status"] == "draft"

      assert %{"data" => %{"openRecruitmentCohort" => %{"result" => opened, "errors" => []}}} =
               build_conn() |> graphql_post(open_mutation(ws.id, first["id"]), token)

      assert opened["status"] == "open"

      assert %{"data" => %{"createRecruitmentCohort" => %{"result" => second}}} =
               build_conn()
               |> graphql_post(create_cohort_mutation(ws.id, "第 2 批"), token)

      # AE9：同台至多一个 open（DB 部分唯一索引 → 稳定业务 code）
      assert %{
               "data" => %{
                 "openRecruitmentCohort" => %{
                   "result" => nil,
                   "errors" => [%{"code" => "recruitment_cohort_open_conflict"}]
                 }
               }
             } =
               build_conn() |> graphql_post(open_mutation(ws.id, second["id"]), token)

      assert %{"data" => %{"closeRecruitmentCohort" => %{"result" => closed, "errors" => []}}} =
               build_conn() |> graphql_post(close_mutation(ws.id, first["id"]), token)

      assert closed["status"] == "closed"

      assert %{"data" => %{"openRecruitmentCohort" => %{"result" => reopened, "errors" => []}}} =
               build_conn() |> graphql_post(open_mutation(ws.id, second["id"]), token)

      assert reopened["status"] == "open"
    end

    test "update 元数据 + listRecruitmentCohorts 管理面全量（Owner / platform_admin），非管理成员 forbidden",
         %{
           workspace: ws,
           owner: owner,
           owner_token: owner_token,
           member_token: member_token,
           platform_admin_token: platform_admin_token
         } do
      cohort = create_cohort(ws, owner, %{name: "第 1 批"})

      assert %{"data" => %{"updateRecruitmentCohort" => %{"result" => updated, "errors" => []}}} =
               build_conn()
               |> graphql_post(update_cohort_mutation(ws.id, cohort.id, "第 1 批（改）"), owner_token)

      assert updated["name"] == "第 1 批（改）"

      assert %{"data" => %{"listRecruitmentCohorts" => [row]}} =
               build_conn()
               |> graphql_post(
                 "{ listRecruitmentCohorts(workspaceId: \"#{ws.id}\") { id name status } }",
                 owner_token
               )

      assert row["id"] == cohort.id
      assert row["status"] == "draft"

      assert %{"data" => %{"listRecruitmentCohorts" => [_one]}} =
               build_conn()
               |> graphql_post(
                 "{ listRecruitmentCohorts(workspaceId: \"#{ws.id}\") { id } }",
                 platform_admin_token
               )

      assert %{"data" => nil, "errors" => [%{"code" => "forbidden"}]} =
               build_conn()
               |> graphql_post(
                 "{ listRecruitmentCohorts(workspaceId: \"#{ws.id}\") { id } }",
                 member_token
               )
    end
  end

  describe "volunteerApplicationDetail（R13 详情含简历档案）" do
    test "Owner：申请 + 申请人简历档案元数据；无档案 → null", %{
      workspace: ws,
      owner: owner,
      owner_token: token,
      applicant: applicant,
      member: member
    } do
      cohort = open_cohort!(ws, owner)
      application = apply_for(ws, applicant, cohort, %{position: :tutor})

      # 未建档
      assert %{
               "data" => %{
                 "volunteerApplicationDetail" => %{"application" => a, "resumeProfile" => nil}
               }
             } =
               build_conn() |> graphql_post(detail_query(ws.id, application.id), token)

      assert a["id"] == application.id

      upsert_resume(ws, applicant, %{
        full_name: "张三",
        contact_email: "zhang@example.com",
        weekly_hours: 6,
        skills: ["摄影"]
      })

      assert %{
               "data" => %{
                 "volunteerApplicationDetail" => %{
                   "application" => detail_app,
                   "resumeProfile" => resume
                 }
               }
             } =
               build_conn() |> graphql_post(detail_query(ws.id, application.id), token)

      assert detail_app["id"] == application.id
      assert resume["fullName"] == "张三"
      assert resume["contactEmail"] == "zhang@example.com"
      assert resume["weeklyHours"] == 6

      # 无档案的另一个申请人（member 也提过申请但没有简历档案）→ resumeProfile null
      member_application = apply_for(ws, member, cohort, %{position: :coach})

      assert %{"data" => %{"volunteerApplicationDetail" => %{"resumeProfile" => nil}}} =
               build_conn() |> graphql_post(detail_query(ws.id, member_application.id), token)
    end

    test "门控与边界：非管理 forbidden、跨台 not_found、不存在 null", %{
      workspace: ws,
      owner: owner,
      owner_token: owner_token,
      member_token: member_token,
      applicant: applicant,
      other_owner_token: other_owner_token
    } do
      cohort = open_cohort!(ws, owner)
      application = apply_for(ws, applicant, cohort, %{position: :tutor})

      assert_field_forbidden(
        build_conn() |> graphql_post(detail_query(ws.id, application.id), member_token),
        "volunteerApplicationDetail"
      )

      assert_field_forbidden(
        build_conn() |> graphql_post(detail_query(ws.id, application.id), other_owner_token),
        "volunteerApplicationDetail"
      )

      assert %{"data" => %{"volunteerApplicationDetail" => nil}} =
               build_conn()
               |> graphql_post(detail_query(ws.id, Ecto.UUID.generate()), owner_token)
    end

    test "简历文件内容列不出 GraphQL 面（KDT3：file_data 不可选，走 U2 专线）", %{
      workspace: ws,
      owner: owner,
      owner_token: token
    } do
      cohort = open_cohort!(ws, owner)
      application = apply_for(ws, owner, cohort, %{position: :tutor})

      query = """
      query {
        volunteerApplicationDetail(workspaceId: "#{ws.id}", id: "#{application.id}") {
          resumeProfile { fileData }
        }
      }
      """

      assert %{"errors" => errors} = build_conn() |> graphql_post(query, token)

      assert Enum.any?(errors, fn e ->
               e["message"] =~ "fileData" or e["message"] =~ "Cannot query field"
             end)
    end
  end

  # --- GraphQL 请求 helpers ---------------------------------------------------

  # 可空字段上的 resolver 错误（如 forbidden / not_found）：Absinthe 把该字段置
  # null（data 里键仍在），错误进顶层 errors 携 code——与 non_null 字段
  # （data 整体为 null）刻意不同，两种形状分别断言。
  defp assert_field_forbidden(payload, field) do
    assert %{"data" => %{^field => nil}, "errors" => errors} = payload
    assert Enum.any?(errors, &(&1["code"] == "forbidden"))
  end

  defp graphql_post(conn, query, token \\ nil) do
    conn =
      if token do
        put_req_header(conn, "authorization", "Bearer #{token}")
      else
        conn
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp sign_in_token(user) do
    query = """
    mutation {
      signIn(login: "#{user.email}", password: "#{Fixtures.password()}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  # --- GraphQL 文本 helpers ---------------------------------------------------

  defp cohort_query(workspace_id) do
    """
    query {
      currentRecruitmentCohort(workspaceId: "#{workspace_id}") {
        id name status applyDeadlineAt startsAt endsAt
      }
    }
    """
  end

  defp upsert_resume_mutation(workspace_id, input) do
    fields =
      input
      |> Enum.map(fn {key, value} -> "#{key}: #{graphql_literal(value)}" end)
      |> Enum.join("\n        ")

    """
    mutation {
      upsertResumeProfile(workspaceId: "#{workspace_id}", input: { #{fields} }) {
        result { id fullName contactEmail weeklyHours skills fileName fileSize uploadedAt }
        errors { message code fields }
      }
    }
    """
  end

  defp apply_mutation(workspace_id, cohort_id, input) do
    fields =
      input
      |> Enum.map(fn {key, value} -> "#{key}: #{graphql_literal(value)}" end)
      |> Enum.join("\n          ")

    """
    mutation {
      createVolunteerApplication(workspaceId: "#{workspace_id}", input: {
        cohortId: "#{cohort_id}"
        #{fields}
      }) {
        result { id userId cohortId position city heardAboutUs hasInternalReferrer status }
        errors { message code fields }
      }
    }
    """
  end

  defp list_query(workspace_id, opts \\ []) do
    args =
      opts
      |> Enum.map(fn
        {:cohort_id, value} -> "cohortId: \"#{value}\""
        {:position, value} -> "position: \"#{value}\""
        {:first, value} -> "first: #{value}"
        {:after, value} -> "after: \"#{value}\""
      end)
      |> Enum.join(", ")

    """
    query {
      listVolunteerApplications(workspaceId: "#{workspace_id}"#{if args == "", do: "", else: ", " <> args}) {
        id userId cohortId position status rejectionReason
      }
    }
    """
  end

  defp advance_mutation(stage, workspace_id, application_id) do
    field =
      case stage do
        :interview -> "advanceVolunteerApplicationToInterview"
        :training -> "advanceVolunteerApplicationToTraining"
      end

    """
    mutation {
      #{field}(workspaceId: "#{workspace_id}", id: "#{application_id}") {
        result { id status }
        errors { message code fields }
      }
    }
    """
  end

  defp assign_mutation(workspace_id, application_id, event_id, note) do
    args =
      [
        event_id && "assignedEventId: \"#{event_id}\"",
        note && "assignmentNote: \"#{note}\""
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    """
    mutation {
      assignVolunteerApplication(workspaceId: "#{workspace_id}", id: "#{application_id}"#{if args == "", do: "", else: ", " <> args}) {
        result { id status assignedEventId assignmentNote assignedAt }
        errors { message code fields }
      }
    }
    """
  end

  defp reject_mutation(workspace_id, application_id, reason) do
    """
    mutation {
      rejectVolunteerApplication(workspaceId: "#{workspace_id}", id: "#{application_id}"#{if reason, do: ", reason: #{graphql_literal(reason)}", else: ""}) {
        result { id status rejectionReason }
        errors { message code fields }
      }
    }
    """
  end

  defp cancel_mutation(workspace_id, application_id) do
    """
    mutation {
      cancelVolunteerApplication(workspaceId: "#{workspace_id}", id: "#{application_id}") {
        result { id status rejectionReason }
        errors { message code fields }
      }
    }
    """
  end

  defp create_cohort_mutation(workspace_id, name) do
    deadline = DateTime.add(DateTime.utc_now(), 14, :day) |> DateTime.to_iso8601()

    """
    mutation {
      createRecruitmentCohort(workspaceId: "#{workspace_id}", input: {
        name: "#{name}"
        applyDeadlineAt: "#{deadline}"
      }) {
        result { id name status applyDeadlineAt }
        errors { message code fields }
      }
    }
    """
  end

  defp update_cohort_mutation(workspace_id, cohort_id, name) do
    """
    mutation {
      updateRecruitmentCohort(workspaceId: "#{workspace_id}", id: "#{cohort_id}", input: { name: "#{name}" }) {
        result { id name status }
        errors { message code fields }
      }
    }
    """
  end

  defp open_mutation(workspace_id, cohort_id) do
    """
    mutation {
      openRecruitmentCohort(workspaceId: "#{workspace_id}", id: "#{cohort_id}") {
        result { id name status }
        errors { message code fields }
      }
    }
    """
  end

  defp close_mutation(workspace_id, cohort_id) do
    """
    mutation {
      closeRecruitmentCohort(workspaceId: "#{workspace_id}", id: "#{cohort_id}") {
        result { id name status }
        errors { message code fields }
      }
    }
    """
  end

  defp detail_query(workspace_id, application_id) do
    """
    query {
      volunteerApplicationDetail(workspaceId: "#{workspace_id}", id: "#{application_id}") {
        application { id userId status position }
        resumeProfile { id fullName contactEmail weeklyHours skills fileName fileSize uploadedAt }
      }
    }
    """
  end

  defp graphql_literal(value) when is_binary(value), do: "\"#{value}\""
  defp graphql_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp graphql_literal(value) when is_boolean(value), do: to_string(value)

  defp graphql_literal(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &graphql_literal/1) <> "]"

  # --- 布置 helpers（Ash 层；被测对象是 GraphQL 接线，不是这两条域路径） --------

  defp create_cohort(workspace, actor, attrs) do
    attrs =
      Map.merge(
        %{name: "第 1 批", apply_deadline_at: DateTime.add(DateTime.utc_now(), 14, :day)},
        attrs
      )

    {:ok, cohort} =
      RecruitmentCohort
      |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
      |> Ash.create(tenant: workspace.id, actor: actor)

    cohort
  end

  defp open_cohort(workspace, actor, cohort) do
    cohort
    |> Ash.Changeset.for_update(:open, %{}, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp close_cohort(workspace, actor, cohort) do
    cohort
    |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: actor)
    |> Ash.update(tenant: workspace.id, actor: actor)
  end

  defp open_cohort!(workspace, actor) do
    cohort = create_cohort(workspace, actor, %{})
    {:ok, opened} = open_cohort(workspace, actor, cohort)
    opened
  end

  defp apply_for(workspace, actor, cohort, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          cohort_id: cohort.id,
          position: :event_moderator,
          city: "上海",
          heard_about_us: "公众号",
          has_internal_referrer: false,
          message: "希望参与"
        },
        attrs
      )

    {:ok, application} =
      VolunteerApplication
      |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
      |> Ash.create(tenant: workspace.id, actor: actor)

    application
  end

  defp upsert_resume(workspace, actor, attrs) do
    {:ok, profile} =
      ResumeProfile
      |> Ash.Changeset.for_create(:upsert, attrs, tenant: workspace.id)
      |> Ash.create(tenant: workspace.id, actor: actor)

    profile
  end
end
