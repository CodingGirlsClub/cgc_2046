defmodule Cgc2046.Mcp.Tools.DeleteEvent do
  @moduledoc """
  删除草稿活动：物理删除 draft（#676，ADR-0015；Owner 专属管理工具，确认流 two-tool
  写，D-D3）。

  语义对齐 GraphQL deleteEvent（同 `Events.Event :delete` action）。与 close/cancel
  的差别：**只有 draft 可删**——已发布活动走 close/cancel（终态不可逆但保留行与
  slug），draft 删除不可恢复：活动行删除、slug 立即释放可复用（ADR-0014 锁的是
  发布后的 URL 段，draft slug 从未发布、无公开契约）。

  **级联**（#688 修订，同事务原子）：讲者邀请 run 在**邀请创建时**实例化（draft
  合法），删除时由 `SpeakerInvitation.stop_event_runs/1` 收口为 cancelled（留痕：
  facts 含材料镜像保留）；名额账本行由 `CapacityLedger.delete_for_offering/2` 删除
  （多态无 FK）。无教研 curriculum run（launch 后才有）、无内容行
  （curriculum_outputs 只有 course 维度）；event_moderators / sponsorships /
  speaker_invitations / invite_batches 由 FK delete_all 级联——邀请与批次对 draft
  并非结构性不存在（邀请在 draft 合法、批次创建无状态门），摘要须披露。

  权限（#676 收窄面，与 cancel 的 Owner/Admin **刻意不同**）：Owner ∪ 平台管理员。
  admin 不放行（删除不可逆、无回收站）；member-only 门的既有契约（S2）不含
  platform_admin 豁免，非成员平台管理员经 GraphQL 域放行。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  非 draft 活动快速失败（不建 pending）；并发竞态（确认窗内被 launch）由 domain
  的行锁守卫在 confirm 段兜底。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Policies.PlatformAdmin
  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Events.Event
  alias Cgc2046.Mcp.{Confirmation, Wrapper}

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    工作台 Owner 或平台管理员专用（Admin 不行）：永久删除一场草稿（draft）活动，不可恢复，slug 立即
    释放。主理人、赞助、讲者邀请、邀请批次一并删除，进行中的讲者邀请流程终止，确认摘要会列出这些
    影响。已开放过的活动不能删除，要用 close_event / cancel_event。活动不是 draft 时直接返回错误。
    走确认流：第一次调用只返回 needs_confirmation + pending_id + summary，
    用户确认后调 confirm_operation(pending_id) 才执行。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:event_id, {:required, :string}, description: "待删除活动 ID（UUID，须为 draft）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "delete_event", fn actor, workspace_id, params ->
        event_id = params["event_id"]

        with :ok <- authorize(actor, workspace_id),
             {:ok, event} <- fetch_event(actor, workspace_id, event_id) do
          if event.status != :draft do
            {:error, "cannot delete from status=#{event.status}（仅 draft 可删除）"}
          else
            summary =
              "删除草稿活动「#{event.title}」（#{event.id}）：" <>
                "活动行将永久删除、不可恢复；" <>
                "主理人指派、讲者邀请记录（含已接受）与邀请批次将一并删除；" <>
                "流程留痕（run facts）按审计保留；slug #{event.slug} 将释放可复用"

            Confirmation.request(
              frame.assigns[:current_user],
              "delete_event",
              params,
              summary
            )
          end
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  params 为 pending 落库的 redact 后参数（本工具参数无敏感键，直接可用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    workspace_id = params["workspace_id"]
    event_id = params["event_id"]

    with {:ok, event} <- fetch_event(actor, workspace_id, event_id) do
      case event
           |> Ash.Changeset.for_destroy(:delete, %{}, tenant: workspace_id)
           |> Ash.destroy(actor: actor, tenant: workspace_id) do
        :ok ->
          {:ok, %{event_id: event.id, title: event.title, slug: event.slug}}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error,
           "forbidden: owner or platform admin required to delete event in workspace #{workspace_id}"}

        {:error, err} ->
          {:error, Cgc2046.Mcp.Errors.message(err, "failed to delete event")}
      end
    end
  end

  # Owner ∪ 平台管理员（#676 收窄面）：admin 不在内。平台管理员分支同时兜住
  # 「成员平台管理员」与「非成员平台管理员」——后者撞 Wrapper member-only 门
  # （S2 成文契约：MCP 门不放宽 admin 豁免），只有 GraphQL 域放行。
  defp authorize(actor, workspace_id) do
    if PlatformAdmin.platform_admin?(actor) or Rbac.owner?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or platform admin required to delete events"}
    end
  end

  # tenant 收紧活动归属：他租户 event_id 与不存在同一「not found」，不泄露存在性
  defp fetch_event(actor, workspace_id, event_id) do
    case Event
         |> Ash.Query.for_read(:get_by_id, %{id: event_id})
         |> Ash.read_one(actor: actor, tenant: workspace_id) do
      {:ok, nil} ->
        {:error, "event not found: #{event_id}"}

      {:ok, event} ->
        {:ok, event}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not allowed to read event #{event_id}"}

      {:error, _} ->
        {:error, "failed to load event"}
    end
  end
end
