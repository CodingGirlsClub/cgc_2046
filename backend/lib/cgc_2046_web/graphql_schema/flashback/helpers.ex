defmodule Cgc2046Web.GraphqlSchema.Flashback.Helpers do
  @moduledoc """
  闪念间（In a Flash）域内 resolver helper：身份解析（token / actor /
  anon 键）、flashback_call 信封、IP 提取、今日参数拍平与 id 校验；
  仅本域 notation 模块使用。
  """

  # 找回限流的 IP 提取（同 WebAuthFlow.remote_ip 口径；conn 由 plug 上下文携带）
  def context_ip(%{conn: %{remote_ip: ip}}), do: ip |> :inet.ntoa() |> to_string()
  def context_ip(_context), do: "unknown"

  # wish2 U6：登录 actor 的 user_id（未登录 nil——匿名 voter 走 a: 键）
  def actor_user_id(%{actor: %{id: id}}) when is_binary(id), do: id
  def actor_user_id(_context), do: nil

  # wish2 review HS-3：读面 viewer 双键集——登录 = 强制 u:<uid> + 入参 a: 键
  # （a: 入参与期待 mutation 的 anonVoterKey merge 语义对称，刷新不漂移）；
  # 未登录 = 入参单键（a: 设备键原样）。入参 u: 键仅未登录时透传（低危回显，
  # 登录时被 actor 键取代——不可借此窥探他人）。
  def viewer_voter_keys(context, arg_key) do
    case actor_user_id(context) do
      nil ->
        [arg_key]

      uid ->
        ["u:#{uid}" | [arg_key]]
    end
  end

  # voter_key 只在 a: 前缀时当 anon 键用（u: 由 actor_user_id 强制）
  def anon_key_from(nil), do: nil
  def anon_key_from("a:" <> _ = key), do: key
  def anon_key_from(_), do: nil

  # 闪念间写面双入口（U9/R28）：token 优先（首程/链接回访）；省略时按登录
  # actor 解析绑定的档案（person.user_id）。返回 {:token, t} | {:person, id}，
  # 与 capsule 读面的 resolve_person 同语义；两者皆无 → auth_required。
  # Wish authorship needs an account, not an archive. Other archive operations
  # deliberately keep flashback_identity's existing eligibility boundary.
  def wish_identity(token, %{actor: %{id: id}}) when token in [nil, ""], do: {:ok, {:user, id}}

  def wish_identity(token, context) do
    with {:ok, identity} <- flashback_identity(token, context),
         {:ok, id} <- identity_person_id(identity),
         do: {:ok, {:person, id}}
  end

  def flashback_identity(token, context) do
    cond do
      is_binary(token) and token != "" ->
        case Cgc2046.Flashback.Tokens.fetch_valid(token) do
          {:ok, _flashback_token} -> {:ok, {:token, token}}
          {:error, error} -> {:error, error}
        end

      not is_nil(context[:actor]) ->
        case Cgc2046.Flashback.AlumniProjection.resolve_person(nil, context[:actor]) do
          {:ok, %{person: person}} -> {:ok, {:person, person.id}}
          {:error, error} -> {:error, error}
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

  # 闪念间身份元组 → person_id（U9/U11 写面共用：redeem 等不需 person 结构的入口）。
  def identity_person_id({:token, token}) do
    case Cgc2046.Flashback.Tokens.fetch_valid(token) do
      {:ok, flashback_token} -> {:ok, flashback_token.person_id}
      {:error, error} -> {:error, error}
    end
  end

  def identity_person_id({:person, person_id}), do: {:ok, person_id}

  # wish2 U8/KTD1：signature_choice 字符串→atom（context opts 契约）；
  # 非法/缺省宽容降级 anonymous——旧客户端与拼写错误不因此拒绝整单
  def wish_signature_choice("display_name"), do: :display_name
  def wish_signature_choice(_), do: :anonymous

  # 闪念间手写 field 的统一错误映射：domain 信封原样透传（code 进 #241 契约）；
  # Ash 校验错误经 domain 的 invalid_input_error/1 包装；其余按 DB 故障兜底。
  def flashback_call(fun) do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      # wish2 U8/KTD11：city_unknown 信封带 candidates（≤3 候选城市）——
      # map 模式匹配需余字段容忍，candidates 保留在 extensions 供前端提示
      {:error, %{code: code, message: message} = envelope}
      when is_binary(code) and is_map(envelope) ->
        {:error, [message: message, code: code] ++ envelope_extra(envelope)}

      {:error, %Ash.Error.Invalid{errors: [first | _]}} ->
        envelope = Cgc2046.Flashback.Tokens.invalid_input_error(Exception.message(first))
        {:error, message: envelope.message, code: envelope.code}

      {:error, _other} ->
        {:error, message: "服务暂时不可用，请稍后重试。", code: "database_error"}
    end
  end

  # 信封余字段（如 city_unknown 的 candidates）→ keyword 附加项；
  # code/message 已显式消费，只透传非空名单类补充信息
  def envelope_extra(envelope) do
    case envelope[:candidates] || Map.get(envelope, :candidates) do
      candidates when is_list(candidates) and candidates != [] -> [candidates: candidates]
      _ -> []
    end
  end

  # 动员勾选拍平 → mobilization map（存储形状单一，前端不必拼 JSON）。
  def today_params(input) do
    %{
      now_status: Map.get(input, :now_status),
      want: Map.get(input, :want),
      need: Map.get(input, :need),
      say: Map.get(input, :say),
      want_give_tags: Map.get(input, :want_give_tags) || [],
      mobilization: %{
        "join_1024" => Map.get(input, :mobilization_join_1024) || false,
        "help_promote" => Map.get(input, :mobilization_help_promote) || false,
        "donate_intent" => Map.get(input, :mobilization_donate_intent) || false,
        "volunteer_lead" => Map.get(input, :mobilization_volunteer_lead) || false
      },
      newsletter_opt_in: Map.get(input, :newsletter_opt_in) || false,
      reconnect_tags: Map.get(input, :reconnect_tags) || []
    }
  end

  # id 入参形态校验（R36/R38）：Absinthe 的 :id 是 string，非法 uuid 直接进
  # Ecto.UUID.dump! 会抛；这里 fail-closed 成业务码（不泄露存在性）。
  def validate_like_person_id(person_id) when is_binary(person_id) do
    case Ecto.UUID.cast(person_id) do
      {:ok, uuid} ->
        {:ok, uuid}

      :error ->
        {:error,
         %{
           code: "flashback_quote_not_found",
           message: "quote not found",
           reason: :quote_not_found
         }}
    end
  end

  def validate_like_person_id(_) do
    {:error,
     %{code: "flashback_quote_not_found", message: "quote not found", reason: :quote_not_found}}
  end
end
