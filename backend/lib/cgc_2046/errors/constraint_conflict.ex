defmodule Cgc2046.Errors.ConstraintConflict do
  @moduledoc """
  Ash 错误「是否某类 DB 约束冲突」的单源判据。

  各资源的 `error_handler` 用它把约束冲突（唯一索引 / CHECK）转稳定业务错误，
  其余错误原样上抛——判据是安全敏感的 fail-closed 开关：漏判即把 DB 真故障
  吞成业务错误（静默数据丢失），误判即把可重试冲突当成硬失败。

  判据只认 `Ash.Error.Changes.InvalidAttribute.private_vars.constraint_type`
  （ash_postgres 映射 Ecto `unique_constraint` / `check_constraint` 时写入）；
  DB 断连等真实故障不含该键，故一律 false。
  """

  @leaf Ash.Error.Changes.InvalidAttribute

  @spec unique_conflict?(term) :: boolean
  def unique_conflict?(error), do: constraint_conflict?(error, :unique)

  @spec check_conflict?(term) :: boolean
  def check_conflict?(error), do: constraint_conflict?(error, :check)

  @spec constraint_conflict?(term, :unique | :check) :: boolean
  def constraint_conflict?(%{errors: errors}, type) when is_list(errors),
    do: Enum.any?(errors, &constraint_conflict?(&1, type))

  def constraint_conflict?(%@leaf{private_vars: private_vars}, type),
    do: Keyword.get(private_vars || [], :constraint_type) == type

  def constraint_conflict?(_error, _type), do: false

  @doc """
  冲突 leaf 是否由指定约束名触发（`private_vars.constraint`，ash_postgres 写入）。

  与 `constraint_conflict?/2` 合用可分辨「同一类型下的不同索引」。
  """
  @spec constraint_named?(term, String.t()) :: boolean
  def constraint_named?(%{errors: errors}, name) when is_list(errors),
    do: Enum.any?(errors, &constraint_named?(&1, name))

  def constraint_named?(%@leaf{private_vars: private_vars}, name),
    do: Keyword.get(private_vars || [], :constraint) == name

  def constraint_named?(_error, _name), do: false
end
