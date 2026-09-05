defmodule Cgc2046.Accounts.SendInvitationEmail do
  @moduledoc """
  邀请邮件通知（邀请即完整意图）。

  创建指向邮箱的邀请后异步投递：工作台 + 预授权角色 + 绑定课程 +
  接受链接（`/join?token=xxx`，web 端已支持 token 落地流程）。
  公开链接邀请（target_email 空）无收件人，不投递。

  失败语义：Task 异步、投递失败仅 log——邀请创建成功是事实，
  邮件是通知（与 SendPasswordResetEmail 同款纪律）。
  """

  require Logger
  require Ash.Query

  import Swoosh.Email

  @default_web_base_url "http://localhost:3000"
  @default_from "no-reply@example.com"
  @default_from_name "CGC 2046"
  @subject_prefix "邀请你加入"

  @doc """
  异步投递邀请邮件。公开链接邀请（无 target_email）静默跳过。
  """
  @spec deliver_async(Cgc2046.Accounts.Invitation.t(), String.t()) :: :ok
  def deliver_async(invitation, plain_token) do
    if invitation.target_email do
      _ = Task.start(fn -> deliver(invitation, plain_token) end)
    end

    :ok
  end

  defp deliver(invitation, plain_token) do
    config = Application.get_env(:cgc_2046, Cgc2046.Mailer, [])
    from = Keyword.get(config, :from, @default_from)
    from_name = Keyword.get(config, :from_name, @default_from_name)
    web_base_url = Application.get_env(:cgc_2046, :web_base_url, @default_web_base_url)
    accept_url = build_accept_url(web_base_url, plain_token)

    workspace = workspace_name(invitation.workspace_id)
    role_label = role_label(invitation.preauthorized_role_names)
    courses_block = courses_block(invitation.prep_course_ids)

    email =
      new()
      |> to(to_string(invitation.target_email))
      |> from({from_name, from})
      |> subject("#{@subject_prefix} #{workspace} · CGC 2046")
      |> text_body(
        body_text(workspace, role_label, courses_block, accept_url, invitation.expires_at)
      )

    case Cgc2046.Mailer.deliver(email) do
      {:ok, _meta} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "invitation email deliver failed (invitation #{invitation.id}): #{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.warning(
        "invitation email crashed (invitation #{invitation.id}): #{Exception.message(e)}"
      )
  end

  defp workspace_name(workspace_id) do
    case Cgc2046.Accounts.Workspace
         |> Ash.Query.filter(id == ^workspace_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> "工作台"
      {:ok, ws} -> to_string(ws.name)
      {:error, _} -> "工作台"
    end
  end

  defp role_label(nil), do: "成员"

  defp role_label(roles) do
    labels = %{
      tutor: "教研导师（tutor）",
      volunteer: "志愿者（volunteer）",
      learner: "学员（learner）",
      admin: "管理员（admin）",
      owner: "所有者（owner）"
    }

    roles
    |> Enum.map(&Map.get(labels, &1, to_string(&1)))
    |> Enum.join("、")
  end

  defp courses_block(nil), do: ""

  defp courses_block([]), do: ""

  defp courses_block(course_ids) do
    titles =
      Cgc2046.Courses.Course
      |> Ash.Query.filter(id in ^List.wrap(course_ids))
      |> Ash.read!(authorize?: false)
      |> Enum.map(&to_string(&1.title))

    if titles == [],
      do: "",
      else: "\n你将负责教研的课程：\n" <> Enum.map_join(titles, "\n", &("  · " <> &1))
  end

  defp build_accept_url(web_base_url, token) do
    String.trim_trailing(web_base_url, "/") <> "/join?token=" <> URI.encode_www_form(token)
  end

  defp body_text(workspace, role_label, courses_block, accept_url, expires_at) do
    expiry =
      if expires_at do
        "\n邀请有效期至：#{Calendar.strftime(expires_at, "%Y-%m-%d %H:%M UTC")}"
      else
        ""
      end

    """
    你被邀请加入工作台「#{workspace}」，身份：#{role_label}。#{courses_block}#{expiry}

    点击以下链接接受邀请（注册/登录后自动完成加入）：
    #{accept_url}

    如果链接无法点击，请复制到浏览器打开。此邮件由系统发送，无需回复。
    """
  end
end
