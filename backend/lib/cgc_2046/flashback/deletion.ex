defmodule Cgc2046.Flashback.Deletion do
  @moduledoc """
  档案删除（U10/R30/KTD8，ADR-0015 房规：不可逆、二次确认、级联清单逐项核查）。

  ## 身份（与读写面同构）

  token（首程/链接回访——「token 有效期内免注册删除」，R30）或已绑定账号
  （capsule 回访正门）；与 `AlumniProjection.resolve_person/2` 同一解析。

  ## 二次确认

  `delete/2` 要求 `confirm == "DELETE"`——前端先展示删除摘要（capsule 数据：
  卡片/附议/回信现状），用户显式确认后才提交；错值 → `flashback_delete_confirm_required`
  （fail-closed，不静默吞）。

  ## 级联清单（KTD8 逐项；全部同事务，任一步失败整体回滚）

  1. **token 作废**：该人全部 token `revoked_at` 置位（链接失效）；
  2. **卡撤下 + 回信删除**：`flashback_todays` 行硬删（sent_to_wall_at 随行消失，
     名册回到无此人——见 9）；
  3. **附议删除**：`flashback_endorsements` 行硬删（卡的 endorsement_count 同步回落）；
  4. **金句授权删除**：`flashback_quote_licenses` 行硬删（金句墙与实名页即刻消失）；
  5. **公开 slug 下线**：`public_slug` / `public_slug_published_at` 清空（公开页 404；
     ADR-0014 的「发布后锁定」不挡删除——锁定防误改，删除是本人行使权利）；
  6. **outreach 个人字段匿名化**：`Outreach.Dispatch.anonymize_person/1`（U8 已落地；
     行保留承接 KTD10 分母聚合）；
  7. **当年答案删除**：`flashback_answers` 行硬删（PIPL 数据清除——原文含个人内容）；
  8. **账号解绑**：`user_id` 清空（会话腿自此 not_bound）；
  9. **`deleted_at` 置位**：名册/公开统计/找回匹配全面排除（R30「本人卡从墙上撤下」）。

  保留（非个人数据）：`flashback_touches`（四率聚合，无 PII）、`flashback_outreaches`
  发送状态行（匿名化后无个人字段）、退订状态（`outreach_unsubscribed_at`——
  删除者天然不可再触达，保留无害且防数据回灌）。

  ## 错误码（#241 契约）

  `flashback_delete_confirm_required` / `flashback_already_deleted` / 身份错误复用
  token 面三态与 `flashback_person_not_bound`。
  """

  require Ash.Query

  alias Cgc2046.Flashback.{
    Answer,
    Person,
    QuoteLicense,
    Today,
    Token,
    Tokens,
    Wish,
    WishComment,
    WishEndorsement
  }

  alias Cgc2046.Flashback.Outreach.Dispatch
  alias Cgc2046.Repo

  @confirm_word "DELETE"

  # ── 摘要（二次确认页的数据源；capsule 已含同款信息——此处供删除面复用） ──

  @doc """
  删除摘要：本人将失去什么（卡/附议数/寄出态）——强提示文案的依据。
  """
  @spec preview(map()) :: {:ok, map()}
  def preview(%{person: person}) do
    endorsement_count =
      WishEndorsement
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(person_id == ^person.id)
      |> Ash.count!(authorize?: false)

    sent_to_wall_at =
      case Today
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(person_id == ^person.id)
           |> Ash.read_one(authorize?: false) do
        {:ok, %Today{sent_to_wall_at: at}} when not is_nil(at) ->
          DateTime.to_iso8601(at)

        _ ->
          nil
      end

    {:ok,
     %{
       person_id: person.id,
       full_name: person.full_name,
       sent_to_wall_at: sent_to_wall_at,
       endorsement_count: endorsement_count,
       already_deleted: deleted?(person)
     }}
  end

  # ── 删除本体 ─────────────────────────────────────────────────────────

  @doc """
  删除档案（不可逆）：`confirm` 必须为 `"DELETE"`（二次确认，前端展示摘要后
  由用户显式输入/勾选产生）。级联清单见 moduledoc；同事务执行。
  """
  @spec delete(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete(%{person: person}, confirm) do
    with :ok <- check_confirm(confirm),
         # DB 最新态查重（调用方可能持旧 struct——重复删除幂等拒绝）
         person when is_struct(person, Person) <- Repo.reload!(person),
         :ok <- check_not_deleted(person) do
      Repo.transaction(fn -> cascade!(person) end)
      |> case do
        {:ok, %{deleted_at: deleted_at}} ->
          {:ok, %{deleted: true, deleted_at: DateTime.to_iso8601(deleted_at)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_confirm(@confirm_word), do: :ok

  defp check_confirm(_),
    do:
      {:error,
       %{
         code: "flashback_delete_confirm_required",
         message: "confirmation word is required to delete (type DELETE)",
         reason: :confirm_required
       }}

  defp deleted?(%Person{deleted_at: nil}), do: false
  defp deleted?(%Person{}), do: true

  defp check_not_deleted(%Person{} = person) do
    if deleted?(person) do
      {:error,
       %{
         code: "flashback_already_deleted",
         message: "archive already deleted",
         reason: :already_deleted
       }}
    else
      :ok
    end
  end

  # 级联（事务内，全部 authorize?: false——token/账号本人即授权）。
  defp cascade!(person) do
    person = Repo.reload!(person)

    # 1. token 作废（链接失效）
    Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person.id and is_nil(revoked_at))
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.each(fn token ->
      token
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:revoked_at, DateTime.utc_now())
      |> Ash.update!(authorize?: false)
    end)

    # 2. 回信删除（含寄出态）
    Today
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false, action: :destroy))

    # 3. 许愿三项（U8/KTD9）：本人许愿硬删（PIPL——含私有内容），其上的他人
    #    留言与附议随 wish 外键 on_delete 级联；本人在他人许愿上的留言/附议同删
    Wish
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false, action: :destroy))

    WishComment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false, action: :destroy))

    WishEndorsement
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false, action: :destroy))

    # 4. 金句授权删除
    QuoteLicense
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false, action: :destroy))

    # 6. outreach 个人字段匿名化（U8 能力；行保留承接分母聚合）
    :ok = Dispatch.anonymize_person(person.id)

    # 7. 当年答案删除（PIPL 数据清除）
    Answer
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false, action: :destroy))

    # 5/8/9. slug 下线 + 账号解绑 + deleted_at 置位（一次 update）
    deleted_at = DateTime.utc_now()

    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:deleted_at, deleted_at)
    |> Ash.Changeset.force_change_attribute(:user_id, nil)
    |> Ash.Changeset.force_change_attribute(:public_slug, nil)
    |> Ash.Changeset.force_change_attribute(:public_slug_published_at, nil)
    |> Ash.update!(authorize?: false)

    %{deleted_at: deleted_at}
  end

  # ── 身份解析（与 AlumniProjection.resolve_person 同构的删除面入口） ────

  @doc """
  token 或登录 actor → `%{person: Person}`（删除面身份；错误信封同 token 面）。
  """
  @spec resolve_identity(String.t() | nil, struct() | nil) ::
          {:ok, %{person: Person.t()}} | {:error, map()}
  def resolve_identity(token, actor) do
    cond do
      is_binary(token) and token != "" ->
        case Tokens.fetch_valid(token) do
          {:ok, flashback_token} -> {:ok, %{person: flashback_token.person}}
          {:error, error} -> {:error, error}
        end

      not is_nil(actor) ->
        case Person
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(user_id == ^actor.id)
             |> Ash.read_one(authorize?: false) do
          {:ok, %Person{} = person} ->
            {:ok, %{person: person}}

          _ ->
            {:error,
             %{
               code: "flashback_person_not_bound",
               message: "no archive bound",
               reason: :not_bound
             }}
        end

      true ->
        {:error,
         %{
           code: "flashback_auth_required",
           message: "token or sign-in required",
           reason: :auth_required
         }}
    end
  end
end
