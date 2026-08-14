defmodule Cgc2046.Changes.Transition do
  @moduledoc """
  状态迁移守卫 change（PR-G；plan 2026-08-15-008 决策 D1-D7）。

  workflow_run 九个状态迁移 action 的声明式守卫 + checkpoint 终态清理配对：
  `status ∈ from` → `force_change :status = to`；否则 `add_error`（错误串逐字保持
  现有格式「cannot <verb> from status=<s>」，verb = action 名）。

  `to` 为终态且 `cleanup_checkpoint: true` 时挂 `after_transaction` 清理
  jido_checkpoints（收编 workflow_run 既有 cleanup_checkpoint helper 语义；宽松
  清理，失败记日志不阻塞状态流转——策略单源在 CheckpointLifecycle）。

  checkpoint 清理只在终态后无消费方时安全（ADR-0002：checkpoint 仅 waiting 挂起期
  有意义，hibernate 落、thaw 恢复；终态后无消费方）。非终态 `to`（start/wait/
  resume/start_run/resume_signal 的 transient running/waiting）一律
  `cleanup_checkpoint: false`/缺省——start_run/resume_signal 的执行闭环内部已由
  CheckpointLifecycle 收口 checkpoint 生命周期。

  用法（同 SignalEmitter 的 module+opts change 形态；opts 是编译期字面量）：

      change {Cgc2046.Changes.Transition, from: [:running, :waiting], to: :succeeded,
              cleanup_checkpoint: true}

  - `from`：允许的起始 status 列表（必填）。
  - `to`：目标 status（必填）。
  - `cleanup_checkpoint`：终态 `to` 时清理 checkpoint（默认 false）。
  """

  use Ash.Resource.Change

  alias Cgc2046.Workflows.CheckpointLifecycle

  @impl true
  def change(changeset, opts, _context) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    cleanup_checkpoint? = Keyword.get(opts, :cleanup_checkpoint, false)

    changeset =
      case Ash.Changeset.get_data(changeset, :status) do
        status ->
          if Enum.member?(from, status) do
            Ash.Changeset.force_change_attribute(changeset, :status, to)
          else
            Ash.Changeset.add_error(changeset, "cannot #{verb(changeset)} from status=#{status}")
          end
      end

    if cleanup_checkpoint? do
      Ash.Changeset.after_transaction(changeset, fn cs, result ->
        case result do
          {:ok, _record} -> cleanup_checkpoint(cs, to)
          _ -> :ok
        end

        result
      end)
    else
      changeset
    end
  end

  # 错误串 verb = action 名（「cannot <verb> from status=<s>」逐字保持现有格式；
  # action 缺失为编程错误，兜底不崩）。
  defp verb(%{action: %{name: name}}), do: to_string(name)
  defp verb(_changeset), do: "transition"

  # 终态清理 checkpoint（收编 workflow_run.cleanup_checkpoint 语义）：按 run id 删
  # checkpoint 行（幂等）；宽松，失败记日志不阻塞状态流转。策略单源在
  # CheckpointLifecycle（候选 #2）。
  defp cleanup_checkpoint(changeset, status) do
    run_id = Ash.Changeset.get_data(changeset, :id)
    partition = Ash.Changeset.get_data(changeset, :partition_id)

    if is_binary(run_id) and is_binary(partition) do
      :ok = CheckpointLifecycle.on_status(status, run_id, partition, nil)
    end

    :ok
  end
end
