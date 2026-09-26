defmodule Cgc2046.Mcp.Tools.AdminSendFlashbackOutreach do
  @moduledoc """
  闪念间批量触达（R1/R3/R4，platform_admin，两段式确认）：按场次解析可触达
  校友（未退订）逐人入 outreach 队列。确认摘要含预估入队数、通道三档分布、
  退订剔除数与短信腿就绪位（R4）——运营确认前可核对影响面。通道三档 R11：
  all（email 优先/phone 兜底）| email | sms。token 铸造在 worker 内完成
  （明文不落库，KTD2）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Flashback.Outreach.Dispatch
  alias Cgc2046.Flashback.OutreachAdmin
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  schema do
    field(:archive_key, :string, description: "场次 key（如 2014-01-11-bj）", required: true)
    field(:template, :string, description: "触达模板（当前白名单: reconnect）", required: true)
    field(:channel, :string, description: "通道: all（email 优先/phone 兜底）| email | sms，默认 all")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_send_flashback_outreach", fn _actor, _ws, params ->
        with {:ok, channel} <- parse_channel(params["channel"]),
             {:ok, preview} <- OutreachAdmin.preview(params["archive_key"], channel),
             :ok <- Dispatch.validate_template(params["template"]) do
          Confirmation.request(
            frame.assigns[:current_user],
            "admin_send_flashback_outreach",
            params,
            summary(preview, params["template"])
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
  确认后真正执行（Confirmation 分派）：入队，治理留痕由 Dispatch 单源写入
  （失败不阻塞已入队的发送）。
  返回入队/跳过计数——入队即动作结果（KTD6）；错峰发送进行中，送达结果见
  /admin/flashback 批次历史。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    channel =
      case Dispatch.parse_channel(params["channel"] || "all") do
        {:ok, channel} -> channel
        _ -> :all
      end

    # R6 fail-closed 第二道闸：入队面已抑制 sms 通道，配置竞态窗口内确认的
    # 仅短信发送在此显式拒绝（不静默零入队）。
    # 治理留痕单源在 Dispatch（R1）——与 /admin/flashback GraphQL 面共用。
    with :ok <- Dispatch.ensure_channel_ready(channel),
         {:ok, %{queued: queued, skipped: skipped}} <-
           Dispatch.enqueue_for_archive(params["archive_key"], params["template"], channel,
             actor: actor
           ) do
      {:ok,
       %{
         archive_key: params["archive_key"],
         channel: to_string(channel),
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

  defp summary(preview, template) do
    channel_text =
      case preview.channel do
        :all -> "全部（email 优先/phone 兜底）"
        :email -> "仅邮件"
        :sms -> "仅短信"
      end

    sms_note =
      if preview.sms_ready do
        ""
      else
        "；短信腿未配置，仅短信发送将被拒绝，全部档只走邮件"
      end

    "闪念间批量触达「#{preview.archive_name}」（#{preview.archive_key}）· 模板 #{template} · 通道 #{channel_text}#{sms_note}。预估入队 #{preview.queued} 人（仅邮件 #{preview.email_only} / 仅短信 #{preview.sms_only} / 双通道 #{preview.both}），退订剔除 #{preview.unsubscribed} 人。确认后错峰发送。"
  end

  defp dispatch_error_message(%{code: code, message: message}), do: "#{code}: #{message}"
  defp dispatch_error_message(other), do: inspect(other)
end
