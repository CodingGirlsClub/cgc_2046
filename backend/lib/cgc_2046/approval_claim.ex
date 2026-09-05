defmodule Cgc2046.ApprovalClaim do
  @moduledoc """
  原子抢占（approval claim）唯一真源：把「读到 X 且未过期才置 Y」下推成 DB 原子动作。

  （2026-08-17 架构深化候选 A+B）

  收敛前，7 资源内联 ~14 份「条件 UPDATE + num_rows 判读」拷贝（join_request /
  workspace_application / invitation / enrollment / sponsorship / speaker_invitation）；
  本 module 收编为**唯一实现**。资源 action 退化为：算好参数 → 一行 `claim/2` →
  自己的错误映射 + force_change + after_action 效果。

  ## interface

  `claim(record, opts) :: {:ok, returned :: map()} | {:error, :not_claimed}`
  （record 为资源 struct，取 `id`）。opts 轴：

  - `table:` 编译期枚举 atoms（拒绝任意字符串）；
  - `from:` 状态守卫数组（非空 atom 列表，产出 `status IN (...)`）；
  - `set:` 列 → 字面值（参数化）| `{:arg, atom}`（值取自 opts 同名键）|
    `{:sql, fragment}`（原样内联，如 `"NOW()"`）；
  - `deadline:` `nil | {col, :future | :passed}`——`:future` →
    `(col IS NULL OR col > $N)`（**SQL 端口 = ApprovalDeadline.not_expired?/2**）；
    `:passed` → `col IS NOT NULL AND col < $N`（**SQL 端口 = ApprovalDeadline.overdue?/2**）。
    守卫复用 `set` 中 `{:arg, :now}` 值的占位符（同一时点，与 SET 的
    approved_at/accepted_at/expired_at 同参，==now 双向都拒绝）；无 `{:arg, :now}`
    却配 deadline 为编程错误；
  - `extra_where:` `nil | {sql_fragment, params}`——片段占位符从 `$1` 起内部编号，
    claim 统一重编号到全语句连续编号（消灭现手工连续编号，sponsorship 42P18 纪律
    单点化）。**约束：片段内所有 `$数字` 必须是占位符**——重编号 regex 会 shift
    一切 `$N` 形态文本，含字面 `$100` 的片段会被误改（当前无此形态，防未来误用）；
  - `returning:` 列原子列表（默认 `[]`），成功返回对应列值 map（DB 原始值，调用方自行 load）。

  占位符全语句连续编号：SET 值 → extra_where 参数 → id（固定最后一个参数，order.ex
  claim/4 同款）。不自己开事务/checkout（before_action 事务继承，savepoint 语义不变）；
  不加租户过滤（row id 已从租户隔离读面解析）。

  ## 错误

  正常判读只返回 `:not_claimed`（num_rows=0）；DB 错误以 `{:error, {:database, reason}}`
  原样回传资源层，由各资源映射为自己的错误原子/消息/发生层（D3——错误映射不收编）。
  """

  alias Cgc2046.Repo

  @tables [
    :join_requests,
    :workspace_applications,
    :invitations,
    :enrollments,
    :sponsorships,
    :speaker_invitations
  ]

  @doc """
  原子抢占一行：条件 UPDATE 命中（num_rows=1）→ `{:ok, returned}`；0 行 →
  `{:error, :not_claimed}`；DB 错误 → `{:error, {:database, reason}}`。
  """
  @spec claim(map(), keyword()) ::
          {:ok, map()} | {:error, :not_claimed} | {:error, {:database, term()}}
  def claim(%{id: id}, opts) do
    table = fetch_table!(opts)
    from = fetch_from!(opts)
    set = fetch_set!(opts)
    deadline = Keyword.get(opts, :deadline)
    extra_where = Keyword.get(opts, :extra_where)
    returning = Keyword.get(opts, :returning, [])

    {set_sql, set_params, now_placeholder} = build_set(set, opts)
    deadline_sql = build_deadline(deadline, now_placeholder)
    {extra_sql, extra_params} = build_extra_where(extra_where, length(set_params))
    id_placeholder = length(set_params) + length(extra_params) + 1

    sql = """
    UPDATE #{table}
    SET #{set_sql}
    WHERE id = $#{id_placeholder} AND status IN (#{from_sql(from)})
    #{deadline_sql}
    #{extra_sql}
    #{returning_sql(returning)}
    """

    params = set_params ++ extra_params ++ [Repo.uuid!(id)]

    case Repo.query(sql, params) do
      {:ok, %{num_rows: 1, rows: rows}} -> {:ok, returned_map(returning, rows)}
      {:ok, %{num_rows: 0}} -> {:error, :not_claimed}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp fetch_table!(opts) do
    table = Keyword.fetch!(opts, :table)

    unless table in @tables do
      raise ArgumentError,
            "ApprovalClaim: 未知 table #{inspect(table)}（允许：#{inspect(@tables)}）"
    end

    table
  end

  defp fetch_from!(opts) do
    from = Keyword.fetch!(opts, :from)

    unless is_list(from) and from != [] and Enum.all?(from, &is_atom/1) do
      raise ArgumentError, "ApprovalClaim: from 必须是非空 atom 列表，得到 #{inspect(from)}"
    end

    from
  end

  defp fetch_set!(opts) do
    set = Keyword.fetch!(opts, :set)

    unless is_list(set) and set != [] and
             Enum.all?(set, &match?({col, _} when is_atom(col), &1)) do
      raise ArgumentError, "ApprovalClaim: set 必须是 {列atom, 值} keyword 列表，得到 #{inspect(set)}"
    end

    set
  end

  defp from_sql(from), do: Enum.map_join(from, ", ", &"'#{&1}'")

  defp build_set(set, opts) do
    {sql_parts, params, now_placeholder} =
      Enum.reduce(set, {[], [], nil}, fn {col, value}, {parts, params, now_placeholder} ->
        case value do
          {:sql, fragment} ->
            {[~s(#{col} = #{fragment}) | parts], params, now_placeholder}

          {:arg, :now} ->
            placeholder = length(params) + 1

            {[~s(#{col} = $#{placeholder}) | parts], params ++ [Keyword.fetch!(opts, :now)],
             now_placeholder || placeholder}

          {:arg, name} ->
            placeholder = length(params) + 1

            {[~s(#{col} = $#{placeholder}) | parts], params ++ [Keyword.fetch!(opts, name)],
             now_placeholder}

          literal ->
            placeholder = length(params) + 1
            {[~s(#{col} = $#{placeholder}) | parts], params ++ [literal], now_placeholder}
        end
      end)

    {Enum.join(Enum.reverse(sql_parts), ", "), params, now_placeholder}
  end

  defp build_deadline(nil, _now_placeholder), do: ""

  defp build_deadline({_col, _direction}, nil) do
    raise ArgumentError,
          "ApprovalClaim: deadline 守卫需要 set 中含 {:arg, :now} 提供同一时点"
  end

  defp build_deadline({col, :future}, now_placeholder) do
    ~s|AND (#{col} IS NULL OR #{col} > $#{now_placeholder})|
  end

  defp build_deadline({col, :passed}, now_placeholder) do
    ~s|AND #{col} IS NOT NULL AND #{col} < $#{now_placeholder}|
  end

  defp build_extra_where(nil, _shift), do: {"", []}

  defp build_extra_where({fragment, params}, shift)
       when is_binary(fragment) and is_list(params) do
    shifted =
      Regex.replace(~r/\$(\d+)/, fragment, fn _, digits ->
        "$#{String.to_integer(digits) + shift}"
      end)

    {"AND #{shifted}", params}
  end

  defp returning_sql([]), do: ""
  defp returning_sql(returning), do: "RETURNING #{Enum.join(returning, ", ")}"

  defp returned_map([], _rows), do: %{}
  defp returned_map(returning, [row]), do: Map.new(Enum.zip(returning, row))
end
