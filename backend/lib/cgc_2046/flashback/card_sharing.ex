defmodule Cgc2046.Flashback.CardSharing do
  @moduledoc """
  卡片分享开关（#771）：把一张档案卡的**实时保存数据**变成一条匿名可读链接。

  ## 身份（与读写面同构，绝不信客户端 person id）

  入口身份元组来自 GraphQL 层的 `flashback_identity/2`（token 优先、其次登录
  actor）——`{:token, 明文}` 经 `Tokens.fetch_valid/1` 解析出 person，
  `{:person, id}` 由服务端按 `user_id` 绑定关系查得。两者都**先在本模块复验
  档案存在且未删除**（`deleted_at` 置位者拒绝），再把服务端确认的 person 交给
  资源内部 action——person id 从不来自请求参数。

  ## 首次开启的并发纪律（行锁 + 唯一索引）

  分享标识**铸出即不可变**（关闭只清 `card_share_enabled_at`，重开复用同号，
  已投出的链接不换号）。两个并发的「首次开启」必须只铸一次：事务内
  `SELECT … FOR UPDATE` 锁住该行，锁内**重读最新行**再构造 changeset——
  后到者看到先到者已提交的 slug，`set_card_sharing` 的 change 因此不重铸。

  唯一索引 `flashback_people_unique_card_share_slug_index` 是最后防线：极端
  碰撞转 `flashback_card_share_conflict`，本模块重铸重试（有界）。

  ## 与授权档 / 公开 slug 无依赖

  分享独立成立：`quote_license` 未授权、`public_slug` 未发布、甚至
  `sent_to_wall_at` 为空（从未寄出）都不影响分享——分享的是「她此刻保存的
  数据」，不是墙上那张卡的副本。
  """

  require Ash.Query

  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Flashback.{Person, SharedCard, Tokens}
  alias Cgc2046.Repo

  # 铸号重试上限：48 字符 hex 的碰撞概率可忽略，上限只为「绝不无限循环」。
  @mint_attempts 3

  @doc """
  设置分享开关（幂等）：`enabled` 为 true 时首开铸号、其后保持同号；false 时
  只清 `card_share_enabled_at`（标识保留）。

  返回管理面状态：`%{enabled: boolean, share_id: String.t() | nil, preview: map}`。
  """
  @spec set(boolean(), {:token, String.t()} | {:person, String.t()}) ::
          {:ok, map()} | {:error, term()}
  def set(enabled, identity) when is_boolean(enabled) do
    with {:ok, person} <- resolve_person(identity) do
      activate(person, enabled, @mint_attempts)
    end
  end

  @doc """
  管理面状态（胶囊 `me.cardSharing`）：开关态 + 标识 + 本人预览。

  预览**独立于公开门**——关闭状态下也返回（本人要能看见自己会分享出什么）。
  """
  @spec state(String.t()) :: map()
  def state(person_id) do
    person =
      Person
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^person_id)
      |> Ash.read_one(authorize?: false)

    case person do
      {:ok, %Person{} = person} ->
        %{
          enabled: not is_nil(person.card_share_enabled_at),
          share_id: person.card_share_slug,
          preview: SharedCard.owner_preview(person.id)
        }

      _ ->
        %{enabled: false, share_id: nil, preview: nil}
    end
  end

  # ── 身份解析（服务端；拒绝缺失 / 已删除档案） ─────────────────────────

  defp resolve_person({:token, token}) do
    with {:ok, flashback_token} <- Tokens.fetch_valid(token),
         {:ok, person} <- fetch_live(flashback_token.person_id) do
      {:ok, person}
    end
  end

  defp resolve_person({:person, person_id}) when is_binary(person_id) do
    fetch_live(person_id)
  end

  defp resolve_person(_) do
    {:error,
     %{
       code: "flashback_auth_required",
       message: "token or sign-in required",
       reason: :auth_required
     }}
  end

  defp fetch_live(person_id) do
    case Person
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^person_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %Person{deleted_at: nil} = person} ->
        {:ok, person}

      {:ok, %Person{}} ->
        # 已删除档案（U10/R30）：token 与账号绑定都已断，此处是纵深防御的第二道闸。
        {:error,
         %{
           code: "flashback_person_not_found",
           message: "archive not found",
           reason: :not_found
         }}

      {:ok, nil} ->
        {:error,
         %{
           code: "flashback_person_not_found",
           message: "archive not found",
           reason: :not_found
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── 行锁下的开关写入 ─────────────────────────────────────────────────

  defp activate(person, enabled, attempts_left) do
    result =
      Repo.transaction(fn ->
        case lock_row(person.id) do
          {:ok, locked} ->
            case write(locked, enabled) do
              {:ok, updated} -> updated
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %Person{} = updated} ->
        {:ok, state_payload(updated)}

      {:error, %Ash.Error.Invalid{} = error} ->
        if attempts_left > 1 and card_share_conflict?(error) do
          activate(person, enabled, attempts_left - 1)
        else
          {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 事务内行锁 + 锁内重读：`FOR UPDATE` 读的是最新已提交行版本，故 stale
  # struct 在此无效化（同 curriculum/prep.ex 的 lock 协议纪律）。
  defp lock_row(person_id) do
    case Repo.query("SELECT id FROM flashback_people WHERE id = $1 FOR UPDATE", [
           Repo.uuid!(person_id)
         ]) do
      {:ok, %{num_rows: 1}} ->
        {:ok, Repo.reload!(%Person{id: person_id})}

      {:ok, %{num_rows: 0}} ->
        {:error,
         %{
           code: "flashback_person_not_found",
           message: "archive not found",
           reason: :not_found
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write(person, enabled) do
    person
    |> Ash.Changeset.for_update(:set_card_sharing, %{enabled: enabled})
    |> Ash.update(authorize?: false)
  end

  # 唯一索引冲突 → Person.handle_write_error 转 flashback_card_share_conflict
  # （Ash 把 error_handler 的 BusinessError 包进 %Ash.Error.Invalid{} 的叶子里）。
  defp card_share_conflict?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%BusinessError{code: "flashback_card_share_conflict"}, &1))
  end

  # 管理面状态直接从写后 struct 组装，预览另查（内容实时，不与开关同快照无妨——
  # 预览读的是本人档案行本身，不存在开关竞态）。
  defp state_payload(person) do
    %{
      enabled: not is_nil(person.card_share_enabled_at),
      share_id: person.card_share_slug,
      preview: SharedCard.owner_preview(person.id)
    }
  end
end
