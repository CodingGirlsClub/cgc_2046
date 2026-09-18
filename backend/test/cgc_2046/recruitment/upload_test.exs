defmodule Cgc2046.Recruitment.UploadTest do
  @moduledoc """
  简历上传管道数据面（R9/KTD3；Covers AE5 的上传/覆盖侧）。

  - 类型守卫：扩展名 / MIME / 魔数**三者一致**才收；改名伪装（exe→.pdf、
    HTML→.doc、zip→.docx）在魔数层被拒；
  - 大小上限：原始文件 ≤5MB（>5MB 拒；恰好 5MB 通过——base64 后约 6.7MB，
    在 endpoint 8MB 请求体闸门内，该闸门不抬高）；
  - 落库：内容 bytea 往返字节一致，元数据（文件名 / MIME / 大小 / 上传时间）
    同表一行；
  - 覆盖语义：二次上传替换旧文件（KTD3 更新语义，AE5 更新侧）；
  - 调用顺序：上传前档案须已存在（`upsertResumeProfile` 建档）——未建档上传 →
    `resume_profile_not_found`；写面 policy 兜底（他人 / 匿名 → Forbidden）。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Recruitment.{ResumeProfile, Upload}

  # KTD3：原始文件上限 5MB；base64 约 +33% ⇒ 请求体约 6.7MB < endpoint 8MB 闸门
  @five_mb 5 * 1024 * 1024
  @endpoint_body_gate 8_000_000
  @docx_type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    creator = Fixtures.platform_admin("upload-creator")
    workspace = Fixtures.create_workspace(creator)

    owner = Fixtures.register_user("upload-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    applicant = Fixtures.register_user("upload-applicant")
    Fixtures.add_member(workspace, applicant, [:volunteer])

    other = Fixtures.register_user("upload-other")
    Fixtures.add_member(workspace, other, [:volunteer])

    %{creator: creator, workspace: workspace, owner: owner, applicant: applicant, other: other}
  end

  describe "类型守卫（扩展名 / MIME / 魔数三者一致）" do
    test "PDF 上传成功：元数据落库 + 内容字节往返一致", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      profile = upsert(ws, applicant)
      content = pdf()

      assert {:ok, uploaded} =
               upload(ws, applicant, "张三-简历.pdf", content, "application/pdf")

      # 同一行（一人一档，不新建）
      assert uploaded.id == profile.id
      assert uploaded.file_name == "张三-简历.pdf"
      assert uploaded.file_content_type == "application/pdf"
      assert uploaded.file_size == byte_size(content)
      assert %DateTime{} = uploaded.uploaded_at

      # 元数据与内容都在库里；内容逐字节一致（bytea 往返）
      stored = stored(ws, profile.id)
      assert stored.file_name == "张三-简历.pdf"
      assert stored.file_content_type == "application/pdf"
      assert stored.file_size == byte_size(content)
      assert stored.uploaded_at == uploaded.uploaded_at
      assert stored.file_data == content

      # 真落 Postgres（不经 Ash 属性缓存的裸读，字节一致）
      assert %{rows: [[raw]]} =
               Cgc2046.Repo.query!("SELECT file_data FROM resume_profiles WHERE id = $1", [
                 Ecto.UUID.dump!(profile.id)
               ])

      assert raw == content

      # 档案仍一条
      assert [%{id: id}] = all_profiles(ws)
      assert id == profile.id
    end

    test "Word 两种容器均可：.doc（OLE2）与 .docx（OOXML/ZIP）", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      profile = upsert(ws, applicant)
      doc = ole2()

      assert {:ok, uploaded} = upload(ws, applicant, "简历.doc", doc, "application/msword")
      assert uploaded.file_content_type == "application/msword"
      assert stored(ws, profile.id).file_data == doc

      docx = docx()
      docx_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

      assert {:ok, replaced} = upload(ws, applicant, "简历.docx", docx, docx_type)
      assert replaced.id == profile.id
      assert replaced.file_content_type == docx_type
      assert stored(ws, profile.id).file_data == docx
    end

    test "非 PDF/Word 扩展名 → resume_profile_file_type_invalid，不入库", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      profile = upsert(ws, applicant)

      for {name, content, type} <- [
            {"photo.png", png(), "image/png"},
            {"virus.exe", exe(), "application/x-msdownload"},
            {"README", "hello", "text/plain"},
            {"resume.txt", "hello", "text/plain"}
          ] do
        assert {:error, %BusinessError{code: "resume_profile_file_type_invalid"}} =
                 upload(ws, applicant, name, content, type),
               "expected type rejection for #{name}"
      end

      assert stored(ws, profile.id).file_data == nil
      assert stored(ws, profile.id).file_name == nil
    end

    test "改名伪装（.exe→.pdf、HTML→.doc、zip→.docx）→ 魔数校验拒绝", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      profile = upsert(ws, applicant)

      disguised = [
        # 扩展名与 MIME 都谎报 PDF，文件头是 Windows 可执行
        {"fake.pdf", exe(), "application/pdf"},
        # 扩展名与 MIME 都谎报 Word，内容是 HTML
        {"fake.doc", "<html><body>not a resume</body></html>", "application/msword"},
        # 扩展名与 MIME 都谎报 docx，内容是普通 ZIP（无 word/ 部件）
        {"fake.docx", plain_zip(), @docx_type}
      ]

      for {name, content, type} <- disguised do
        assert {:error, %BusinessError{code: "resume_profile_file_type_invalid"}} =
                 upload(ws, applicant, name, content, type),
               "expected magic rejection for #{name}"
      end

      assert stored(ws, profile.id).file_data == nil
    end

    test "MIME 与扩展名不一致（真 PDF 标 application/msword）→ 拒", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      profile = upsert(ws, applicant)

      assert {:error, %BusinessError{code: "resume_profile_file_type_invalid"}} =
               upload(ws, applicant, "resume.pdf", pdf(), "application/msword")

      # MIME 与内容不一致（ole2 内容标 pdf）同拒
      assert {:error, %BusinessError{code: "resume_profile_file_type_invalid"}} =
               upload(ws, applicant, "resume.doc", ole2(), "application/pdf")

      assert stored(ws, profile.id).file_data == nil
    end

    test "base64 非法 / 空文件 → resume_profile_file_content_invalid", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      profile = upsert(ws, applicant)

      for encoded <- ["", "%%not-base64%%", "  "] do
        assert {:error, %BusinessError{code: "resume_profile_file_content_invalid"}} =
                 Upload.store(ws.id, applicant, %{
                   file_name: "resume.pdf",
                   content_type: "application/pdf",
                   content_base64: encoded
                 }),
               "expected content rejection for #{inspect(encoded)}"
      end

      assert stored(ws, profile.id).file_data == nil
    end
  end

  describe "大小上限（KTD3：原始文件 ≤5MB）" do
    test "超过 5MB → resume_profile_file_too_large，不入库", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      profile = upsert(ws, applicant)
      oversized = pdf(String.duplicate("A", @five_mb))

      assert byte_size(oversized) > @five_mb

      assert {:error, %BusinessError{code: "resume_profile_file_too_large"}} =
               upload(ws, applicant, "resume.pdf", oversized, "application/pdf")

      assert stored(ws, profile.id).file_data == nil
    end

    test "恰好 5MB 通过（base64 请求体仍在 endpoint 8MB 闸门内）", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      profile = upsert(ws, applicant)
      boundary = pdf(String.duplicate("A", @five_mb - byte_size(pdf())))

      assert byte_size(boundary) == @five_mb

      encoded = Base.encode64(boundary)

      assert byte_size(encoded) > @five_mb
      assert byte_size(encoded) < @endpoint_body_gate

      assert {:ok, uploaded} = upload(ws, applicant, "resume.pdf", boundary, "application/pdf")
      assert uploaded.file_size == @five_mb
      assert stored(ws, profile.id).file_data == boundary
    end
  end

  describe "更新语义（KTD3 二次上传覆盖；Covers AE5 更新侧）" do
    test "二次上传替换旧文件，档案仍一条", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      profile = upsert(ws, applicant)
      first = pdf()
      second = ole2()

      assert {:ok, _} = upload(ws, applicant, "旧简历.pdf", first, "application/pdf")
      assert {:ok, replaced} = upload(ws, applicant, "新简历.doc", second, "application/msword")

      assert replaced.id == profile.id
      assert replaced.file_name == "新简历.doc"
      assert replaced.file_content_type == "application/msword"
      assert replaced.file_size == byte_size(second)

      stored = stored(ws, profile.id)
      assert stored.file_data == second
      refute stored.file_data == first

      # 一人一档：覆盖而非新增
      assert [%{id: id}] = all_profiles(ws)
      assert id == profile.id
    end
  end

  describe "调用顺序与授权边界" do
    test "未建档上传 → resume_profile_not_found（先 upsert 建档再上传）", ctx do
      %{workspace: ws, applicant: applicant} = ctx

      assert {:error, %BusinessError{code: "resume_profile_not_found"}} =
               upload(ws, applicant, "resume.pdf", pdf(), "application/pdf")

      # 建档后同一调用即成功
      profile = upsert(ws, applicant)
      assert {:ok, uploaded} = upload(ws, applicant, "resume.pdf", pdf(), "application/pdf")
      assert uploaded.id == profile.id
    end

    test "上传目标恒为 actor 自己的档案（他人档案不可达）", ctx do
      %{workspace: ws, applicant: applicant, other: other} = ctx

      mine = upsert(ws, applicant)

      # other 未建档 → 拒；申请人档案的文件态不受影响
      assert {:error, %BusinessError{code: "resume_profile_not_found"}} =
               upload(ws, other, "别人的简历.pdf", pdf(), "application/pdf")

      assert stored(ws, mine.id).file_data == nil

      # other 建档后上传 → 落在自己的档案上，与申请人档案互不影响
      theirs = upsert(ws, other)
      assert {:ok, theirs_uploaded} = upload(ws, other, "李四.pdf", pdf(), "application/pdf")
      assert theirs_uploaded.id == theirs.id
      assert stored(ws, mine.id).file_data == nil
      assert stored(ws, theirs.id).file_data != nil
    end

    test "写面 policy：他人 / 匿名调用 upload_file → Forbidden", ctx do
      %{workspace: ws, applicant: applicant, other: other, owner: owner} = ctx

      profile = upsert(ws, applicant)

      changeset =
        Ash.Changeset.for_update(profile, :upload_file, %{
          file_name: "篡改.pdf",
          file_content_type: "application/pdf",
          file_size: 8
        })

      for actor <- [other, owner, nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Ash.update(changeset, tenant: ws.id, actor: actor),
               "expected Forbidden for actor #{inspect(actor && actor.id)}"
      end

      assert stored(ws, profile.id).file_data == nil
    end

    test "跨台 workspaceId → resume_profile_not_found（tenant 隔离）", ctx do
      %{workspace: ws, creator: creator, applicant: applicant} = ctx

      profile = upsert(ws, applicant)
      other_ws = Fixtures.create_workspace(creator, %{slug: "upload-other-ws"})

      assert {:error, %BusinessError{code: "resume_profile_not_found"}} =
               upload(other_ws, applicant, "resume.pdf", pdf(), "application/pdf")

      assert stored(ws, profile.id).file_data == nil
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp upload(workspace, actor, file_name, content, content_type) do
    Upload.store(workspace.id, actor, %{
      file_name: file_name,
      content_type: content_type,
      content_base64: Base.encode64(content)
    })
  end

  defp upsert(workspace, actor) do
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

  # 授权读（不走 policy：断言落库事实本身）
  defp stored(workspace, id) do
    Ash.get!(ResumeProfile, id, tenant: workspace.id, authorize?: false)
  end

  defp all_profiles(workspace) do
    Ash.read!(ResumeProfile, tenant: workspace.id, authorize?: false)
  end

  # 最小合法 PDF（魔数 `%PDF-` + 尾部标记）
  defp pdf(extra \\ "") do
    "%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n" <>
      extra
  end

  # PNG 魔数（非 PDF/Word 的合法二进制对照组）
  defp png, do: <<0x89, "PNG\r\n", 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">> <> :binary.copy(<<0>>, 16)

  # Windows 可执行魔数（改名伪装对照组）
  defp exe, do: "MZ" <> :binary.copy(<<0>>, 64)

  # OLE2 复合文档魔数（.doc 容器）
  defp ole2 do
    <<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1>> <>
      :binary.copy(<<0>>, 32) <> "<html>Word 97 二进制流</html>"
  end

  # OOXML（.docx）容器：ZIP + word/ 部件（`[:memory]`：只在内存造包，不落盘）
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

  # 普通 ZIP（无 word/ 部件）：zip→.docx 改名伪装对照组
  defp plain_zip do
    {:ok, {_name, binary}} =
      :zip.create(~c"archive.zip", [{~c"readme.txt", "not a docx"}], [:memory])

    binary
  end
end
