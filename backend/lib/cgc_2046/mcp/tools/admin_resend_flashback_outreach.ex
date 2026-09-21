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

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Flashback.{AlumniProjection, Outreach.Dispatch}
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  require Logger

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
  确认后真正执行（Confirmation 分派）：入队 + 治理留痕。校验在第一段已过；
  竞态窗口内状态变化的兜底由 `resend_for_person/3` 内同款拒绝表承接。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    channel =
      case Dispatch.parse_channel(params["channel"] || "all") do
        {:ok, channel} -> channel
        _ -> :all
      end

    with :ok <- Dispatch.ensure_channel_ready(channel),
         {:ok, %{queued: queued, skipped: skipped, batch: batch}} <-
           Dispatch.resend_for_person(params["person_id"], params["template"], channel) do
      log_admin_action(actor, params, channel, batch, queued, skipped)

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

  defp log_admin_action(actor, params, channel, batch, queued, skipped) do
    # 审计失败不阻塞已入队的发送（wrapper 审计哲学同款），error 日志留痕。
    AdminActionLog.log(%{
      actor_id: actor && Map.get(actor, :id),
      action: :flashback_outreach_resend,
      target_type: :flashback_person,
      target_id: params["person_id"],
      result: :success,
      metadata: %{
        template: params["template"],
        channel: to_string(channel),
        batch: batch,
        queued: queued,
        skipped: skipped
      }
    })
    |> case do
      {:ok, _} ->
        :ok

      error ->
        Logger.error("[flashback_outreach_resend] admin action log failed: #{inspect(error)}")
        :ok
    end
  end

  defp dispatch_error_message(%{code: code, message: message}), do: "#{code}: #{message}"
  defp dispatch_error_message(other), do: inspect(other)
end
