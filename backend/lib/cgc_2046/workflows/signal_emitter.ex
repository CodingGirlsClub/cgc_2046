defmodule Cgc2046.Workflows.SignalEmitter do
  @moduledoc """
  信号发布 change（异步链路深化 PR-A；plan 2026-08-14-003 决策 Q5/Q6/Q12/Q13/Q14）。

  四种历史发布形状（after_transaction 直发 fire-and-forget / after_action 手写入队）
  归一为「after_action change + 事务内 Oban outbox」：数据层成功后、事务提交前
  入队 `SignalPublishWorker` job——job 与实体终态同事务提交；入队失败 raise →
  事务回滚，action 整体失败可安全重试（幂等）。worker 异步投递失败经 Oban 重试
  （max_attempts 8），消费方经 SignalIdempotency 幂等去重。

  顺序语义：同一 action 成对入队的信号（如 create 自动确认时的
  submitted → completed）是 :maintenance 队列上的独立 job，Oban 并发执行不保证
  先后——completed 可能先于 submitted 投递（旧直发路径为同步有序）。当前订阅方
  彼此独立且幂等，乱序到达安全；若未来订阅方依赖顺序，须按 record 状态自决。

  用法（fn 须为 public 模块函数的远程捕获——Spark DSL 实体 opts 需可转义，
  匿名 fn 与私有捕获会在资源编译期报错，同 LogAdminAction 契约）：

      change {Cgc2046.Workflows.SignalEmitter,
        type: "enrollment.completed", payload: &__MODULE__.signal_payload/2}

  opts：

  - `type`：信号类型字符串（必填）。
  - `payload`：`fn changeset, record -> map`（必填，Q13），只组装业务键。
  - `skip_unless`：`fn changeset, record -> boolean`（可选）；返回 false 跳过
    入队（如 create 仅自动确认时才发 completed；与 LogAdminAction 同款谓词契约）。

  emitter 统一上收的 payload 规范（Q12，资源不再自拼）：

  - `"idempotency_key"` = `"<type>:<record_id>"`——仅缺省注入（payload fn
    自带幂等键时保留自带值，如 `offering.capacity_changed` 逐次唯一键）；
    缺省值与消费方既有派生回退（Notifications.Subscriber/SpeakerSubscriber
    的 `"<type>:<id>"` fallback）逐值一致，存量 claim 键不变；
  - `"workspace_id"` 取自 `record.workspace_id`（覆盖 payload fn 同名片段，
    规范唯一来源在 emitter）；
  - payload 键一律字符串（atom 键在 emitter 边界归一）。
  """

  use Ash.Resource.Change

  alias Cgc2046.Workflows.SignalPublishWorker

  @impl true
  def change(changeset, opts, _context) do
    type = Keyword.fetch!(opts, :type)
    payload_fn = Keyword.fetch!(opts, :payload)
    skip_unless = Keyword.get(opts, :skip_unless)

    Ash.Changeset.after_action(changeset, fn cs, record ->
      if is_function(skip_unless, 2) and not skip_unless.(cs, record) do
        {:ok, record}
      else
        payload =
          payload_fn.(cs, record)
          |> Map.new(fn {key, value} -> {to_string(key), value} end)
          |> Map.put_new("idempotency_key", type <> ":" <> record.id)
          |> Map.put("workspace_id", record.workspace_id)

        SignalPublishWorker.enqueue_in_transaction(type, payload, cs.tenant)
        {:ok, record}
      end
    end)
  end
end
