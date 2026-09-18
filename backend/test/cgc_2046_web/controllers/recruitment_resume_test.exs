defmodule Cgc2046Web.RecruitmentResumeTest do
  @moduledoc """
  简历文件下载端点验收（R13/U8；KTD2 授权边界 + 安全响应头）。

  文件字节不经 GraphQL（敏感列），唯一读出口是本端点：
  本人 ∪ 所属台 Owner/Admin ∪ platform_admin；固定安全 Content-Type 白名单 +
  `Content-Disposition: attachment` + `X-Content-Type-Options: nosniff`。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Recruitment.ResumeProfile

  @pdf_bytes "%PDF-1.4\n%fake-resume-bytes\n"

  setup do
    creator = Fixtures.platform_admin("resume-creator")
    workspace = Fixtures.create_workspace(creator)

    owner = Fixtures.register_user("resume-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    # 同台普通成员（volunteer 角色）：非管理角色，不应能读他人档案
    member = Fixtures.register_user("resume-member")
    Fixtures.add_member(workspace, member, [:volunteer])

    # create_workspace 需 platform_admin（RBAC）：他台 fixture 同款
    other_creator = Fixtures.platform_admin("resume-other-creator")
    other_workspace = Fixtures.create_workspace(other_creator)
    other_owner = Fixtures.register_user("resume-other-owner")
    Fixtures.add_member(other_workspace, other_owner, [:owner])

    applicant = Fixtures.register_user("resume-applicant")

    profile =
      create_profile(workspace, applicant, %{
        full_name: "小程",
        contact_email: "xiao@example.com",
        file_name: "resume.pdf",
        file_content_type: "application/pdf",
        file_size: byte_size(@pdf_bytes),
        file_data: @pdf_bytes
      })

    %{
      workspace: workspace,
      other_workspace: other_workspace,
      owner: owner,
      member: member,
      other_owner: other_owner,
      applicant: applicant,
      profile: profile,
      creator: creator
    }
  end

  test "本人下载 → 200 + 安全头 + 字节一致", ctx do
    conn = download(ctx.profile.id, ctx.applicant)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/pdf"]
    assert get_resp_header(conn, "content-disposition") == ["attachment; filename=\"resume.pdf\""]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert conn.resp_body == @pdf_bytes
  end

  test "所属台 Owner 下载 → 200（审核方）", ctx do
    conn = download(ctx.profile.id, ctx.owner)
    assert conn.status == 200
    assert conn.resp_body == @pdf_bytes
  end

  test "platform_admin 下载 → 200（穿透）", ctx do
    conn = download(ctx.profile.id, ctx.creator)
    assert conn.status == 200
  end

  test "同台普通成员 → 403（PIPL 边界：仅审核方可读）", ctx do
    conn = download(ctx.profile.id, ctx.member)
    assert conn.status == 403
  end

  test "他台 Owner → 403", ctx do
    conn = download(ctx.profile.id, ctx.other_owner)
    assert conn.status == 403
  end

  test "匿名 → 401", %{profile: profile} do
    conn = get(build_conn(), "/api/recruitment/resumes/#{profile.id}")
    assert conn.status == 401
  end

  test "不存在的档案 → 404", ctx do
    conn = download(Ash.UUID.generate(), ctx.owner)
    assert conn.status == 404
  end

  test "已建档但未上传文件 → 404", ctx do
    no_file_user = Fixtures.register_user("resume-no-file")

    profile =
      create_profile(ctx.workspace, no_file_user, %{
        full_name: "无文件",
        contact_email: "nofile@example.com"
      })

    conn = download(profile.id, ctx.owner)
    assert conn.status == 404
  end

  test "未知/伪造 content_type → 回退 octet-stream（不回显客户端声明）", ctx do
    fake_user = Fixtures.register_user("resume-fake")

    profile =
      create_profile(ctx.workspace, fake_user, %{
        full_name: "伪装",
        contact_email: "fake@example.com",
        file_name: "evil.html",
        file_content_type: "text/html",
        file_size: byte_size("<script/>"),
        file_data: "<script/>"
      })

    conn = download(profile.id, ctx.owner)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  # --- helpers ----------------------------------------------------------------

  defp download(profile_id, user) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{sign_in_token(user)}")
    |> get("/api/recruitment/resumes/#{profile_id}")
  end

  defp create_profile(workspace, user, attrs) do
    changeset =
      ResumeProfile
      |> Ash.Changeset.for_create(:upsert, %{
        full_name: attrs.full_name,
        contact_email: attrs.contact_email
      })

    changeset =
      if attrs[:file_data] do
        changeset
        |> Ash.Changeset.force_change_attribute(:file_name, attrs.file_name)
        |> Ash.Changeset.force_change_attribute(:file_content_type, attrs.file_content_type)
        |> Ash.Changeset.force_change_attribute(:file_size, attrs.file_size)
        |> Ash.Changeset.force_change_attribute(:file_data, attrs.file_data)
        |> Ash.Changeset.force_change_attribute(:uploaded_at, DateTime.utc_now())
      else
        changeset
      end

    # user_id 由 create action 的 before_action 强制为 actor；此处以 applicant 为 actor
    {:ok, profile} = Ash.create(changeset, tenant: workspace.id, actor: user, authorize?: false)
    profile
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
end
