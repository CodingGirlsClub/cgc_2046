defmodule Cgc2046.Workflows.SpeakerInvitationInstantiator do
  @moduledoc """
  SpeakerInvitation 的 workflow run 实例化（E-4 #49）。

  一个邀请 = 一个 run（邀请设计 §2.3）：run 持 decision/materials 两个人工
  信号门控（manual-only 定义，无需 StepHandlerRegistry），镜像邀请生命周期：

  - 创建 → start_run → waiting（decision 门控，等 Speaker 决策）
  - 接受 → resume decision → waiting（materials 门控，等材料产出）
  - 材料产出（save_materials 写 facts）→ complete → resume materials → succeeded
  - 婉拒 → run failed（邀请设计 §5.2 状态对应表）

  定义按 workspace find_or_create（「每个 Workspace 默认内置邀请 workflow
  模板」，邀请设计 §2.3；type=speaker_invitation，published）。并发首建冲突
  （unique_name_version_per_workspace）重读既有定义，不打断邀请创建。
  """

  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  require Ash.Query

  @definition_name "Speaker 邀请 workflow"

  @doc """
  为邀请创建并启动 workflow run。返回 {:ok, run}（waiting）或 {:error, reason}。
  调用方（SpeakerInvitation.create_invitation 的 before_action）在同一事务内
  执行——失败回滚邀请创建，不落孤儿邀请。
  """
  @spec start_run(String.t(), String.t(), String.t()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def start_run(workspace_id, event_id, invitation_id) do
    with {:ok, defn} <- ensure_definition(workspace_id) do
      input = %{
        "key" => "speaker_invitation_#{invitation_id}",
        "speaker_invitation_id" => invitation_id,
        "event_id" => event_id
      }

      # key: nil → 不去重直接 create+start（PR-F D3）：邀请唯一性由调用侧
      # ensure_no_active_invitation 保证；input 的 key 字段随 run 落库不变。
      case WorkflowRun.find_or_create_and_start(workspace_id, defn, input) do
        {:ok, run, _status} -> {:ok, run}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- 定义 find_or_create ----------------------------------------------------

  defp ensure_definition(workspace_id) do
    case fetch_definition(workspace_id) do
      {:ok, %WorkflowDefinition{} = defn} ->
        {:ok, defn}

      {:ok, nil} ->
        case create_definition(workspace_id) do
          {:ok, defn} ->
            {:ok, defn}

          # 并发首建：唯一索引冲突 → 重读既有定义（幂等）
          {:error, %Ash.Error.Invalid{}} ->
            case fetch_definition(workspace_id) do
              {:ok, %WorkflowDefinition{} = defn} -> {:ok, defn}
              _ -> {:error, :definition_not_found}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 取该租户已 published 的邀请定义。多个时取最新（version desc，
  # inserted_at desc 兜底）——read_one 无排序时 Postgres 返回任意行
  # （Curriculum.Instantiator.fetch_curriculum_definition 同款纪律）。
  defp fetch_definition(workspace_id) do
    WorkflowDefinition
    |> Ash.Query.filter(type == :speaker_invitation and status == :published)
    |> Ash.Query.sort(version: :desc, inserted_at: :desc)
    |> Ash.read_first(tenant: workspace_id, authorize?: false)
  end

  defp create_definition(workspace_id) do
    attrs = %{
      name: @definition_name,
      type: :speaker_invitation,
      input_schema: %{},
      # decision：等 Speaker 接受/拒绝；materials：等材料产出后完成。
      # manual-only：start_run 直达 waiting，无 auto 步骤（ADR-0003 注册表
      # 无生产 handler，实体自序贯下引擎只做门控镜像）。
      node_def: %{
        "steps" => [
          %{"id" => "decision", "type" => "manual"},
          %{"id" => "materials", "type" => "manual"}
        ]
      },
      approval_timeout: nil
    }

    with {:ok, draft} <-
           WorkflowDefinition
           |> Ash.Changeset.for_create(:create, attrs, tenant: workspace_id, authorize?: false)
           |> Ash.create(tenant: workspace_id, authorize?: false),
         {:ok, published} <-
           draft
           |> Ash.Changeset.for_update(:publish, %{}, tenant: workspace_id, authorize?: false)
           |> Ash.update(tenant: workspace_id, authorize?: false) do
      {:ok, published}
    end
  end
end
