defmodule Cgc2046.Errors.DatabaseErrorDbTest do
  @moduledoc """
  #612 真 `Postgrex.Error` 路径：裸 SQL 造一个 resource DSL **未声明**的约束并触发它
  （issue 验收 ① 的构造方式），走 ash_postgres 数据层同款转换，再断言两个面。

  不污染的论证：

  - 探针表用 `CREATE TEMP TABLE`，只存在于本测试独占的 sandbox 连接上，**不锁任何
    共享表**（async 测试可并行）；
  - DDL 与 INSERT 都在 sandbox 事务内，测试结束回滚即消失（PostgreSQL DDL 事务性），
    无跨测试残留；
  - 表名 / 约束名带 `probe_` 前缀，不与真实 schema 对象重名。
  """

  use Cgc2046.DataCase, async: true

  import ExUnit.CaptureLog

  alias Cgc2046.Errors.DatabaseError
  alias Cgc2046.Initiatives.Initiative
  alias Cgc2046.Mcp.Errors, as: McpErrors

  @table "probe_unmapped_error"
  @constraint "probe_unmapped_error_code_uniq"
  @leak ~r/#{@constraint}|#{@table}|duplicate key|violates|already exists|Key \(code\)|Ecto\.ConstraintError/

  setup do
    Repo.query!("""
    CREATE TEMP TABLE #{@table} (
      id int primary key,
      code text,
      CONSTRAINT #{@constraint} UNIQUE (code)
    )
    """)

    Repo.query!("INSERT INTO #{@table} VALUES (1, 'x')")
    :ok
  end

  test "未声明唯一约束的真 violation：数据层转换 → 类/叶子 → 两个面都不含库内文本" do
    assert {:error, %Postgrex.Error{postgres: postgres}} =
             Repo.query("INSERT INTO #{@table} VALUES (2, 'x')")

    assert postgres.constraint == @constraint
    assert postgres.table == @table
    assert postgres.detail =~ "already exists"

    # ash_postgres 的未命中分支：{:error, Ash.Error.to_ash_error(error, stacktrace)}
    leaf = Ash.Error.to_ash_error(%Postgrex.Error{postgres: postgres}, [])
    assert %Ash.Error.Unknown.UnknownError{} = leaf

    # 叶子确实携带原文——这就是改动前的泄漏源（原文必须留在服务端）
    assert Exception.message(leaf) =~ @constraint
    assert DatabaseError.unmapped?(leaf)

    class = Ash.Error.to_error_class([leaf])
    assert %Ash.Error.Unknown{} = class

    {[entry], log} =
      with_log(fn ->
        AshGraphql.Errors.to_errors([class], %{}, Cgc2046.Initiatives, Initiative, :create)
      end)

    assert entry.code == "database_error"
    assert entry.message =~ ~r/^database operation failed \(error id: [0-9a-f-]{36}\)$/
    refute entry.message =~ @leak

    # 原文只进服务端日志（含约束名 / 表名 / 冲突键值 / Postgrex 原文）
    assert log =~ "[database_error] error_id="
    assert log =~ @constraint
    assert log =~ "Key (code)=(x) already exists."

    {mcp, mcp_log} = with_log(fn -> McpErrors.message(class, "failed to create initiative") end)
    assert mcp =~ ~r/^database_error: database operation failed \(error id: [0-9a-f-]{36}\)$/
    refute mcp =~ @leak
    assert mcp_log =~ @constraint

    {audit, _log} = with_log(fn -> McpErrors.audit_message(class) end)
    assert audit =~ ~r/^database_error: /
    refute audit =~ @leak
  end
end
