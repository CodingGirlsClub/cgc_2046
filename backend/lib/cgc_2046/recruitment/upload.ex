defmodule Cgc2046.Recruitment.Upload do
  @moduledoc """
  简历文件上传管道（R9；KTD3 最小上传管道单入口）。

  base64-over-JSON 走既有 GraphQL 接线（零新依赖；multipart 需路由层改造，不在
  本期）：**单一入口** = `uploadResumeFile` mutation → `store/3`，校验后把文件内容
  写入 `resume_profiles.file_data`（bytea），元数据（文件名 / MIME / 大小 / 上传
  时间）同表一行。

  校验（三者一致才收，任一不符即 `resume_profile_file_type_invalid`）：

  - **扩展名**：`.pdf` / `.doc` / `.docx`（大小写不敏感）；
  - **MIME**：与扩展名同族的声明类型（`application/pdf` / `application/msword` /
    `application/vnd.openxmlformats-officedocument.wordprocessingml.document`）；
  - **魔数**：`%PDF-` / OLE2 复合文档头 / OOXML 容器（ZIP 魔数 + `word/` 部件）。

  大小上限为**原始文件 ≤5MB**（KTD3）：base64 约膨胀 33%（≈6.7MB 请求体），仍在
  endpoint 全局 8MB 请求体闸门（`CachingBodyReader` / `Plug.Parsers`）内——该闸门
  是公开端点唯一总量防线，不随本管道抬高。文件大小由实际解码字节数计算（不信客户端
  自报），上传时间由服务端落。

  调用顺序：**先建档再上传**（档案 = 姓名 + 联系邮箱 + 简历文件 + 投入 + 技能，
  姓名/联系邮箱为必填，R9）——档案不存在时上传不代建半成品行，返回
  `resume_profile_not_found`，由前端先调 `upsertResumeProfile`（一人一档、幂等）
  再上传；二次上传覆盖旧文件（KTD3 更新语义），目标恒为 actor 自己的档案
  （写入 policy 仅本人，PIPL 边界 KTD2）。

  不做应用层加密（依赖数据库访问控制 + KTD2 policy 兜底）；保留期限策略见 OQ4。
  """

  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Recruitment.ResumeProfile

  require Ash.Query

  # 原始文件上限（KTD3）：5MB。base64-over-JSON 后约 6.7MB，在 endpoint 8MB
  # 闸门内；闸门本身不得抬高。
  @max_file_size 5 * 1024 * 1024

  @pdf_types ~w(application/pdf)
  @doc_types ~w(application/msword)

  @docx_types ~w(application/vnd.openxmlformats-officedocument.wordprocessingml.document)

  @pdf_magic "%PDF-"
  @ole2_magic <<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1>>
  @zip_magic <<0x50, 0x4B, 0x03, 0x04>>

  # OOXML（docx）是 ZIP 容器：除 ZIP 魔数外还要求出现 `word/` 部件目录
  # （`word/document.xml`），否则普通 ZIP（.zip/.jar 改名）也能过闸。
  @docx_marker "word/"

  @doc """
  校验并入档：文件名 / 声明 MIME / 文件内容（base64）。

  `actor` 必须已登录（GraphQL 入口 `with_actor` 已挡匿名）；返回
  `{:ok, profile}` 或 `{:error, BusinessError.t() | Ash.Error.t()}`。
  """
  @spec store(term(), map(), map()) :: {:ok, ResumeProfile.t()} | {:error, term()}
  def store(workspace_id, actor, %{file_name: _, content_type: _, content_base64: _} = input) do
    with {:ok, file} <- decode_and_validate(input),
         {:ok, profile} <- fetch_profile(workspace_id, actor) do
      write_file(profile, workspace_id, actor, file)
    end
  end

  # ── 校验（纯函数，无 IO） ───────────────────────────────────────────────────

  defp decode_and_validate(%{file_name: name, content_type: content_type} = input) do
    with {:ok, content} <- decode(input[:content_base64]),
         :ok <- check_size(content),
         :ok <- check_type(name, content_type, content) do
      {:ok, %{file_name: name, file_content_type: content_type, content: content}}
    end
  end

  defp decode(encoded) when is_binary(encoded) do
    case Base.decode64(encoded, ignore: :whitespace) do
      {:ok, ""} -> {:error, content_invalid("resume file content is empty")}
      {:ok, content} -> {:ok, content}
      :error -> {:error, content_invalid("resume file content is not valid base64")}
    end
  end

  defp decode(_), do: {:error, content_invalid("resume file content is required")}

  defp check_size(content) when byte_size(content) > @max_file_size do
    {:error,
     BusinessError.exception(
       message: "resume file exceeds the 5MB limit",
       code: "resume_profile_file_too_large",
       fields: [:content_base64]
     )}
  end

  defp check_size(_content), do: :ok

  defp check_type(file_name, content_type, content) do
    with {:ok, family} <- family_of(file_name),
         :ok <- check_content_type(family, content_type),
         :ok <- check_magic(family, content) do
      :ok
    end
  end

  defp family_of(file_name) when is_binary(file_name) do
    case file_name |> Path.extname() |> String.downcase() do
      ".pdf" -> {:ok, :pdf}
      ".doc" -> {:ok, :doc}
      ".docx" -> {:ok, :docx}
      _ -> {:error, type_invalid("resume file must be .pdf, .doc or .docx")}
    end
  end

  defp family_of(_file_name), do: {:error, type_invalid("resume file name is required")}

  defp check_content_type(family, content_type) do
    declared = content_type |> to_string() |> String.trim() |> String.downcase()

    if declared in expected_content_types(family) do
      :ok
    else
      {:error, type_invalid("resume file content type does not match its extension")}
    end
  end

  defp expected_content_types(:pdf), do: @pdf_types
  defp expected_content_types(:doc), do: @doc_types
  defp expected_content_types(:docx), do: @docx_types

  defp check_magic(:pdf, <<@pdf_magic, _::binary>>), do: :ok
  defp check_magic(:doc, <<@ole2_magic, _::binary>>), do: :ok

  defp check_magic(:docx, <<@zip_magic, _::binary>> = content) do
    if :binary.match(content, @docx_marker) == :nomatch do
      {:error, type_invalid("resume file content does not match its extension")}
    else
      :ok
    end
  end

  defp check_magic(_family, _content),
    do: {:error, type_invalid("resume file content does not match its extension")}

  defp type_invalid(message) do
    BusinessError.exception(
      message: message,
      code: "resume_profile_file_type_invalid",
      fields: [:file_name]
    )
  end

  defp content_invalid(message) do
    BusinessError.exception(
      message: message,
      code: "resume_profile_file_content_invalid",
      fields: [:content_base64]
    )
  end

  # ── 落库（tenant 内定位 actor 自己的档案 → 授权更新） ───────────────────────

  defp fetch_profile(workspace_id, actor) do
    ResumeProfile
    |> Ash.Query.for_read(:read)
    # 定位行只为发起 update（新 blob 由 force_change 覆盖，不读旧值），不拖 file_data
    |> Ash.Query.deselect(:file_data)
    |> Ash.Query.filter(user_id == ^actor.id)
    |> Ash.read_one(tenant: workspace_id, actor: actor)
    |> case do
      {:ok, %ResumeProfile{} = profile} ->
        {:ok, profile}

      {:ok, nil} ->
        {:error,
         BusinessError.exception(
           message: "resume profile not found; complete the profile before uploading the file",
           code: "resume_profile_not_found",
           fields: [:file_name]
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp write_file(profile, workspace_id, actor, file) do
    # 大小 = 实际解码字节数（不信客户端自报）；上传时间由 action 落
    attrs = %{
      file_name: file.file_name,
      file_content_type: file.file_content_type,
      file_size: byte_size(file.content)
    }

    profile
    |> Ash.Changeset.for_update(:upload_file, attrs, tenant: workspace_id, actor: actor)
    # 内容本体不走 accept 面（file_data 对客户端结构上不可达）：单入口校验后
    # force_change 注入（KTD3）。
    |> Ash.Changeset.force_change_attribute(:file_data, file.content)
    |> Ash.update(tenant: workspace_id, actor: actor)
  end
end
