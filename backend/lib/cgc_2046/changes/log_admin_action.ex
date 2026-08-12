defmodule Cgc2046.Changes.LogAdminAction do
  @moduledoc """
  治理操作留痕挂接（#116 R10a 收口，7 处挂接点的统一注册表）。

  两种 interface 共用同一份 actor 提取 + `AdminActionLog.log/1` 调用，返回
  `{:ok, record} | {:error, _}`（fail-closed：调用方经 with 上抛，失败回滚治理操作）。

  声明式：作为 resource change 挂在治理 action 上（on_missing_actor 默认 :log）：
      change {Cgc2046.Changes.LogAdminAction,
        action: :admin_demote,
        target_type: :user,
        # fn 须为 public 远程捕获（匿名 fn 无法被 DSL 实体转义，见文末注意）
        metadata: &__MODULE__.user_log_metadata/2}
  change/3 回调内用 `Ash.Changeset.after_action/2` 挂实现——Ash 的 after_action
  按声明顺序执行（run_after_actions 的 Enum.reduce_while 列表序），声明位置与原
  手写 after_action 保持相同相对顺序即可。

  函数式：嵌在 with 链里的站点直接调 `log/3`，保持一步形态：
      with {:ok, _log} <- LogAdminAction.log(changeset, record, %{...}) do ...

  opts / attrs：
  - `action`：atom 或 fn changeset, record -> atom（站点 set_platform_admin 用函数
    形式从 argument 算出 promote/demote）
  - `target_type`：atom 或 fn changeset, record -> atom（与 action/target_id/metadata
    同一「raw 或 fn/2」契约）
  - `target_id`：fn changeset, record -> uuid（默认取 record.id；函数式传裸 uuid 亦可，
    站点 invitation revoke 用 fn 取 invitation.workspace_id）
  - `metadata`：fn changeset, record -> map（默认 %{}；函数式传裸 map 亦可）
  - `skip_unless`：可选 fn changeset, record -> boolean，false 时不落行（站点
    invitation revoke 的条件谓词）
  - `on_missing_actor`：:log | :skip，默认 :log（CLI 无 actor 时 actor_id 落 nil
    仍留痕）；:skip = 无 actor 时不落行（workspace create 双记防护）

  注意：fn 形式 opts 须传 public 模块函数的远程捕获（如 `&__MODULE__.foo/2`）——
  Spark DSL 实体 opts 需可转义，匿名 fn 与私有函数捕获都会在资源编译期报错。
  """
  use Ash.Resource.Change

  alias Cgc2046.Accounts.AdminActionLog

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      log(changeset, record, opts)
    end)
  end

  @doc """
  同事务落一条治理操作留痕（共享实现：actor 提取 + `AdminActionLog.log/1`）。
  无 actor 且 `on_missing_actor: :skip`、或 `skip_unless` 谓词不满足时不落行，
  返回 `{:ok, record}`。失败返回 `{:error, _}`。
  """
  def log(changeset, record, attrs) do
    actor = get_in(changeset.context, [:private, :actor])

    cond do
      not is_nil(attrs[:skip_unless]) and not attrs[:skip_unless].(changeset, record) ->
        {:ok, record}

      is_nil(actor) and attrs[:on_missing_actor] == :skip ->
        {:ok, record}

      true ->
        with {:ok, _log} <-
               AdminActionLog.log(%{
                 actor_id: actor && actor.id,
                 action: resolve(attrs[:action], changeset, record),
                 target_type: resolve(attrs[:target_type], changeset, record),
                 target_id:
                   resolve(
                     attrs[:target_id] || fn _changeset, record -> record.id end,
                     changeset,
                     record
                   ),
                 metadata: resolve(attrs[:metadata] || %{}, changeset, record)
               }) do
          {:ok, record}
        end
    end
  end

  defp resolve(value, changeset, record) when is_function(value, 2) do
    value.(changeset, record)
  end

  defp resolve(value, _changeset, _record), do: value
end
