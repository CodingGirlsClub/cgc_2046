defmodule Cgc2046.Events.Offering do
  @moduledoc """
  供给物（Offering）读取面 seam：一行可指向 Event 或 Course 的统一读取
  （PR-H；plan 2026-08-15-009 决策 D1-D7）。

  五处各自为政的 Ash.get Event/Course 分叉（NotificationSubscriber.target_title /
  LearningInstantiator.fetch_entity / PendingApprovals.load_offering_titles /
  GraphqlSchema.fetch_offering_by_id / ResearchInstantiator.fetch_entity）收敛为
  一个 interface，错误形状统一坍缩为 `{:error, :not_found}` 单点。

  ## 命名空间区分

  kind 原子 `:event` 与 Sponsorship `level: :event`（赞助级别）**撞名但无语义关系**
  ——本模块的 `:event | :course` 是「一行可指向哪种供给物」的读取分派键；赞助级别
  是业务分类字段（D5 不动，勿混用）。

  ## interface

  - `fetch/3`：`fetch(kind, id, opts \\ [])` → `{:ok, entity} | {:error, :not_found}`。
    kind ∈ `:event | :course`；opts `authorize?: false`（默认）/ `actor:`（graphql
    场景，全库唯一 actor 感知读取）/ `tenant:`。返回**完整 entity**（research 需
    status graphql 需完整 struct 供 Readiness;research 门控 U6 起 event-only)。
  - `fetch_by_signal_payload/1`：按 payload 键 `event_id`/`course_id` 分派（消灭
    各处手写键探测）。
  - `fetch_titles_by_ids/2`：批量（`%{kind => [ids]}` + tenant → `%{id => title}`），
    保持 per-kind per-tenant 的 Ash.read 批量形状（消 N+1 不退化）。
  - `fetch_slugs_by_ids/2`：同形状批量取 slug（`%{id => slug}`，E-9 #123 审批页
    expired 重提链接按目标活动公开页 `/events/<slug>` 落点）。
  - 投影便利：`kind/1`、`title/1`、`workspace_id/1`（entity → 值）。
  """

  require Ash.Query

  alias Cgc2046.Events.{Course, Event}

  @doc """
  按 kind + id 读取供给物。默认 `authorize?: false`（匹配原五处分叉行为）；
  非命中（不存在 / 授权拒绝 / 读取错误）统一 `{:error, :not_found}`。
  """
  @spec fetch(:event | :course, String.t(), keyword()) ::
          {:ok, Event.t() | Course.t()} | {:error, :not_found}
  def fetch(kind, id, opts \\ []) do
    resource_for(kind)
    |> Ash.get(id, Keyword.put_new(opts, :authorize?, false))
    |> case do
      {:ok, %_{} = entity} -> {:ok, entity}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  按信号 payload 分派：`event_id` → `fetch(:event, id)`，`course_id` →
  `fetch(:course, id)`；无两者或空串 → `{:error, :not_found}`。
  """
  @spec fetch_by_signal_payload(map()) ::
          {:ok, Event.t() | Course.t()} | {:error, :not_found}
  def fetch_by_signal_payload(%{"event_id" => id}) when is_binary(id) and id != "",
    do: fetch(:event, id)

  def fetch_by_signal_payload(%{"course_id" => id}) when is_binary(id) and id != "",
    do: fetch(:course, id)

  def fetch_by_signal_payload(_data), do: {:error, :not_found}

  @doc """
  批量取标题：`%{event: [ids], course: [ids]}` + tenant → `%{id => title}`。
  按 kind 分组、per-tenant 批量 `Ash.read`（保持 PendingApprovals 既有批量形状，
  不退化 N+1；空 id 列表不查询）。
  """
  @spec fetch_titles_by_ids(%{optional(:event | :course) => [String.t()]}, String.t()) ::
          %{String.t() => String.t()}
  def fetch_titles_by_ids(ids_by_kind, tenant) do
    Enum.reduce(ids_by_kind, %{}, fn {kind, ids}, acc ->
      Map.merge(acc, field_values_for(resource_for(kind), ids, tenant, :title))
    end)
  end

  @doc """
  批量取 slug：`%{event: [ids], course: [ids]}` + tenant → `%{id => slug}`。
  与 `fetch_titles_by_ids/2` 同形状（per-kind per-tenant 批量读，消 N+1）；
  未配置 slug 的供给物不在结果中出现（调用方按缺失降级）。
  """
  @spec fetch_slugs_by_ids(%{optional(:event | :course) => [String.t()]}, String.t()) ::
          %{String.t() => String.t()}
  def fetch_slugs_by_ids(ids_by_kind, tenant) do
    Enum.reduce(ids_by_kind, %{}, fn {kind, ids}, acc ->
      Map.merge(acc, field_values_for(resource_for(kind), ids, tenant, :slug))
    end)
  end

  @doc "entity → kind 原子（:event | :course）"
  @spec kind(Event.t() | Course.t()) :: :event | :course
  def kind(%Event{}), do: :event
  def kind(%Course{}), do: :course

  @doc "entity → title"
  @spec title(Event.t() | Course.t()) :: String.t()
  def title(%Event{title: title}), do: title
  def title(%Course{title: title}), do: title

  @doc "entity → workspace_id"
  @spec workspace_id(Event.t() | Course.t()) :: String.t()
  def workspace_id(%Event{workspace_id: workspace_id}), do: workspace_id
  def workspace_id(%Course{workspace_id: workspace_id}), do: workspace_id

  defp resource_for(:event), do: Event
  defp resource_for(:course), do: Course

  defp field_values_for(_resource, [], _tenant, _field), do: %{}

  defp field_values_for(resource, ids, tenant, field) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.reduce(%{}, fn offering, acc ->
      case Map.get(offering, field) do
        nil -> acc
        value -> Map.put(acc, offering.id, value)
      end
    end)
  end
end
