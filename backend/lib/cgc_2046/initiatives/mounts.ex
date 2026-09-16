defmodule Cgc2046.Initiatives.Mounts do
  @moduledoc """
  Initiative 挂载场读投影（#595）：一次查询给出该 Initiative 全部已挂载 Event
  的真值 + 所属 Workspace 名字，供平台管理台「影响预览 / 事后核对」使用。

  ## 口径（与 `Initiatives.Public` 的刻意差异）

  - **不过滤 `visibility`**：锁死规则传播会改写全部已挂载场（含
    `visibility: :workspace` 的内部场），故清单必须是全集；`Public.fetch_events/1`
    只投影 `visibility = 'public'` 的公开场，两者口径不同是因为服务对象不同。
  - **不过滤 `status`**：draft / open / closed / cancelled 全在清单里（前端按
    draft·open·终态分组展示）。传播范围是否限于 draft/open 属 #587 的语义，
    本模块只如实投影真值，不预判。
  - **无分页**：影响预览的数字必须与操作者看到的行严格同源，截断会让计数漂移。
    承载假设 = 单个 Initiative 的挂载场在人工运营量级（≤200 场）。若日后实测
    推翻，降级路径 = 加 `first/after` 并把 by-status 计数改为后端标量（另开 issue）。
  - **排序**：`starts_at NULLS LAST, inserted_at, id`（与 `Public.fetch_events/1`
    同款稳定序），保证同一数据下响应逐字节可复现。

  ## 门控

  本模块不自带鉴权，**只允许**从平台管理员门控后的读面调用（GraphQL 侧经
  `admin_initiative.mountedEvents`，其父 query 已由 `with_admin/2` 收口）。
  与 `graphql_schema.ex` 的 `resolve_my_workspace_tool_calls/3` 同款纪律：
  `authorize?: false` 直读 + 上游显式门控。

  ## 实现

  单条裸 SQL join `events × workspaces`：Event 是 `workspace_id` 属性多租户资源，
  跨租户读 + 需要 Workspace 名字，裸 SQL 一次拿全且不引入 policy/tenant 分支
  （`Public` 同为裸 SQL 投影先例）。
  """

  alias Cgc2046.Repo

  @doc """
  返回某 Initiative 的全部挂载场（按上述排序）。

  字段与 `AdminInitiativeMountedEvent`（graphql_schema.ex）逐一对齐；
  `venue` 保持解码后的 map（SDL `JsonString` 标量自行 `Jason.encode!/1`）。
  """
  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(initiative_id) do
    query = """
    SELECT e.id, e.slug, e.title, e.status, e.starts_at, e.registration_deadline,
           e.venue, e.confirmed_count, e.pricing_enabled, e.deposit_enabled,
           e.deposit_amount_cents, e.min_age, e.min_participants, e.initiative_id,
           w.id, w.name
    FROM events e
    JOIN workspaces w ON w.id = e.workspace_id
    WHERE e.initiative_id = $1
    ORDER BY e.starts_at NULLS LAST, e.inserted_at, e.id
    """

    case Repo.query(query, [Repo.uuid!(initiative_id)]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &row_to_mount/1)}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp row_to_mount([
         id,
         slug,
         title,
         status,
         starts_at,
         registration_deadline,
         venue,
         confirmed_count,
         pricing_enabled,
         deposit_enabled,
         deposit_amount_cents,
         min_age,
         min_participants,
         initiative_id,
         workspace_id,
         workspace_name
       ]) do
    %{
      id: uuid_text(id),
      initiative_id: uuid_text(initiative_id),
      slug: slug,
      title: title,
      status: status,
      starts_at: to_utc_datetime(starts_at),
      registration_deadline: to_utc_datetime(registration_deadline),
      venue: venue,
      workspace_id: uuid_text(workspace_id),
      workspace_name: workspace_name,
      confirmed_count: confirmed_count,
      pricing_enabled: pricing_enabled,
      deposit_enabled: deposit_enabled,
      deposit_amount_cents: deposit_amount_cents,
      min_age: min_age,
      min_participants: min_participants
    }
  end

  # 裸 SQL 绕过 Ecto 类型加载，utc_datetime 列返回 NaiveDateTime；
  # GraphQL :datetime 标量只接受 DateTime，统一按 UTC 抬升（同 Public）。
  defp to_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_utc_datetime(value), do: value

  defp uuid_text(<<_::128>> = id), do: Ecto.UUID.load!(id)
  defp uuid_text(id), do: id
end
