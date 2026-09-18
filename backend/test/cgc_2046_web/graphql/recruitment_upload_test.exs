defmodule Cgc2046Web.Graphql.RecruitmentUploadTest do
  @moduledoc """
  U2 验收：简历上传 mutation（`uploadResumeFile`）经 /api/graphql 端到端。

  覆盖：

  - 未登录 → unauthorized（写面仅本人，匿名到不了域层）；
  - 上传成功 → 档案回显元数据（fileName/contentType/fileSize/uploadedAt），
    内容经数据库往返（GraphQL 面恒不含 fileData——KTD3 专线）；
  - 稳定错误码经 payload errors 通道：类型不一致 / 超限 / base64 非法；
  - 恰好 5MB 通过——base64 请求体约 6.7MB，仍在 endpoint 8MB 请求体闸门内；
  - 二次上传覆盖（AE5 更新侧）：同一档案 id，文件态被替换；
  - 未建档上传 → resume_profile_not_found（先 upsertResumeProfile 建档的调用顺序）；
    跨台 workspaceId → 同码（tenant 隔离）。

  行为断言主路径在 test/cgc_2046/recruitment/upload_test.exs（Ash 层 + 校验矩阵），
  本测试只证明 GraphQL 接线、登录门控与错误协议（code 稳定，前端按 code 查文案）。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Recruitment.ResumeProfile

  require Ash.Query

  @five_mb 5 * 1024 * 1024
  @docx_type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    creator = Fixtures.platform_admin("upq-creator")
    workspace = Fixtures.create_workspace(creator)

    owner = Fixtures.register_user("upq-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    member = Fixtures.register_user("upq-member")
    Fixtures.add_member(workspace, member, [:volunteer])

    applicant = Fixtures.register_user("upq-applicant")

    %{
      creator: creator,
      workspace: workspace,
      owner: owner,
      member: member,
      member_token: sign_in_token(member),
      applicant: applicant,
      applicant_token: sign_in_token(applicant)
    }
  end

  describe "uploadResumeFile（R9/KTD3 单入口）" do
    test "未登录 → unauthorized", %{workspace: ws} do
      assert %{"errors" => [%{"code" => "unauthorized"}]} =
               build_conn()
               |> graphql_post(upload_query(), %{
                 workspaceId: ws.id,
                 input: upload_input(pdf(), "r.pdf", "application/pdf")
               })
    end

    test "上传 → 元数据回显；二次上传覆盖同一档案（AE5 更新侧）", %{
      workspace: ws,
      applicant_token: token,
      applicant: applicant
    } do
      assert %{"data" => %{"upsertResumeProfile" => %{"result" => profile}}} =
               build_conn()
               |> graphql_post(
                 upsert_mutation(),
                 %{
                   workspaceId: ws.id,
                   input: %{fullName: "张三", contactEmail: "zhang@example.com"}
                 },
                 token
               )

      first = pdf()

      assert %{"data" => %{"uploadResumeFile" => %{"result" => uploaded, "errors" => []}}} =
               build_conn()
               |> graphql_post(
                 upload_query(),
                 %{
                   workspaceId: ws.id,
                   input: upload_input(first, "张三-简历.pdf", "application/pdf")
                 },
                 token
               )

      assert uploaded["id"] == profile["id"]
      assert uploaded["fileName"] == "张三-简历.pdf"
      assert uploaded["fileContentType"] == "application/pdf"
      assert uploaded["fileSize"] == byte_size(first)
      assert is_binary(uploaded["uploadedAt"])

      # 内容经端点写入数据库（逐字节；GraphQL 面读不到 fileData）
      assert stored_file(ws, profile["id"]) == first

      # 二次上传（.docx）覆盖，档案仍一条
      docx = docx()

      assert %{"data" => %{"uploadResumeFile" => %{"result" => replaced, "errors" => []}}} =
               build_conn()
               |> graphql_post(
                 upload_query(),
                 %{workspaceId: ws.id, input: upload_input(docx, "新简历.docx", @docx_type)},
                 token
               )

      assert replaced["id"] == profile["id"]
      assert replaced["fileName"] == "新简历.docx"
      assert replaced["fileContentType"] == @docx_type
      assert replaced["fileSize"] == byte_size(docx)
      assert stored_file(ws, profile["id"]) == docx

      # 本人入口读回同一档（含文件元数据）
      assert %{"data" => %{"myResumeProfile" => mine}} =
               build_conn()
               |> graphql_post(my_resume_query(ws.id), nil, token)

      assert mine["id"] == profile["id"]
      assert mine["fileName"] == "新简历.docx"
      assert mine["fileSize"] == byte_size(docx)

      assert [%{id: id, user_id: user_id}] =
               ResumeProfile
               |> Ash.Query.filter(user_id == ^applicant.id)
               |> Ash.read!(tenant: ws.id, authorize?: false)

      assert id == profile["id"]
      assert user_id == applicant.id
    end

    test "类型 / 大小 / base64 错误 → 稳定 code 进 payload errors，不入库", %{
      workspace: ws,
      applicant_token: token,
      applicant: applicant
    } do
      profile = upsert_resume(ws, applicant)

      cases = [
        # 改名伪装（MZ → 谎报 .pdf）
        {upload_input("MZ" <> :binary.copy(<<0>>, 32), "fake.pdf", "application/pdf"),
         "resume_profile_file_type_invalid"},
        # 非 PDF/Word 扩展名
        {upload_input("hello", "resume.txt", "text/plain"), "resume_profile_file_type_invalid"},
        # MIME 与扩展名不一致
        {upload_input(pdf(), "resume.pdf", "application/msword"),
         "resume_profile_file_type_invalid"},
        # 超限（原始文件 >5MB）
        {upload_input(pdf(:binary.copy("A", @five_mb)), "resume.pdf", "application/pdf"),
         "resume_profile_file_too_large"},
        # 非 base64
        {%{fileName: "resume.pdf", contentType: "application/pdf", contentBase64: "%%nope%%"},
         "resume_profile_file_content_invalid"}
      ]

      for {input, code} <- cases do
        assert %{
                 "data" => %{
                   "uploadResumeFile" => %{"result" => nil, "errors" => [%{"code" => ^code}]}
                 }
               } =
                 build_conn()
                 |> graphql_post(upload_query(), %{workspaceId: ws.id, input: input}, token),
               "expected #{code} for #{inspect(input.fileName)}"
      end

      # 一条都没入库（拒绝路径不留半成品）
      assert stored_file(ws, profile.id) == nil
      assert stored(ws, profile.id).file_name == nil
    end

    test "恰好 5MB 通过（base64 请求体在 endpoint 8MB 闸门内）", %{
      workspace: ws,
      applicant_token: token,
      applicant: applicant
    } do
      profile = upsert_resume(ws, applicant)
      boundary = pdf(:binary.copy("A", @five_mb - byte_size(pdf())))

      assert byte_size(boundary) == @five_mb

      input = upload_input(boundary, "resume.pdf", "application/pdf")
      # 请求体（base64 + JSON 包装）与闸门的余量
      assert byte_size(input.contentBase64) < 8_000_000

      assert %{"data" => %{"uploadResumeFile" => %{"result" => uploaded, "errors" => []}}} =
               build_conn()
               |> graphql_post(upload_query(), %{workspaceId: ws.id, input: input}, token)

      assert uploaded["fileSize"] == @five_mb
      assert stored_file(ws, profile.id) == boundary
    end

    test "未建档上传 → resume_profile_not_found；跨台 workspaceId 同码（tenant 隔离）", %{
      creator: creator,
      workspace: ws,
      applicant: applicant,
      applicant_token: token
    } do
      input = upload_input(pdf(), "resume.pdf", "application/pdf")

      assert %{
               "data" => %{
                 "uploadResumeFile" => %{
                   "result" => nil,
                   "errors" => [%{"code" => "resume_profile_not_found"}]
                 }
               }
             } =
               build_conn()
               |> graphql_post(upload_query(), %{workspaceId: ws.id, input: input}, token)

      profile = upsert_resume(ws, applicant)
      other_ws = Fixtures.create_workspace(creator, %{slug: "upq-other-ws"})

      # 本台已建档，但 tenant 换成他台 → 本台档案不可达
      assert %{
               "data" => %{
                 "uploadResumeFile" => %{
                   "errors" => [%{"code" => "resume_profile_not_found"}]
                 }
               }
             } =
               build_conn()
               |> graphql_post(upload_query(), %{workspaceId: other_ws.id, input: input}, token)

      assert stored_file(ws, profile.id) == nil
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp upsert_mutation do
    """
    mutation Upsert($workspaceId: ID!, $input: UpsertResumeProfileInput!) {
      upsertResumeProfile(workspaceId: $workspaceId, input: $input) {
        result { id fullName contactEmail }
        errors { message code fields }
      }
    }
    """
  end

  defp upload_query do
    """
    mutation Upload($workspaceId: ID!, $input: UploadResumeFileInput!) {
      uploadResumeFile(workspaceId: $workspaceId, input: $input) {
        result { id fileName fileContentType fileSize uploadedAt }
        errors { message code fields }
      }
    }
    """
  end

  defp my_resume_query(workspace_id) do
    """
    query {
      myResumeProfile(workspaceId: "#{workspace_id}") {
        id fileName fileContentType fileSize uploadedAt
      }
    }
    """
  end

  defp upload_input(content, file_name, content_type) do
    %{fileName: file_name, contentType: content_type, contentBase64: Base.encode64(content)}
  end

  defp graphql_post(conn, query, variables, token \\ nil) do
    conn =
      if token do
        put_req_header(conn, "authorization", "Bearer #{token}")
      else
        conn
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
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

  defp upsert_resume(workspace, actor) do
    {:ok, profile} =
      ResumeProfile
      |> Ash.Changeset.for_create(
        :upsert,
        %{full_name: "张三", contact_email: "zhang@example.com"},
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    profile
  end

  defp stored(workspace, id) do
    Ash.get!(ResumeProfile, id, tenant: workspace.id, authorize?: false)
  end

  defp stored_file(workspace, id), do: stored(workspace, id).file_data

  # 最小合法 PDF；extra 用于撑到边界大小
  defp pdf(extra \\ "") do
    "%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n" <>
      extra
  end

  defp docx do
    {:ok, {_name, binary}} =
      :zip.create(
        ~c"resume.docx",
        [
          {~c"[Content_Types].xml", ~s(<?xml version="1.0"?><Types/>)},
          {~c"word/document.xml", ~s(<?xml version="1.0"?><w:document/>)}
        ],
        [:memory]
      )

    binary
  end
end
