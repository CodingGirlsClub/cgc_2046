defmodule Cgc2046.Mcp.Tools.AdminResendFlashbackOutreach do
  @moduledoc """
  闪念间单人重发（R2/R5，platform_admin，两段式确认）：对未认领、未退订、
  未删除且可达的校友重新入队（`resend-*` 独立批次）。不可重发者第一段即
  带原因业务错误（不建 pending、零副作用）。不做频控（KD8）——每次重发
  都经确认流把关。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Flashback.{AlumniProjection, Outreach.Dispatch}
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    平台管理员专用：给闪念间的一位校友重发触达（person_id + template，模板目前只有 reconnect）。只对
    未认领、未退订、未删除且联系方式可达的校友生效，不满足时直接返回带原因的错误。channel：all（邮件
    优先，没有邮箱时发短信）| email | sms，默认 all。没有频率限制，每次重发都要经确认。
    走确认流：第一次调用只返回 needs_confirmation + pending_id + summary，
    用户确认后调 confirm_operation(pending_id) 才执行。
    """
  end

  schema do
    field(:person_id, :string, description: "校友档案 id", required: true)
    field(:template, :string, description: "触达模板（当前白名单: reconnect）", required: true)
    field(:channel, :string, description: "通道: all（email 优先/phone 兜底）| email | sms，默认 all")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_resend_flashback_outreach", fn _actor, _ws, params ->
        with {:ok, channel} <- parse_channel(params["channel"]),
             {:ok, person} <- Dispatch.validate_resend_for_person(params["person_id"]),
             :ok <- Dispatch.validate_template(params["template"]) do
          Confirmation.request(
            frame.assigns[:current_user],
            "admin_resend_flashback_outreach",
            params,
            summary(person, params["template"], channel)
          )
        else
          {:error, :invalid_channel} ->
            {:error, "flashback_invalid_input: channel must be one of all|email|sms"}

          {:error, reason} ->
            {:error, dispatch_error_message(reason)}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（Confirmation 分派）：入队，治理留痕由 Dispatch 单源写入。
  校验在第一段已过；
  竞态窗口内状态变化的兜底由 `resend_for_person/3` 内同款拒绝表承接。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    channel =
      case Dispatch.parse_channel(params["channel"] || "all") do
        {:ok, channel} -> channel
        _ -> :all
      end

    # 治理留痕单源在 Dispatch（R2）——与 /admin/flashback GraphQL 面共用。
    with :ok <- Dispatch.ensure_channel_ready(channel),
         {:ok, %{queued: queued, skipped: skipped, batch: batch}} <-
           Dispatch.resend_for_person(params["person_id"], params["template"], channel, actor) do
      {:ok,
       %{
         person_id: params["person_id"],
         channel: to_string(channel),
         batch: batch,
         queued: queued,
         skipped: skipped,
         note: "已入队，错峰发送进行中；送达结果见 /admin/flashback 批次历史"
       }}
    else
      {:error, reason} ->
        {:error, dispatch_error_message(reason)}
    end
  end

  defp parse_channel(nil), do: {:ok, :all}
  defp parse_channel(raw), do: Dispatch.parse_channel(raw)

  defp summary(person, template, channel) do
    channel_text =
      case channel do
        :all -> "全部（email 优先/phone 兜底）"
        :email -> "仅邮件"
        :sms -> "仅短信"
      end

    sms_note =
      if channel == :sms and not Dispatch.sms_configured?() do
        "；短信腿未配置，确认将被拒绝"
      else
        ""
      end

    "闪念间单人重发 · #{AlumniProjection.masked_name(person)} · 模板 #{template} · 通道 #{channel_text}#{sms_note}。确认后独立批次错峰发送。"
  end

  defp dispatch_error_message(%{code: code, message: message}), do: "#{code}: #{message}"
  defp dispatch_error_message(other), do: inspect(other)
end
