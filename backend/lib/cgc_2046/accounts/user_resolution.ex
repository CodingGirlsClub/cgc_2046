defmodule Cgc2046.Accounts.UserResolution do
  @moduledoc """
  三锚点用户解析单源（#537）：email 精确 / `CGC-XXXXXX` 编号前缀（大小写
  不敏感）/ UUID 精确，返回唯一 User。消费方：主理人指派
  （`Events.Moderators.assign` 的 `userId` 参数）；MCP 工具放宽（#539）复用
  同一单源。

  防枚举口径：任一锚未命中统一 `user_not_found`（不区分锚类型）——名录泄露
  的本质是可枚举，精确匹配不可枚举，与既有「用户不存在」错误反馈的信息
  增益完全等价。唯一例外：CGC 前缀命中多行（前缀冲突，概率 16⁻⁶ 量级）报
  `user_anchor_ambiguous` 引导改用用户 ID——歧义是可操作错误，伪装成
  「不存在」会让用户换锚也永远无法成功。

  读取内部 `authorize?: false`（User read policy 默认 only_me 会滤空），
  鉴权由调用方在解析前完成（`Moderators.assign` 的权限门先于本函数）。
  """

  require Ash.Query

  alias Cgc2046.Accounts.User
  alias Cgc2046.Errors.BusinessError

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  # 编号定长 6 位 hex；多输位数 = 更长前缀（歧义自救）。上限 32 = uuid 去
  # 连字符长度，更长必然无命中。hex 字符集天然不含 % 与 _，LIKE 拼接无
  # 通配注入面；非法格式不进 SQL 分支，直接落「用户不存在」。
  @cgc_prefix_regex ~r/\Acgc-(.+)\z/i
  @cgc_hex_regex ~r/\A[0-9a-fA-F]{6,32}\z/

  @doc """
  按锚解析唯一用户：

      {:ok, user} = resolve("a@b.example")
      {:ok, user} = resolve("cgc-ab12cd")
      {:ok, user} = resolve("00000000-0000-4000-8000-000000000000")

  未命中（任一锚）/ 非法格式 → `{:error, user_not_found}`；CGC 前缀命中
  多行 → `{:error, user_anchor_ambiguous}`；DB 读失败原样透传（瞬断可
  重试，不伪装成「用户不存在」）。
  """
  @spec resolve(term()) :: {:ok, User.t()} | {:error, term()}
  def resolve(anchor) when is_binary(anchor) do
    cond do
      String.contains?(anchor, "@") -> by_email(anchor)
      uuid?(anchor) -> by_uuid(anchor)
      cgc_hex = cgc_hex(anchor) -> by_member_number_prefix(cgc_hex)
      true -> not_found()
    end
  end

  # Ash ci_string 加载后是 %Ash.CiString{}（如调用方直传 user.email），
  # 归一成 binary 再分流
  def resolve(%Ash.CiString{} = ci), do: resolve(to_string(ci))

  def resolve(_), do: not_found()

  # users.email 为 citext：等值比较天然大小写不敏感（与登录同口径）；
  # identity unique_email 保证至多一行，手机注册用户 email=nil 不会命中。
  defp by_email(email) do
    case User |> Ash.Query.filter(email == ^email) |> Ash.read(authorize?: false) do
      {:ok, [user]} -> {:ok, user}
      {:ok, []} -> not_found()
      {:error, _} = error -> error
    end
  end

  defp by_uuid(uuid) do
    case Ash.get(User, String.downcase(uuid), authorize?: false, not_found_error?: false) do
      {:ok, nil} -> not_found()
      {:ok, user} -> {:ok, user}
      {:error, _} = error -> error
    end
  end

  defp by_member_number_prefix(hex) do
    prefix = String.upcase(hex) <> "%"

    User
    |> Ash.Query.filter(fragment("upper(replace(id::text, '-', '')) LIKE ?", ^prefix))
    |> Ash.Query.limit(2)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [user]} -> {:ok, user}
      {:ok, [_ | _]} -> ambiguous()
      {:ok, []} -> not_found()
      {:error, _} = error -> error
    end
  end

  defp uuid?(anchor), do: Regex.match?(@uuid_regex, anchor)

  # 剥 CGC- 前缀（大小写不敏感）后校验 hex 形状；不合法返回 nil 落统一未命中
  defp cgc_hex(anchor) do
    case Regex.run(@cgc_prefix_regex, anchor) do
      [_, hex] -> if Regex.match?(@cgc_hex_regex, hex), do: hex
      nil -> nil
    end
  end

  defp not_found do
    {:error, BusinessError.exception(message: "user not found", code: "user_not_found")}
  end

  defp ambiguous do
    {:error,
     BusinessError.exception(
       message: "this CGC number prefix matches multiple users; use the user ID instead",
       code: "user_anchor_ambiguous"
     )}
  end
end
