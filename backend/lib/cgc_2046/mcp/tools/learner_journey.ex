defmodule Cgc2046.Mcp.Tools.LearnerJourney do
  @moduledoc """
  学员旅程工具族（role-agent-journeys-v2 S7：discover_offerings /
  get_enrollment_summary / create_enrollment / get_my_enrollments /
  get_order_status）的共享读取面。

  - `checkout_url/1`：web 下单页绝对链接（`/orders/new?enrollmentId=`，缴费闭环
    U11）；base 取既有 `config :cgc_2046, :web_base_url`（runtime.exs：dev/test
    默认 http://localhost:3000，prod 强制 WEB_BASE_URL https）——
    speaker_invitation_email / send_password_reset_email 同款出处，不新增配置键。
  - 「活跃报名」= pending / payment_pending / confirmed（部分唯一索引
    unique_event_user / unique_course_user 的占位状态集，enrollment.ex
    identities 同款口径）：每个 (actor, offering) 至多一条。
  - 活跃报名读取一律带 actor 走 policy（Enrollment read policy：
    `user_id == ^actor(:id)` 本人可读），actor 锚定无越权面。
  """

  alias Cgc2046.Admission.Enrollment

  require Ash.Query

  @active_statuses [:pending, :payment_pending, :confirmed]

  @doc "活跃状态集（pending/payment_pending/confirmed，唯一索引占位口径）。"
  def active_statuses, do: @active_statuses

  @doc """
  web 下单页绝对链接（支付入口唯一落点）。enrollment_id 为 nil 时返回 nil。
  """
  @spec checkout_url(String.t() | nil) :: String.t() | nil
  def checkout_url(nil), do: nil

  def checkout_url(enrollment_id) when is_binary(enrollment_id) do
    base =
      Application.get_env(:cgc_2046, :web_base_url, "http://localhost:3000")
      |> to_string()
      |> String.trim_trailing("/")

    "#{base}/orders/new?enrollmentId=#{enrollment_id}"
  end

  @doc """
  解析必填 kind 参数：`{:ok, :event | :course} | {:error, String.t()}`。
  缺省/未知值均为参数错误（学员旅程工具不允许 event → course 盲扫）。
  """
  @spec parse_required_kind(term()) :: {:ok, :event | :course} | {:error, String.t()}
  def parse_required_kind("event"), do: {:ok, :event}
  def parse_required_kind("course"), do: {:ok, :course}

  def parse_required_kind(other),
    do: {:error, "invalid kind: #{inspect(other)} (expected event | course)"}

  @doc """
  actor 在目标 workspace 内、目标 offering 上的活跃报名（无 → nil）。带 actor
  走 policy；读取失败按无报名降级（发现/摘要面的附挂信息不阻断主读）。

  workspace 过滤（#349 B）：幂等重放回读按 (actor, kind, offering, workspace)
  四元组钉死；offering UUID 全局唯一下为防御深度，fail-closed。
  """
  @spec active_enrollment(term(), :event | :course, String.t(), String.t()) ::
          Enrollment.t() | nil
  def active_enrollment(actor, kind, offering_id, workspace_id) do
    {event_ids, course_ids} =
      if kind == :event, do: {[offering_id], []}, else: {[], [offering_id]}

    actor
    |> active_enrollments_by_offering(event_ids, course_ids, workspace_id)
    |> Map.get({kind, offering_id})
  end

  @doc """
  批量取 actor 在给定 offering id 集上的活跃报名：
  `%{(:event | :course, offering_id) => %Enrollment{}}`（消 N+1）。
  """
  @spec active_enrollments_by_offering(term(), [String.t()], [String.t()], String.t() | nil) ::
          %{{:event | :course, String.t()} => Enrollment.t()}
  def active_enrollments_by_offering(actor, event_ids, course_ids, workspace_id \\ nil) do
    query =
      Enrollment
      |> Ash.Query.filter(
        user_id == ^actor.id and status in ^@active_statuses and
          (event_id in ^event_ids or course_id in ^course_ids)
      )

    query =
      if workspace_id,
        do: Ash.Query.filter(query, workspace_id == ^workspace_id),
        else: query

    query
    |> Ash.read(actor: actor)
    |> case do
      {:ok, enrollments} ->
        Map.new(enrollments, fn enrollment ->
          {offering_key(enrollment), enrollment}
        end)

      {:error, _} ->
        %{}
    end
  end

  defp offering_key(%{event_id: event_id}) when is_binary(event_id), do: {:event, event_id}
  defp offering_key(%{course_id: course_id}) when is_binary(course_id), do: {:course, course_id}
end
