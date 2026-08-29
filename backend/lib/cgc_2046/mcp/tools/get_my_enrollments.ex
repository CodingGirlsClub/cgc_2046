defmodule Cgc2046.Mcp.Tools.GetMyEnrollments do
  @moduledoc """
  本人全部报名（role-agent-journeys-v2 S7，R32/R35/AE8；全状态、跨工作台、
  actor 锚定读，不收参数）。

  meta `%{workspace_id: :optional, membership: :deferred}` 命中 Wrapper 的
  `:optional` 分支（discover_offerings 同款跨工作台语义；Enrollment read
  policy `user_id == ^actor(:id)` 本人锚定，无越权面）。

  供给标题/slugs 经 `authorize?: false` 批量投影（先例 = Enrollment.target_title
  计算字段：本人报名锚定的供给段收窄，标题非敏感面）；宿主 workspace 块带
  actor 走 policy（invite_only 工作台对非成员落 nil——跨台报名的可能宿主）。
  附最新订单的 tier_snapshot（带 actor 本人订单，非终态优先）。
  最多 100 条（§B#16 读面封顶）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :deferred}

  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Payments.Order

  require Ash.Query

  @limit 100

  schema do
    %{}
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_my_enrollments", fn actor, _workspace_id, _params ->
        with {:ok, enrollments} <- read_my_enrollments(actor),
             {:ok, offerings} <- load_offerings(enrollments),
             {:ok, workspaces} <- load_workspaces(actor, enrollments),
             {:ok, tier_snapshots} <- load_tier_snapshots(actor, enrollments) do
          {:ok,
           %{
             enrollments:
               Enum.map(enrollments, &to_row(&1, offerings, workspaces, tier_snapshots)),
             count: length(enrollments)
           }}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 本人报名全状态（带 actor 走 policy，user_id == actor 收窄）；倒序 + 上限。
  # read（非 bang）纪律同 list_public_offerings：失败走 Wrapper 审计不逃逸。
  defp read_my_enrollments(actor) do
    Enrollment
    |> Ash.Query.filter(user_id == ^actor.id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@limit)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, enrollments} -> {:ok, enrollments}
      {:error, _} -> {:error, "failed to load enrollments"}
    end
  end

  # 供给物投影批量读：%{kind => %{offering_id => %{title, slug}}}。
  # authorize?: false 先例 = Enrollment.target_title 计算字段（本人报名锚定投影）。
  defp load_offerings(enrollments) do
    ids_by_kind = %{
      event: enrollments |> Enum.map(& &1.event_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      course: enrollments |> Enum.map(& &1.course_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }

    [event: Event, course: Course]
    |> Enum.reduce_while({:ok, %{}}, fn {kind, resource}, {:ok, acc} ->
      case read_offering_titles(resource, Map.fetch!(ids_by_kind, kind)) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, kind, rows)}}
        {:error, _} -> {:halt, {:error, "failed to load offerings"}}
      end
    end)
  end

  defp read_offering_titles(_resource, []), do: {:ok, %{}}

  defp read_offering_titles(resource, ids) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, records} -> {:ok, Map.new(records, &{&1.id, %{title: &1.title, slug: &1.slug}})}
      {:error, _} = error -> error
    end
  end

  # 宿主工作台块：带 actor 的 policy 授权批量读（invite_only 对非成员落 nil）。
  defp load_workspaces(actor, enrollments) do
    ids = enrollments |> Enum.map(& &1.workspace_id) |> Enum.uniq()

    Workspace
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, workspaces} -> {:ok, Map.new(workspaces, &{&1.id, &1})}
      {:error, _} -> {:error, "failed to load workspaces"}
    end
  end

  # 最新一笔订单的档位快照：%{enrollment_id => tier_snapshot}（带 actor 本人订单）。
  defp load_tier_snapshots(actor, enrollments) do
    ids = Enum.map(enrollments, & &1.id)

    Order
    |> Ash.Query.filter(enrollment_id in ^ids)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, orders} ->
        {:ok,
         orders
         |> Enum.uniq_by(& &1.enrollment_id)
         |> Map.new(fn order -> {order.enrollment_id, order.tier_snapshot} end)}

      {:error, _} ->
        {:error, "failed to load orders"}
    end
  end

  defp to_row(enrollment, offerings, workspaces, tier_snapshots) do
    {kind, offering_id} = kind_and_offering_id(enrollment)
    offering = get_in(offerings, [kind, offering_id])

    %{
      id: enrollment.id,
      kind: to_string(kind),
      offering: %{
        id: offering_id,
        title: offering && offering.title,
        slug: offering && offering.slug
      },
      workspace: workspace_block(Map.get(workspaces, enrollment.workspace_id)),
      status: to_string(enrollment.status),
      tier_snapshot: tier_snapshot(Map.get(tier_snapshots, enrollment.id)),
      inserted_at: enrollment.inserted_at
    }
  end

  defp kind_and_offering_id(%{event_id: event_id}) when is_binary(event_id),
    do: {:event, event_id}

  defp kind_and_offering_id(%{course_id: course_id}) when is_binary(course_id),
    do: {:course, course_id}

  defp workspace_block(nil), do: nil

  defp workspace_block(workspace),
    do: %{id: workspace.id, name: workspace.name, slug: workspace.slug}

  # 空快照（免费/占位订单无档位）归一为 nil
  defp tier_snapshot(snapshot) when is_map(snapshot) and map_size(snapshot) > 0, do: snapshot
  defp tier_snapshot(_snapshot), do: nil
end
