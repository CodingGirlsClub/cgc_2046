defmodule Cgc2046.Mcp.Tools.LearnerJourney do
  @moduledoc """
  学员旅程工具族（role-agent-journeys-v2 S7：discover_offerings /
  get_enrollment_summary / create_enrollment / get_my_enrollments /
  get_order_status）的共享读取面。

  - `checkout_url/1`：web 下单页绝对链接（`/orders/new?enrollmentId=`，缴费闭环
    U11）；base 取既有 `config :cgc_2046, :web_base_url`（runtime.exs：dev/test
    默认 http://localhost:3000，prod 强制 WEB_BASE_URL https）——
    speaker_invitation_email / send_password_reset_email 同款出处，不新增配置键。
  - 「活跃报名」读取真源 = `Cgc2046.Admission.Enrollment`（active_statuses /
    active_enrollment / active_enrollments_by_offering，#355 P1-3 起 MCP 与
    GraphQL Event/Course myEnrollment 计算共用同一语义）。
  """

  alias Cgc2046.Mcp.Tools.PublicOffering

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
  词汇解析与错误串单源于 `PublicOffering.parse_kind/1`（C12 #855）；
  此处只补 nil 必填分支——`parse_kind(nil)` 是 `{:ok, nil}`（不窄化），
  必填语义下须转回与缺省同式的参数错误（消息为已发布契约，逐字节不变）。
  """
  @spec parse_required_kind(term()) :: {:ok, :event | :course} | {:error, String.t()}
  def parse_required_kind(nil),
    do: {:error, "invalid kind: nil (expected event | course)"}

  def parse_required_kind(kind), do: PublicOffering.parse_kind(kind)
end
