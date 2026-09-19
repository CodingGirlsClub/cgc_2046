defmodule Cgc2046.Mcp.Tools.RecruitmentCohortHelpers do
  @moduledoc """
  招募批次工具族共享投影与取参（admin_initiative_helpers / PaymentSlot 同款
  「工具间单源」惯例——五件工具的行投影与租户收紧取数不逐份复制）。
  """

  alias Cgc2046.Mcp.Tools.AdminInitiativeHelpers
  alias Cgc2046.Recruitment.RecruitmentCohort

  require Ash.Query

  # 与 RecruitmentCohort :create/:update 的 datetime accept 字段一一对应
  @datetime_fields ~w(apply_deadline_at starts_at ends_at)a

  @doc "工具响应 / 列表行的批次投影（五件共用同一形状，agent 无需判键存在）"
  @spec row(RecruitmentCohort.t()) :: %{
          cohort_id: String.t(),
          name: String.t(),
          status: atom(),
          apply_deadline_at: DateTime.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil
        }
  def row(cohort) do
    %{
      cohort_id: cohort.id,
      name: cohort.name,
      status: cohort.status,
      apply_deadline_at: cohort.apply_deadline_at,
      starts_at: cohort.starts_at,
      ends_at: cohort.ends_at
    }
  end

  @doc """
  tenant 收紧批次归属：他租户 cohort_id 与不存在同一「not found」，不泄露存在性
  （launch_event.fetch_event 同款纪律）。
  """
  @spec fetch_cohort(term(), String.t(), String.t()) ::
          {:ok, RecruitmentCohort.t()} | {:error, String.t()}
  def fetch_cohort(actor, workspace_id, cohort_id) do
    RecruitmentCohort
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^cohort_id)
    |> Ash.read_one(actor: actor, tenant: workspace_id)
    |> case do
      {:ok, nil} -> {:error, "recruitment cohort not found: #{cohort_id}"}
      {:ok, cohort} -> {:ok, cohort}
      {:error, %Ash.Error.Forbidden{}} -> {:error, "forbidden: not allowed to read cohort"}
      {:error, _} -> {:error, "failed to load recruitment cohort"}
    end
  end

  @doc """
  时间字段经通用解析复用（admin_initiative_helpers 单源，带偏移 ISO8601 → UTC
  DateTime）；其余字段原样透传。解析失败保留原字符串，由 Ash cast 报错并经
  Errors.message 折叠——不在工具层发明第二种错误出口。
  """
  @spec parse_datetime_attrs(map()) :: map()
  def parse_datetime_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when key in @datetime_fields ->
        {key, AdminInitiativeHelpers.parse_datetime(value)}

      {key, value} ->
        {key, value}
    end)
  end
end
