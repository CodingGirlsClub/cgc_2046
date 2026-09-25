defmodule Cgc2046Web.GraphqlSchema.Helpers do
  @moduledoc """
  GraphQL schema 跨域共享的 resolver helper：actor 门控、Ash 错误映射、input 投影。
  由 `Cgc2046Web.GraphqlSchema` 与各域 notation 模块（如 `GraphqlSchema.Recruitment`）import 使用。
  """

  require Logger

  alias Cgc2046.AdminList

  # 未登录统一错误形状（message + code），供 me / update_profile / set_ui_theme
  # 的 actor nil 分支复用——与 sign_in 的 keyword list 错误走同一序列化路径。
  def unauthorized_error, do: [message: "unauthorized", code: "unauthorized"]

  # Ash action 错误 → AshGraphql.Error 结构化顶层 error（message/code/fields）。
  # 复用 AshGraphql.Errors.to_errors（自动生成 mutation 同款映射），与 sign_up 的
  # 错误协议一致；只取最小形状字段，避免 vars/short_message 等内部字段进响应。
  # domain 默认 Accounts（历史调用方均属此域）；其它域的资源（如 Cgc2046.Mcp.Token）须显式传入。
  def to_ash_graphql_errors(
        error,
        context,
        action,
        resource \\ Cgc2046.Accounts.User,
        domain \\ Cgc2046.Accounts
      ) do
    error
    |> AshGraphql.Errors.to_errors(context, domain, resource, action)
    |> Enum.map(fn mapped ->
      mapped
      |> Map.take([:message, :code])
      |> Map.put(:fields, format_error_fields(mapped[:fields]))
    end)
  end

  # `MutationError.fields` 是 SDL 的 `[String!]`；域层 fields 允许两种形态：
  # 裸字段名（atom，如 `:pricing_enabled`）与 `{字段名, 值}`（如
  # `event_id: <uuid>`，见 RuleInheritance.pricing_conflict_error/1）。值可能是
  # 裸 SQL 行里的原始 16 字节 UUID（非 canonical 字符串），直接进 `[String!]`
  # 会在 Absinthe 序列化处炸，故统一规范化成 `name` / `name=value` 字符串
  # （#595 D4a：fields 语义 = name=value，前端按 `event_id=<uuid>` 反查挂载场）。
  defp format_error_fields(nil), do: []

  defp format_error_fields(fields) when is_list(fields),
    do: fields |> Enum.map(&format_error_field/1) |> Enum.reject(&is_nil/1)

  defp format_error_fields(field), do: format_error_fields([field])

  defp format_error_field({name, value}),
    do: "#{format_error_field_name(name)}=#{format_error_value(value)}"

  defp format_error_field(name) when is_atom(name), do: format_error_field_name(name)
  # 裸值也走 format_error_value/1：16 字节 binary 同样要规范化成 canonical UUID，
  # 否则裸值形态会绕过规范化、以非法 UTF-8 进 `[String!]`（F7）。
  defp format_error_field(value) when is_binary(value), do: format_error_value(value)

  # 无法识别的形态（map / 三元组 / 数字 …）不塞进 `[String!]`，但也不能静默丢：
  # 丢了等于 #595 刚建立的「拒绝路径可定位」在下一个新错误形态上无声退化（A4）。
  defp format_error_field(other) do
    Logger.warning("[graphql] dropped unrecognized error field shape: #{inspect(other)}")
    nil
  end

  defp format_error_field_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_error_field_name(name) when is_binary(name), do: name
  defp format_error_field_name(name), do: inspect(name)

  defp format_error_value(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp format_error_value(value) when is_binary(value), do: value
  defp format_error_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_error_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_error_value(value), do: inspect(value)

  # 把 Absinthe input map 转为 Ash attrs map（只取指定字段，忽略缺省）。
  # map_input(input, keys)：keys 内存在才放进去；
  # map_input(input)：全量取（用于 update_workspace_profile_input 的全部可选字段）。
  def map_input(input, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case input do
        %{^key => value} -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  def map_input(input) do
    map_input(input, [:avatar_url, :location, :about, :skills, :visibility])
  end

  # actor 门控组合子（PR-E）：nil → unauthorized_error()（on_nil 可覆盖——消费方：
  # me 的 auth_uncertain 分支与 myEnrollment 匿名→null），ok → fun.(actor)。
  # 19 处 case context[:actor] 标准门收敛于此，错误契约单点（未登录统一
  # unauthorized message/code）。
  def with_actor(context, fun, opts \\ []) do
    on_nil = Keyword.get(opts, :on_nil, fn _context -> {:error, unauthorized_error()} end)

    case context[:actor] do
      nil -> on_nil.(context)
      actor -> fun.(actor)
    end
  end

  def mutation_errors(error, context, action, resource, domain) do
    to_ash_graphql_errors(error, context, action, resource, domain)
    |> List.wrap()
    |> Enum.map(fn error ->
      %{
        message: error[:message] || error.message || "invalid request",
        code: error[:code] || "invalid",
        # #595：拒绝路径要能定位到具体场/工作台，fields 不再丢弃
        # （规范化在 to_ash_graphql_errors/5，本处只透传）。
        fields: error[:fields] || []
      }
    end)
  end

  # Ash.read 结果 → Absinthe 结果（错误统一走 to_ash_graphql_errors）
  def map_error(result, context, action, resource, domain) do
    case result do
      {:ok, records} -> {:ok, records}
      {:error, error} -> {:error, to_ash_graphql_errors(error, context, action, resource, domain)}
    end
  end

  # admin 门控：非 platform_admin → forbidden（与 Phase 1 PlatformAdminPlug 同语义）。
  # 未登录 → unauthorized。通过后执行 fun(actor)。
  def with_admin(context, fun) do
    actor = context[:actor]

    cond do
      Cgc2046.Accounts.Policies.PlatformAdmin.platform_admin?(actor) ->
        fun.(actor)

      is_nil(actor) ->
        {:error, unauthorized_error()}

      true ->
        {:error, [message: "forbidden", code: "forbidden"]}
    end
  end

  # admin 列表 resolver 工厂：with_admin 门控 → args 校验 → for_read → filter →
  # pre_read → paginate → read → post_read。一处接线顺序，N 个 query 声明式复用
  # （leverage）；gate/validate/filter/paginate 顺序只在此验证（locality）。
  # my_workspace_applications 不用此构造器：gate 是 applicant 非 platform_admin，形状不同。
  def admin_list(resource, filter_fn, post_fn, opts \\ []) do
    pre_read = Keyword.get(opts, :pre_read, fn q -> q end)

    # 成对/互斥类 args 约束（如 KTD5 entity_id 必须与 entity_type 成对）：门控之后、
    # 触库之前校验，返回 :ok | {:error, absinthe_error}；默认无约束。
    validate = Keyword.get(opts, :validate, fn _args -> :ok end)

    fn _, args, %{context: context} ->
      with_admin(context, fn actor ->
        with :ok <- validate.(args) do
          resource
          |> Ash.Query.for_read(:read)
          |> filter_fn.(args)
          |> pre_read.()
          |> AdminList.paginate(args[:first], args[:after])
          |> Ash.read(actor: actor)
          |> post_fn.(context)
        end
      end)
    end
  end

  def admin_rule_row(rule) do
    %{
      id: rule.id,
      initiative_id: rule.initiative_id,
      key: to_string(rule.key),
      value_json: Jason.encode!(rule.value),
      locked: rule.locked,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end
end
