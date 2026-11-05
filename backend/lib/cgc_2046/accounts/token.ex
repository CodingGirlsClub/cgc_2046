defmodule Cgc2046.Accounts.Token do
  @moduledoc """
  登录 JWT 的存储资源（TokenResource）。

  由 `AshAuthentication.TokenResource` 自动生成属性/动作，用于 token 撤销、
  `store_all_tokens?` 时的全量 token 存储等。表中行由 ash_authentication 内部管理。

  `:stored_for_subject` 是为 Phase 1 小程序策略重登吊销（按 subject 枚举活跃 token
  后逐个 `revoke_jti`）添加的内部读动作——仅 ash_authentication 私有 context 可达。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

  import Ash.Expr, only: [expr: 1]

  actions do
    # ash_authentication 4.15.1 起，`revoke_all_stored_for_subject` 改用
    # `Ash.bulk_update/4` 一次性吊销，需要 token 资源的 primary read 作为基础查询。
    # 这里必须是不带过滤的全量读：primary read 的过滤会成为吊销范围。外部读取
    # 仍被 policies 拒绝（除 ash_authentication 私有 context 的 bypass）。
    read :read do
      primary?(true)
      description("内部：ash_authentication 全量吊销构建基础查询，外部不可达")
    end

    read :stored_for_subject do
      description("内部：枚举某 subject 全部活跃（purpose=user）已存 token（重登吊销用）")

      argument(:subject, :string, allow_nil?: false, sensitive?: true)

      # M8：吊销按 platform 面过滤。nil = 不过滤（全量，user.ex 密码重置用）；
      # atom 经 extra_data->>'platform' 匹配（无 platform claim 的 token 归
      # web 面，由调用方传 :web 并用 SQL 表达式覆盖，见 stored_for_platform_expr）。
      argument(:platform, :atom, allow_nil?: true)

      prepare(fn query, _context ->
        platform = Ash.Query.get_argument(query, :platform)

        query
        |> filter_subject_and_purpose(Ash.Query.get_argument(query, :subject))
        |> filter_by_platform(platform)
      end)
    end
  end

  require Ash.Query

  defp filter_subject_and_purpose(query, subject) do
    Ash.Query.filter(query, subject == ^subject and purpose == "user")
  end

  defp filter_by_platform(query, nil), do: query

  # web 面 = extra_data 无 platform 键 OR = "web"（密码路径签发的 token 无
  # platform claim，advisor02 M8 裁决归入 web 面）。小程序面 = 精确匹配。
  defp filter_by_platform(query, :web) do
    platform = "web"

    Ash.Query.filter(
      query,
      expr(is_nil(fragment("extra_data->>'platform'"))) or
        expr(fragment("extra_data->>'platform'") == ^platform)
    )
  end

  defp filter_by_platform(query, platform) when is_atom(platform) do
    value = to_string(platform)

    Ash.Query.filter(
      query,
      expr(fragment("extra_data->>'platform'") == ^value)
    )
  end

  postgres do
    table("tokens")
    repo(Cgc2046.Repo)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end
  end

  admin do
    # #113 ops 面优化：导航分组
    resource_group(:accounts)
  end
end
