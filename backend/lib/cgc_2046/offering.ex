defmodule Cgc2046.Offering do
  @moduledoc """
  供给物（Offering）读取面 seam：一行可指向 Event 或 Course 的统一读取
  （PR-H；plan 2026-08-15-009 决策 D1-D7）。

  五处各自为政的 Ash.get Event/Course 分叉（Notifications.Subscriber.target_title /
  Learning.LearningInstantiator.fetch_entity / PendingApprovals.load_offering_titles /
  GraphqlSchema.fetch_offering_by_id / Curriculum.Instantiator.fetch_entity）收敛为
  一个 interface，错误形状统一坍缩为 `{:error, :not_found}` 单点。

  ## 命名空间区分

  kind 原子 `:event` 与 Sponsorship `level: :event`（赞助级别）**撞名但无语义关系**
  ——本模块的 `:event | :course` 是「一行可指向哪种供给物」的读取分派键；赞助级别
  是业务分类字段（D5 不动，勿混用）。

  ## interface

  - `fetch/3`：`fetch(kind, id, opts \\ [])` → `{:ok, entity} | {:error, :not_found}`。
    kind ∈ `:event | :course`；opts `authorize?: false`（默认）/ `actor:`（graphql
    场景，全库唯一 actor 感知读取）/ `tenant:`。返回**完整 entity**（curriculum 需
    status graphql 需完整 struct 供 Readiness;curriculum 门控 U6 起 event-only)。
  - `fetch_by_signal_payload/1`：按 payload 键 `event_id`/`course_id` 分派（消灭
    各处手写键探测）。
  - `fetch_titles_by_ids/2`：批量（`%{kind => [ids]}` + tenant → `%{id => title}`），
    保持 per-kind per-tenant 的 Ash.read 批量形状（消 N+1 不退化）。
  - `fetch_slugs_by_ids/2`：同形状批量取 slug（`%{id => slug}`，E-9 #123 审批页
    expired 重提链接按目标活动公开页 `/events/<slug>` 落点）。
  - `fetch_schedule_by_ids/2`：同形状批量取日程化字段（`%{id => %{starts_at, venue}}`，
    venue 为 `Events.Venue.text/1` 文本化；报名日程化旅程 P2a 的 Enrollment
    starts_at/venue 计算数据源）。
  - 投影便利：`kind/1`、`title/1`、`workspace_id/1`（entity → 值）。
  - `payment_mode/1`：供给物缴费槽三态（`:free | :pricing | :deposit`）唯一谓词；
    `deposit_amount_cents/1`：押金金额（正整数，否则 `nil`）。落点状态预测
    （`Admission.Enrollment.auto_confirm_status/1`）与 MCP/扩展读面共用本谓词，
    不再各自重写三态分支。
  - `payment_slot/1`：缴费槽读面形状（`payment_mode` + `deposit` 明细块）唯一实现，
    MCP 四个读面工具与公开 Initiative 投影共用（#627）。
  """

  require Ash.Query

  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.Events.Venue

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

  @doc """
  批量取日程化字段：`%{event: [ids], course: [ids]}` + tenant →
  `%{id => %{starts_at: DateTime.t() | nil, venue: String.t() | nil}}`。
  与 `fetch_titles_by_ids/2` 同形状（per-kind per-tenant 批量读，消 N+1；
  空 id 列表不查询）。starts_at 为供给物原始值（可 nil）；venue 为 Event
  venue map 经 `Events.Venue.text/1` 的「city+district」文本化（Course 或无
  venue → nil），与 event_reminder 通知文案同款。另带缴费槽字段
  `registration_deadline / deposit_enabled / deposit_amount_cents /
  pricing_enabled`（#749 起 deposit 金额入投影，Enrollment 展示面与创单同源）。
  """
  @spec fetch_schedule_by_ids(%{optional(:event | :course) => [String.t()]}, String.t()) ::
          %{
            String.t() => %{
              starts_at: DateTime.t() | nil,
              venue: String.t() | nil,
              registration_deadline: DateTime.t() | nil,
              deposit_enabled: boolean(),
              deposit_amount_cents: pos_integer() | nil,
              pricing_enabled: boolean()
            }
          }
  def fetch_schedule_by_ids(ids_by_kind, tenant) do
    Enum.reduce(ids_by_kind, %{}, fn {kind, ids}, acc ->
      Map.merge(acc, schedule_for(resource_for(kind), ids, tenant))
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

  @doc """
  供给物缴费槽三态（CONTEXT「缴费槽」/ event-deposit R1·R3·KTD2）：
  `:deposit | :pricing | :free`。

  押金优先于定价参与判定——两列互斥由 `Events.PaymentModeValidation` 与 DB CHECK
  `events_payment_mode_exclusive` 保证同时为真不可达，故优先级只影响不可达输入；
  判定序与 web `paymentModeOf`、`Enrollment.payment_mode` 计算字段逐字一致。

  入参形状宽松：Event/Course struct（course 无押金列）、`schedule_for/3` 的投影
  map、或 `confirm_target_status/2` 那样的裸 SQL 行 map 皆可；nil/缺键落 `:free`
  （存量行为：目标供给物不可得时旧实现亦落免费）。

  **只匹配 atom 键**：JSON 解码后的 string 键 map（`%{"deposit_enabled" => true}`）
  不匹配任何子句，会静默落 `:free`——调用方须先转成 struct 或 atom 键 map。
  """
  @spec payment_mode(map() | nil) :: :free | :pricing | :deposit
  def payment_mode(%{deposit_enabled: true}), do: :deposit
  def payment_mode(%{pricing_enabled: true}), do: :pricing
  def payment_mode(_offering), do: :free

  @doc """
  押金金额（分）：仅正整数算有效金额，非正/缺失（course 无押金列、U3 校验前写入
  的历史脏行）一律降级 `nil`——读面绝不臆造 ¥0。

  判据与 `Payments.Order.deposit_tier/1` 同源：那边对非正金额 fail-closed 报
  `order_deposit_amount_missing`，本函数把同一事实投影成「无金额」给展示面。
  同样**只匹配 atom 键**（string 键 map → nil，见 `payment_mode/1`）。
  """
  @spec deposit_amount_cents(map() | nil) :: pos_integer() | nil
  def deposit_amount_cents(%{deposit_amount_cents: amount})
      when is_integer(amount) and amount > 0,
      do: amount

  def deposit_amount_cents(_offering), do: nil

  @doc """
  缴费槽读面投影：`%{payment_mode: String.t(), deposit: map()}`（跨面唯一实现）。

  落在域层而非某个消费面：MCP 读面（`Mcp.Tools.PaymentSlot`，四个工具共用）与公开
  Initiative 投影（`Initiatives.Public`）同用此形状——domain 不反向依赖 interface
  层，各消费面也不再手写同一份 block（#586 的「唯一出口」纪律不变，出口下沉到此）。

  展示降级规则（#586 裁决，逐条保留）：

  - `deposit.enabled` 只看 mode，不看金额：押金场金额脏（历史行的 nil / 0）也恒为
    `true`，绝不掉回「免费」——把押金场说成免费的病根即「无信号 + 金额缺失」被读成
    免费。
  - `deposit.amount_cents` 只出正整数，否则 `nil`，绝不显示 `0`。
  - `refundable_on_check_in` 押金态恒 `true`：平台规则「到场核销即退」（CONTEXT
    押金段），非每场可配；其余态 `nil`。
  - 非押金场形状恒定（`enabled: false` 而非整块 `nil`）：字段缺席正是 #586 的病根，
    恒定形状让「押金槽存在但未开」可见。

  入参形状纪律同 `payment_mode/1`：**只匹配 atom 键**，string 键 map（JSON 解码
  形状）会被判成 free，调用方不得直传解码后的 payload。
  """
  @spec payment_slot(map() | nil) :: %{payment_mode: String.t(), deposit: map()}
  def payment_slot(offering) do
    mode = payment_mode(offering)

    %{payment_mode: to_string(mode), deposit: deposit_block(offering, mode)}
  end

  defp deposit_block(offering, :deposit) do
    %{
      enabled: true,
      amount_cents: deposit_amount_cents(offering),
      refundable_on_check_in: true
    }
  end

  defp deposit_block(_offering, _mode) do
    %{enabled: false, amount_cents: nil, refundable_on_check_in: nil}
  end

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

  defp schedule_for(_resource, [], _tenant), do: %{}

  defp schedule_for(resource, ids, tenant) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Map.new(fn offering ->
      {offering.id,
       %{
         starts_at: offering.starts_at,
         venue: venue_text_for(offering),
         registration_deadline: offering.registration_deadline,
         deposit_enabled: Map.get(offering, :deposit_enabled) == true,
         # 押金现值（#749）：Enrollment.deposit_amount_cents 计算字段与创单金额
         # 同源（活动现值权威）；course 无押金列 → nil
         deposit_amount_cents: Map.get(offering, :deposit_amount_cents),
         pricing_enabled: offering.pricing_enabled == true
       }}
    end)
  end

  defp venue_text_for(%Event{venue: venue}) when is_map(venue), do: Venue.text(venue)
  defp venue_text_for(_offering), do: nil
end
