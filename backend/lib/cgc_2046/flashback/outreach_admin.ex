defmodule Cgc2046.Flashback.OutreachAdmin do
  @moduledoc """
  闪念间触达管理查询面（R4/R8/R9，PlatformAdmin 专用口径）。

  与 `AdminStats` 的分工：本模块只服务「触达发送」运营闭环——确认摘要/页面
  预览的通道分布（`preview/2`）、批次历史（后续 U）、名册视图（后续 U）。
  三档口径与 `Dispatch.archive_channel_breakdown/1` 单源（KTD2），不在此重复
  可达性规则。
  """

  alias Cgc2046.Flashback.EventArchive
  alias Cgc2046.Flashback.Outreach.Dispatch

  require Ash.Query

  @doc """
  批量触达预览（R4 摘要口径）：给定场次与通道档，返回预估入队数、三档分布、
  退订剔除数与短信腿就绪位。不入队、零副作用——MCP 确认摘要与页面预览共用。
  """
  @spec preview(String.t(), atom()) ::
          {:ok,
           %{
             archive_key: String.t(),
             archive_name: String.t(),
             channel: atom(),
             queued: non_neg_integer(),
             email_only: non_neg_integer(),
             sms_only: non_neg_integer(),
             both: non_neg_integer(),
             unsubscribed: non_neg_integer(),
             unreachable: non_neg_integer(),
             sms_ready?: boolean()
           }}
          | {:error, term()}
  def preview(archive_key, channel) when channel in [:all, :email, :sms] do
    with {:ok, archive} <- fetch_archive(archive_key),
         {:ok, breakdown} <- Dispatch.archive_channel_breakdown(archive.id) do
      queued =
        case channel do
          :all -> breakdown.email_only + breakdown.both + breakdown.sms_only
          :email -> breakdown.email_only + breakdown.both
          :sms -> breakdown.sms_only + breakdown.both
        end

      {:ok,
       %{
         archive_key: archive.key,
         archive_name: archive.name,
         channel: channel,
         queued: queued,
         email_only: breakdown.email_only,
         sms_only: breakdown.sms_only,
         both: breakdown.both,
         unsubscribed: breakdown.unsubscribed,
         unreachable: breakdown.unreachable,
         sms_ready?: Dispatch.sms_configured?()
       }}
    end
  end

  defp fetch_archive(archive_key) do
    EventArchive
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^archive_key)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, %{code: "flashback_archive_not_found"}}
      {:ok, archive} -> {:ok, archive}
      {:error, reason} -> {:error, reason}
    end
  end
end
