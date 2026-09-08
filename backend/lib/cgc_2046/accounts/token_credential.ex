defmodule Cgc2046.Accounts.TokenCredential do
  @moduledoc """
  「token 即凭据」定位组合子（PR-E D4；2026-09-08 架构评审候选③自
  `Cgc2046Web.GraphqlSchema` 抽离）：sha256(hex lower) 哈希 → `token_hash`
  精确匹配 → `read_one(authorize?: false)`（不走 read policy——token 持有者
  非成员，read policy 不适用）。

  token 空/非 binary 或未命中任何记录 → `{:error, :invalid_token}`（nil 塌缩，
  不泄露存在性）；真实读错误原样上抛（调用方需区分 invalid_token 与真实错误）。
  `extra_filter` 追加双因子（accept_invitation 的 `[id: id]`）。

  消费方：`acceptInvitation`（流①，Accounts.Invitation）/
  `SpeakerInvitation.decide/3`（流②，Events.SpeakerInvitation）。

  哈希实现单源：同款 sha256 hex lower 曾有三份拷贝（schema credential_hash /
  `SpeakerInvitation.hash_token/1` / Invitation create change 内联），收敛于此。
  """

  @doc "token → sha256 hex lower 哈希；空/非 binary → `{:error, :invalid_token}`。"
  @spec hash(term()) :: {:ok, String.t()} | {:error, :invalid_token}
  def hash(token) when is_binary(token) and token != "" do
    {:ok, :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
  end

  def hash(_), do: {:error, :invalid_token}

  @doc "按 token_hash 定位持 token 资源（可追加 extra_filter 双因子）。"
  @spec fetch(module(), term(), keyword() | :none) :: {:ok, term()} | {:error, term()}
  def fetch(resource, token, extra_filter \\ :none) do
    with {:ok, hash} <- hash(token) do
      filters = if extra_filter == :none, do: [], else: extra_filter

      resource
      |> Ash.Query.do_filter(filters ++ [token_hash: hash])
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, nil} -> {:error, :invalid_token}
        result -> result
      end
    end
  end
end
