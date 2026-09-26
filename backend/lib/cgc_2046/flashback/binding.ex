defmodule Cgc2046.Flashback.Binding do
  @moduledoc """
  把闪念间档案绑到账号的唯一入口：web 收好（`Tokens.register_bind/4`）、小程序一键收好与登录后
  自动匹配（`Tokens.claim_for_user/2`）、自助找回（`Recover`）都走这里。

  - **不悄悄挪**：档案已属于另一个账号 → `flashback_recover_account_conflict`（#932 起的规则，
    2026-09-26 推广到全部绑定路径）；同一账号重复绑定照旧成功。转移只能由原账号或运营处理。
  - **绑定即作废全部链接**（R1）：档案名下所有未用的链接 token 一并置 claimed。邀请分邮件 / 短信
    两路、找回邮件各会留一条有效链接——只作废用到的那条，别人拿另一条还能再走「收好」。
  - **防并发**：写入带条件（档案仍无主或已属本账号），检查之后被别人抢先绑定时整批回滚、报冲突。
  """

  import Ash.Expr, only: [expr: 1]
  require Ash.Query

  alias Cgc2046.Accounts.User
  alias Cgc2046.Flashback.{Person, Token}
  alias Cgc2046.Repo

  @doc "绑定一份或多份档案到账号：全部成功，或全部不动。"
  @spec bind(Person.t() | [Person.t()], map()) :: :ok | {:error, map()}
  def bind(people, %{id: user_id}) do
    case Repo.transaction(fn -> people |> List.wrap() |> Enum.each(&bind_one(&1, user_id)) end) do
      {:ok, _} -> :ok
      # 写入条件不满足（已属于别的账号，含并发下被抢先绑定）：Ash 以带 StaleRecord 的 changeset 回滚整批
      {:error, error} -> {:error, if(stale?(error), do: conflict_error(), else: error)}
    end
  end

  @doc """
  按号码建账号 / 登录之前判断归属（web 收好、手机找回）：号码对应的账号还不存在时，任何已有主的
  档案都算冲突。调用方须先验证过号码（验证码通过），否则冲突与否会变成试探主人号码的探针。
  """
  @spec check_for_phone([Person.t()], String.t()) :: :ok | {:error, map()}
  def check_for_phone(people, phone) do
    owner = User |> Ash.Query.filter(phone == ^phone) |> Ash.read_one!(authorize?: false)
    check(people, owner && owner.id)
  end

  @doc false
  def conflict_error do
    %{
      code: "flashback_recover_account_conflict",
      message: "This phone or archive already belongs to another account",
      reason: :account_conflict
    }
  end

  defp check(people, user_id) do
    if Enum.any?(people, &(&1.user_id && &1.user_id != user_id)),
      do: {:error, conflict_error()},
      else: :ok
  end

  # 在事务内执行：写入带「仍无主或已属本账号」条件，失败即回滚整批
  defp bind_one(person, user_id) do
    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.filter(expr(is_nil(user_id) or user_id == ^user_id))
    |> Ash.Changeset.force_change_attribute(:user_id, user_id)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} -> claim_tokens(person.id, user_id)
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  defp stale?(_), do: false

  defp claim_tokens(person_id, user_id) do
    now = DateTime.utc_now()

    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person_id and is_nil(claimed_by_user_id))
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn token ->
      token
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:claimed_by_user_id, user_id)
      |> Ash.Changeset.force_change_attribute(:claimed_at, now)
      |> Ash.update!(authorize?: false)
    end)
  end
end
