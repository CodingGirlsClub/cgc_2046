defmodule Cgc2046Web.GraphqlSchema.Learning.Helpers do
  @moduledoc """
  Learning 读面域 resolver helper（myEnrollment 解析与 enrollment 出示门控），
  仅供 `GraphqlSchema.Learning` 使用。
  """

  # #355 P1-3：myEnrollment 解析。kind 白名单解析（event | course）后委托
  # Enrollment 活跃报名共享读取面；读取失败按无报名降级（附挂信息不阻断详情
  # 主读，与 MCP discover_offerings 同纪律）。status 原子显式 to_string——
  # 手写 :enrollment object 无 ash_graphql 生成查询的枚举转换层。
  def resolve_my_enrollment(actor, %{kind: kind, offering_id: offering_id}) do
    case parse_offering_kind(kind) do
      {:ok, kind_atom} ->
        {event_ids, course_ids} =
          if kind_atom == :event, do: {[offering_id], []}, else: {[], [offering_id]}

        enrollment =
          actor
          |> Cgc2046.Admission.Enrollment.active_enrollments_by_offering(event_ids, course_ids)
          |> Map.get({kind_atom, offering_id})

        {:ok, enrollment && my_enrollment_payload(enrollment)}

      :error ->
        {:error, [message: "invalid kind (expected event | course)", code: "invalid_input"]}
    end
  end

  def parse_offering_kind("event"), do: {:ok, :event}
  def parse_offering_kind("course"), do: {:ok, :course}
  def parse_offering_kind(_other), do: :error

  def my_enrollment_payload(enrollment) do
    %{
      id: enrollment.id,
      workspace_id: enrollment.workspace_id,
      event_id: enrollment.event_id,
      course_id: enrollment.course_id,
      user_id: enrollment.user_id,
      status: to_string(enrollment.status),
      approval_deadline: enrollment.approval_deadline,
      rejection_reason: enrollment.rejection_reason,
      check_in_code: enrollment.check_in_code,
      inserted_at: enrollment.inserted_at
    }
  end

  # enrollment calculation 字段的 alias 感知取值（手写 object 无 AshGraphql
  # resolve_calculation）：alias 查询读 AshGraphql 加载槽；无 alias 读
  # calculations map（Ash 加载后写入），原字段兜底。
  #
  # parent 双形态（#727 健壮化）：Ash record（calculations 键存在，未加载为 nil）
  # 与 my_enrollment 的白名单 payload map（**没有** :calculations 键）——
  # `parent.calculations` 对后者抛 KeyError（不是 nil），必须走 Map.get/3 兜底；
  # 裸 map 上计算字段取不到值即 nil（该投影不携带计算值，不是崩溃）。
  def enrollment_calc_value(parent, %{alias: nil}, field) do
    Map.get(calculations(parent), field) || Map.get(parent, field)
  end

  def enrollment_calc_value(parent, %{alias: field_alias}, _field) do
    Map.get(calculations(parent), {:__ash_graphql_calculation__, field_alias})
  end

  def calculations(parent), do: Map.get(parent, :calculations) || %{}

  # checkInCode 出示门控（KTD5）：仅 actor 即报名人且报名 confirmed。
  # status 双形态：my_enrollment_payload 白名单 map 已 to_string；Ash record
  # 为 :atom（手写 object 无 ash_graphql 生成查询的枚举转换层——同
  # resolve_my_enrollment 的显式 to_string 纪律）。
  def check_in_code_visible?(parent, actor) do
    enrollment_value(parent, :user_id) == actor.id and
      enrollment_value(parent, :status) in ["confirmed", :confirmed]
  end

  def enrollment_value(parent, field) when is_map(parent),
    do: Map.get(parent, field) || Map.get(parent, to_string(field))
end
