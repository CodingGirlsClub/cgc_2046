defmodule Cgc2046.Accounts.OAuthAuthorizations do
  @moduledoc """
  用户级 OAuth 授权读模型与撤销入口（U5，KTD3；只消费 U3 的三张表，不重构资源）。

  「已授权应用」列表 = 本人名下 **同意行（`OAuthConsent`）∪ 刷新令牌链头
  （`OAuthRefreshToken` 中 `rotated_to_id` 为空的行）** 按 client 去重。两个来源
  各覆盖一半事实：

  - **同意行**：授权时间（`granted_at`）与「已同意但尚未换得凭证」的中间态
    （宿主回调端口占用/进程中断后重试，见 U2 ②）。
  - **链头**：活跃性与最近使用（`last_used_at` 由 U3 的鉴权回查触碰，与
    `Mcp.Token.last_used_at` 同源语义，供首公里「已连接」判定）。

  链头 = 每条轮换链一行（轮换出的旧行 `rotated_to_id` 非空，不参与列表与判定），
  故读取量与该用户的历史授权条数同阶，不随刷新次数增长。

  ## 状态派生（与 `OAuthRefreshToken.verify_live/1` 同口径）

  | 状态 | 条件 |
  |---|---|
  | `:active` | 存在未撤销且未过期的链头（= 该授权当前可用） |
  | `:idle_expired` | 有链头、无活跃行、且不是全部已撤销（连续闲置超过滚动窗口） |
  | `:revoked` | 有链头且全部已撤销 |
  | `:pending` | 仅同意行、无链头（已同意、尚未换得凭证） |

  ## 撤销（仅本人）

  `revoke/2` = 整链撤销（`OAuthRefreshToken.revoke_authorization/2`，R11 的即时
  失效语义，下一次调用即 401）+ **撤回同意行**。第二段是必要的：库的
  `/oauth/authorize` 命中同意行即直接发码、不再展示授权页，仅撤凭证不撤同意就等于
  被撤销的宿主仍可在无用户交互下静默重新授权——与 U4 同意页「可随时撤销此授权」的
  承诺及 KTD6 的共用电脑纪律相悖。撤回后重新授权走完整同意页。

  越权与不存在一律塌缩为 `:not_found`（不泄露存在性，同 `Mcp.Token.revoke/2`）：
  他人的 client 与不存在的 client 同形。
  """

  require Ash.Query

  alias Cgc2046.Accounts.{OAuthClient, OAuthConsent, OAuthRefreshToken}

  # 纪元哨兵：排序时把无授权时间的审计行（同意已撤回、链头仍存）排到最后
  @epoch ~U[1970-01-01 00:00:00Z]

  @typedoc "授权状态（派生自令牌链与同意行；序列化经 GraphQL `status: String`）"
  @type status :: :active | :idle_expired | :revoked | :pending

  @typedoc """
  一条授权（按 client 去重）：

  - `client_name` 允许为 nil（client 行缺失时前端降级展示）
  - `granted_at` 允许为 nil（同意行已撤回但链头仍在的审计行——web 撤销后的回看）
  - `scope` 恒非 nil（同意行或链头至少一方存在，二者都带 scope）
  """
  @type entry :: %{
          client_id: String.t(),
          client_name: String.t() | nil,
          scope: String.t(),
          granted_at: DateTime.t() | nil,
          last_used_at: DateTime.t() | nil,
          status: status()
        }

  @doc """
  列出当前用户的授权（新→旧：按授权时间，nil 排最后）。

  只返回本人（显式 `user_id` 过滤 + `authorize?: false`——`OAuthConsent` 与
  `OAuthRefreshToken` 的 policy 面只对协议路径开放，读模型走显式过滤，同
  `OAuthRefreshToken.revoke_authorization/2` 的纪律）。
  """
  @spec list_for(Cgc2046.Accounts.User.t()) :: {:ok, [entry()]} | {:error, term()}
  def list_for(%{id: user_id}) when is_binary(user_id) do
    with {:ok, consents} <- read_consents(user_id),
         {:ok, heads} <- read_chain_heads(user_id),
         {:ok, clients} <- read_clients(consents, heads) do
      by_client = Enum.group_by(heads, & &1.client_id)
      consent_by_client = Map.new(consents, &{&1.client_id, &1})
      names = Map.new(clients, &{&1.id, &1.client_name})

      entries =
        (Map.keys(by_client) ++ Map.keys(consent_by_client))
        |> Enum.uniq()
        |> Enum.map(fn client_id ->
          build_entry(
            client_id,
            Map.get(consent_by_client, client_id),
            Map.get(by_client, client_id, []),
            Map.get(names, client_id),
            DateTime.utc_now()
          )
        end)
        |> Enum.sort_by(&(&1.granted_at || @epoch), {:desc, DateTime})

      {:ok, entries}
    end
  end

  def list_for(_actor), do: {:error, :unauthorized}

  @doc """
  撤销一条授权（仅本人）：整链撤销 + 撤回同意行。

  - 本人且存在 → `{:ok, entry}`（`status: :revoked` 的回执；列表侧该行在
    撤回同意后仍以链头呈现，供审计回看）
  - 他人的 client / 不存在的 client / 非本人 → `{:error, :not_found}`
  - 撤销动作本身失败 → `{:error, {:invalid, error}}`
  """
  @spec revoke(Cgc2046.Accounts.User.t(), String.t()) ::
          {:ok, entry()} | {:error, :not_found} | {:error, {:invalid, term()}}
  def revoke(%{id: user_id}, client_id)
      when is_binary(user_id) and is_binary(client_id) do
    # 收窄读：只取该 (user, client) 的同意行与链头（原实现经 list_for 读该用户
    # 全量再 Enum.find）。not_found 语义不变：两侧皆无即 not_found（他人 client
    # 与不存在同形），存在时才再取 client 名。
    with {:ok, consent} <- find_consent(user_id, client_id),
         {:ok, heads} <- read_client_chain_heads(user_id, client_id),
         :ok <- ensure_exists(consent, heads),
         {:ok, client_name} <- read_client_name(client_id) do
      do_revoke(user_id, client_id, consent, heads, client_name)
    else
      :not_found -> {:error, :not_found}
      {:error, error} -> {:error, {:invalid, error}}
    end
  end

  def revoke(_actor, _client_id), do: {:error, :not_found}

  defp ensure_exists(nil, []), do: :not_found
  defp ensure_exists(_consent, _heads), do: :ok

  defp do_revoke(user_id, client_id, consent, heads, client_name) do
    entry = build_entry(client_id, consent, heads, client_name, DateTime.utc_now())

    with :ok <- OAuthRefreshToken.revoke_authorization(user_id, client_id),
         :ok <- withdraw_consent(consent) do
      {:ok, %{entry | status: :revoked}}
    else
      {:error, error} -> {:error, {:invalid, error}}
    end
  end

  # 同意行撤回：撤销后重新授权必须重新过同意页（本模块 @moduledoc 的语义）。
  # 无同意行（链头独存的历史行）视为已达成目标，幂等成功。
  defp withdraw_consent(nil), do: :ok
  defp withdraw_consent(consent), do: destroy_consent(consent)

  defp destroy_consent(consent) do
    case Ash.destroy(consent, authorize?: false) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp read_consents(user_id) do
    OAuthConsent
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read(authorize?: false)
  end

  # 链头 = 未轮换出的当前行（每条轮换链一行）
  defp read_chain_heads(user_id) do
    OAuthRefreshToken
    |> Ash.Query.filter(user_id == ^user_id and is_nil(rotated_to_id))
    |> Ash.read(authorize?: false)
  end

  defp read_clients([], []), do: {:ok, []}

  defp read_clients(consents, heads) do
    client_ids =
      (Enum.map(consents, & &1.client_id) ++ Enum.map(heads, & &1.client_id))
      |> Enum.uniq()

    OAuthClient
    |> Ash.Query.filter(id in ^client_ids)
    |> Ash.read(authorize?: false)
  end

  defp find_consent(user_id, client_id) do
    OAuthConsent
    |> Ash.Query.filter(user_id == ^user_id and client_id == ^client_id)
    |> Ash.read_one(authorize?: false)
  end

  # 撤销路径的收窄读：只取该 client 的链头（列表路径仍走全量 read_chain_heads/1）
  defp read_client_chain_heads(user_id, client_id) do
    OAuthRefreshToken
    |> Ash.Query.filter(user_id == ^user_id and client_id == ^client_id and is_nil(rotated_to_id))
    |> Ash.read(authorize?: false)
  end

  defp read_client_name(client_id) do
    case OAuthClient |> Ash.Query.filter(id == ^client_id) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:ok, nil}
      {:ok, row} -> {:ok, row.client_name}
      {:error, error} -> {:error, error}
    end
  end

  defp build_entry(client_id, consent, heads, client_name, now) do
    %{
      client_id: client_id,
      client_name: client_name,
      scope: (consent && consent.scope) || scope_of(heads),
      granted_at: consent && consent.granted_at,
      last_used_at: latest_last_used(heads),
      status: status(heads, now)
    }
  end

  defp scope_of(heads) do
    case List.first(heads) do
      nil -> nil
      row -> row.scope
    end
  end

  defp latest_last_used(heads) do
    heads
    |> Enum.map(& &1.last_used_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      dates -> Enum.max(dates, DateTime)
    end
  end

  defp status([], _now), do: :pending

  defp status(heads, now) do
    cond do
      Enum.any?(heads, &OAuthRefreshToken.live?(&1, now)) -> :active
      Enum.all?(heads, &(&1.revoked_at != nil)) -> :revoked
      true -> :idle_expired
    end
  end
end
