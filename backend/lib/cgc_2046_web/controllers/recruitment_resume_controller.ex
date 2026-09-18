defmodule Cgc2046Web.RecruitmentResumeController do
  @moduledoc """
  简历文件下载（R13/U8；KTD3 最小上传管道的唯一读出口）。

  授权（KTD2 边界）：本人 ∪ 所属台 Owner/Admin ∪ platform_admin——与
  `resume_profile` 的读 policy 同口径，但**文件字节不经 GraphQL**（`file_data`
  是敏感列，任何投影都不含它），只能经本端点以固定安全响应头送达：

  - `Content-Type`：白名单映射（PDF/Word 三种），未知一律 `application/octet-stream`
    ——绝不回显客户端声明值（U2 已按魔数校验过，但读面不依赖该信任）；
  - `Content-Disposition: attachment`：强制下载而非内联渲染；
  - `X-Content-Type-Options: nosniff`：禁浏览器嗅探。

  这样「申请人控制的文件」不可能在审核方浏览器里被当作活动内容执行。
  """

  use Cgc2046Web, :controller


  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Recruitment.ResumeProfile

  # 白名单：只放行 PDF/Word 三种安全类型；其余（含空/未知）一律 octet-stream
  @safe_content_types %{
    "application/pdf" => "application/pdf",
    "application/msword" => "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" =>
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  }

  def show(conn, %{"profile_id" => profile_id}) do
    actor = conn.assigns[:current_user]

    with {:ok, actor} <- require_actor(actor),
         {:ok, profile} <- fetch(profile_id),
         :ok <- authorize(actor, profile),
         {:ok, file_data} <- require_file(profile) do
      send_resume_file(conn, profile, file_data)
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
    end
  end

  defp require_actor(%{} = actor), do: {:ok, actor}
  defp require_actor(_), do: {:error, :unauthorized}

  defp fetch(profile_id) do
    case Ash.get(ResumeProfile, profile_id, authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, profile} -> {:ok, profile}
      {:error, _} -> {:error, :not_found}
    end
  end

  # 与 resume_profile 读 policy 同口径：本人 ∪ 台 Owner/Admin ∪ platform_admin
  defp authorize(actor, profile) do
    cond do
      actor.id == profile.user_id -> :ok
      Map.get(actor, :is_platform_admin) == true -> :ok
      Rbac.manage?(actor, profile.workspace_id) -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp require_file(%{file_data: file_data}) when is_binary(file_data) and byte_size(file_data) > 0,
    do: {:ok, file_data}

  defp require_file(_), do: {:error, :not_found}

  defp send_resume_file(conn, profile, file_data) do
    conn
    # charset=nil：二进制文件不带 charset（带上是语义错误，且可能误导浏览器）
    |> put_resp_content_type(safe_content_type(profile.file_content_type), nil)
    |> put_resp_header("content-disposition", content_disposition(profile.file_name))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, file_data)
  end

  defp safe_content_type(content_type) when is_binary(content_type) do
    Map.get(@safe_content_types, String.downcase(content_type), "application/octet-stream")
  end

  defp safe_content_type(_), do: "application/octet-stream"

  # filename 只取 basename 并剔除引号/控制字符（防 header 注入），空则回落
  defp content_disposition(file_name) do
    safe =
      (file_name || "resume")
      |> Path.basename()
      |> String.replace(~r/["\\\r\n\t]/, "_")
      |> String.slice(0, 120)

    safe = if safe == "", do: "resume", else: safe
    "attachment; filename=\"#{safe}\""
  end
end
