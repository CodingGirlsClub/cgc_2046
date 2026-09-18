defmodule Cgc2046.Accounts.Changes.LogAdminAction do
  @moduledoc """
  治理操作留痕挂接（#116 R10a 收口，7 处挂接点的统一注册表）。

  两种 interface 共用同一份 actor 提取 + `AdminActionLog.log/1` 调用，返回
  `{:ok, record} | {:error, _}`（fail-closed：调用方经 with 上抛，失败回滚治理操作）。

  声明式：作为 resource change 挂在治理 action 上（on_missing_actor 默认 :log）：
      change {Cgc2046.Accounts.Changes.LogAdminAction,
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
    invitation revoke 的条件谓词；治理写站点用 `platform_admin_actor?/2`）
  - `raise_on_failure?`：可选 boolean，默认 false。true = 留痕写入失败即上抛
    （`log!/3`，整事务回滚）；false = 返回型 `{:error, _}`（存量站点形状）
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
      if opts[:raise_on_failure?] do
        log!(changeset, record, opts)
      else
        log(changeset, record, opts)
      end
    end)
  end

  @doc """
  同事务落一条治理操作留痕（共享实现：actor 提取 + `AdminActionLog.log/1`）。
  无 actor 且 `on_missing_actor: :skip`、或 `skip_unless` 谓词不满足时不落行，
  返回 `{:ok, record}`。失败返回 `{:error, _}`。
  """
  def log(changeset, record, attrs) do
    case log_attrs(changeset, record, attrs) do
      :skip ->
        {:ok, record}

      {:log, log_attrs} ->
        with {:ok, _log} <- AdminActionLog.log(log_attrs), do: {:ok, record}
    end
  end

  @doc """
  `log/3` 的 raise 型：留痕写入失败即上抛（`AdminActionLog.log!/1`）。供「留痕失败
  ⇒ 整个治理写回滚」的站点使用——Ash 3.33 的 after_action 返回 `{:error, _}` 会
  **提交**事务（`transaction_rollback_on_error?` 未设），上抛是唯一能整事务回滚的
  形状（先例：`Cgc2046.Admission.Attendance` 核销即退的 `log_attendance_refund!/2`）。

  声明式挂接经 `raise_on_failure?: true` 走本路径；存量站点默认走返回型，行为零变化。
  跳过语义（`skip_unless` / `on_missing_actor: :skip`）与 `log/3` 完全一致。
  """
  def log!(changeset, record, attrs) do
    case log_attrs(changeset, record, attrs) do
      :skip ->
        {:ok, record}

      {:log, log_attrs} ->
        AdminActionLog.log!(log_attrs)
        {:ok, record}
    end
  end

  @doc """
  治理写留痕的 `skip_unless` 谓词：actor 是平台管理员才落行。

  工作台 Owner/Admin 的写、系统/CLI 与匿名调用一律跳过——工作台写的审计语义不
  因治理挂接而变（`AdminActionLog` 只覆盖平台治理操作）。
  """
  def platform_admin_actor?(changeset, _record) do
    changeset.context
    |> get_in([:private, :actor])
    |> Cgc2046.Accounts.Policies.PlatformAdmin.platform_admin?()
  end

  # 留痕跳过判定 + attrs 归一的唯一实现：log/3 与 log!/3 的分叉只在写入调用本身
  defp log_attrs(changeset, record, attrs) do
    actor = get_in(changeset.context, [:private, :actor])

    cond do
      not is_nil(attrs[:skip_unless]) and not attrs[:skip_unless].(changeset, record) ->
        :skip

      is_nil(actor) and attrs[:on_missing_actor] == :skip ->
        :skip

      true ->
        {:log,
         %{
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
         }}
    end
  end

  @doc """
  Initiative 规则审计元数据（issue #587：记规则值前后）。

  四项规则的值本身非敏感（押金金额 / 年龄门槛 / 成班阈值 / 截止小时数），
  落库即资金与治理设置的取证面——只记当前值会让「客诉复盘」无从下手。
  `value_before` 取 changeset 原值（`:create` 时 nil），`value_after` 取落库
  记录值。

  `metadata` 经 `/admin/audit` 读面（`listAdminActionLogs.metadata`）**白名单投影**后
  出门（#607）：投影表在 `Cgc2046Web.GraphqlSchema` 顶部（`@admin_action_metadata_whitelist`
  / `@rule_value_whitelist`）。本处写键时必须同步核对该表——**未收录的键不会出现在读面**；
  `value_before` / `value_after` 这类自由 map 另受二级白名单约束，被省略的键由读面
  以 `value_*_omitted` 标出（不静默截断）。
  """
  def initiative_rule_metadata(changeset, rule) do
    %{
      initiative_id: rule.initiative_id,
      rule_key: to_string(rule.key),
      locked: rule.locked,
      locked_before: locked_before(changeset),
      value_before: value_before(changeset),
      value_after: rule.value
    }
  end

  # offering 治理 update 的闭集标量（U1/KTD2）：标题 / 可见性 / 容量 / 定价槽位 /
  # 押金槽位。**只有这些**进 metadata——description / venue / price_tiers /
  # curriculum_requirements 等自由文本与结构体一律不落（审计面不收自由文本）。
  # deposit_enabled 是 Event-only 属性：Course changeset 上 `changing_attribute?/2`
  # 查的是 attributes map，恒 false，不会落键。
  @offering_change_scalars [:title, :visibility, :capacity, :pricing_enabled, :deposit_enabled]

  @doc """
  offering 治理 update 的审计元数据（读面 `adminActionLog.offeringChange` 投影的来源；
  白名单表在 `Cgc2046Web.GraphqlSchema` 顶部 `@admin_offering_change_metadata_whitelist`）。

  只记**闭集标量**的变更前后值（`<field>_before` / `<field>_after`）：属性未变更不落键，
  读面据此只渲染真正变了的列；自由文本与结构体属性（description / venue / …）不进 metadata。
  """
  def offering_change_metadata(changeset, record) do
    Enum.reduce(@offering_change_scalars, %{}, fn key, acc ->
      if Ash.Changeset.changing_attribute?(changeset, key) do
        acc
        |> Map.put(:"#{key}_before", Ash.Changeset.get_data(changeset, key))
        |> Map.put(:"#{key}_after", Map.get(record, key))
      else
        acc
      end
    end)
  end

  defp value_before(%{action_type: :create}), do: nil
  defp value_before(changeset), do: Ash.Changeset.get_data(changeset, :value)

  defp locked_before(%{action_type: :create}), do: nil
  defp locked_before(changeset), do: Ash.Changeset.get_data(changeset, :locked)

  defp resolve(value, changeset, record) when is_function(value, 2) do
    value.(changeset, record)
  end

  defp resolve(value, _changeset, _record), do: value
end
