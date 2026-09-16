defmodule Cgc2046.Errors.DatabaseErrorTest do
  @moduledoc """
  #612 全局安全网契约测试（合成错误树走**真 funnel**，不依赖 DB 漂移）。

  三条实测路径（均在本文件断言，防止"只加类 impl"的半个修法回归）：

  1. 单一未知错误 → `Ash.Error.to_error_class/2` 归并出 `Ash.Error.Unknown` **类**；
  2. `Ash.Error.to_ash_error/2`（ash_postgres 数据层入口）直接给
     `Ash.Error.Unknown.UnknownError` **叶子**；
  3. invalid 类错误 + 未知叶子混合 → `Ash.Error.Invalid` 类，而
     `AshGraphql.Graphql.Resolver.unwrap_errors/1` 会把 Invalid 展开成叶子。

  外加：① 面（GraphQL funnel / MCP 出口 / 审计列）都不含底层细节；
  ② uuid 在面与日志同名可对照；③ 已知错误 code 与文案**逐字不变**的回归钉。
  """

  use Cgc2046.DataCase, async: true

  import ExUnit.CaptureLog

  require Ash.Query

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.{BusinessError, DatabaseError}
  alias Cgc2046.Events.PaymentModeValidation
  alias Cgc2046.Initiatives.Initiative
  alias Cgc2046.Mcp.Errors, as: McpErrors
  alias Cgc2046.Mcp.{ToolCallLog, Wrapper}

  # 模拟 ash_postgres 未命中 resource DSL 声明时叶子携带的原文（索引名 / CHECK 名 /
  # 表名 / 冲突键值 / Ecto 教程文本）——真实来源见 database_error_db_test.exs
  @raw """
  ** (Ecto.ConstraintError) constraint error when attempting to insert struct:

      * unique (index): initiatives_slug_index
      * check (constraint): events_payment_mode_exclusive

  The changeset has not defined any constraint.

  Key (slug)=(probe-slug-value) already exists.
  """

  # 底层细节黑名单：索引名 / 约束名 / 表名 / 冲突键值 / Ecto 原文 / SQL 片段
  @leak ~r/initiatives_slug_index|events_payment_mode_exclusive|initiatives|duplicate key|violates|already exists|Key \(slug\)|Ecto\.ConstraintError|changeset/i

  @initiative_slug_locked_message "slug is locked once the initiative is published (editable in draft only)"

  defp leaf, do: %Ash.Error.Unknown.UnknownError{error: @raw}

  defp unknown_class, do: Ash.Error.to_error_class([leaf()])

  defp mixed_class do
    Ash.Error.to_error_class([
      %Ash.Error.Changes.InvalidAttribute{
        field: :slug,
        message: "has already been taken",
        vars: []
      },
      leaf()
    ])
  end

  defp graphql_errors(error) do
    AshGraphql.Errors.to_errors([error], %{}, Cgc2046.Initiatives, Initiative, :update)
  end

  defp uuid_of(message) do
    [uuid] = Regex.run(~r/error id: ([0-9a-f-]{36})/, message, capture: :all_but_first)
    uuid
  end

  describe "unmapped?/1 判据（只认错误类，与 ConstraintConflict 判据正交）" do
    test "类 / 叶子 / 混合树 / changeset errors 列表 → true" do
      assert DatabaseError.unmapped?(unknown_class())
      assert DatabaseError.unmapped?(leaf())
      assert DatabaseError.unmapped?(mixed_class())

      assert DatabaseError.unmapped?([
               %Ash.Error.Changes.InvalidAttribute{field: :x, message: "m", vars: []},
               leaf()
             ])
    end

    test "已知业务错误 / 已映射 Ash 错误 / 任意值 → false（判据面不扩大）" do
      refute DatabaseError.unmapped?(PaymentModeValidation.exclusive_error(:deposit_enabled))

      refute DatabaseError.unmapped?(%Ash.Error.Invalid{
               errors: [
                 %Ash.Error.Changes.InvalidAttribute{field: :x, message: "m", vars: []}
               ]
             })

      refute DatabaseError.unmapped?(:some_atom)
      refute DatabaseError.unmapped?(nil)
      refute DatabaseError.unmapped?([])
    end
  end

  describe "GraphQL 面（AshGraphql.Errors.to_errors/6：生成 mutation 与自定义 resolver 的唯一 funnel）" do
    test "类 / 叶子 → database_error + uuid，且不含底层细节" do
      for error <- [unknown_class(), leaf()] do
        assert [
                 %{
                   code: "database_error",
                   short_message: "database_error",
                   vars: %{},
                   fields: [],
                   message: message
                 }
               ] = graphql_errors(error)

        assert message =~ ~r/^database operation failed \(error id: [0-9a-f-]{36}\)$/
        refute message =~ @leak
      end
    end

    test "混合树：已知条目逐字不变，未知叶子降级为 database_error" do
      assert [known, unknown] = graphql_errors(mixed_class())

      assert known.code == "invalid_attribute"
      assert known.message == "has already been taken"
      assert unknown.code == "database_error"
      refute unknown.message =~ @leak
    end

    test "读路径 to_resolution/3 同款命中（resolver.ex 的 impl_for 分支）" do
      assert {:error, [%{code: "database_error", message: message}]} =
               AshGraphql.Graphql.Resolver.to_resolution(
                 {:error, unknown_class()},
                 %{},
                 Cgc2046.Initiatives
               )

      refute message =~ @leak
    end

    test "原文只进服务端日志，且与面上 uuid 同名可对照" do
      {[entry], log} = with_log(fn -> graphql_errors(unknown_class()) end)

      uuid = uuid_of(entry.message)

      assert log =~ "[database_error] error_id=#{uuid}"
      assert log =~ "initiatives_slug_index"
      assert log =~ "Key (slug)=(probe-slug-value)"
    end
  end

  describe "MCP 出口（Cgc2046.Mcp.Errors：37 处工具/确认流调用点唯一入口）" do
    test "类 / 叶子 / 混合树 → database_error 前缀 + uuid，且不含底层细节" do
      for error <- [unknown_class(), leaf(), mixed_class()] do
        {message, log} = with_log(fn -> McpErrors.message(error, "failed to update event") end)

        assert message =~
                 ~r/^database_error: database operation failed \(error id: [0-9a-f-]{36}\)$/

        refute message =~ @leak
        assert log =~ "[database_error] error_id=#{uuid_of(message)}"
      end
    end

    test "已知 Invalid → 逐叶折叠：叶子文案逐字，类脚手架不出面（#631）" do
      known = %Ash.Error.Invalid{
        errors: [
          %Ash.Error.Changes.InvalidAttribute{
            field: :slug,
            message: "has already been taken",
            vars: []
          }
        ]
      }

      message = McpErrors.message(known, "failed to update event")

      # 折叠前是 Exception.message(known)（含 "Invalid Error" 类头）；现在 = 叶子文案
      assert message == Exception.message(hd(known.errors))
      refute message =~ "Invalid Error"
      refute message =~ "Bread Crumbs:"
      refute message =~ ~r/\%[A-Z][A-Za-z0-9_.]*\{/
    end

    test "带 breadcrumbs 的错误类 → 折叠后不含 Bread Crumbs/来源行/栈（#631 生产同形）" do
      # 生产 `save_course_content` 的行正是这种带 breadcrumbs 的叶子（Ash 在
      # action 内 add_error 时写入 "Error returned from: <模块>.<action>"）
      class =
        Ash.Error.to_error_class([
          %Ash.Error.Changes.InvalidChanges{
            message: "objectives required",
            vars: [],
            bread_crumbs: ["Error returned from: Cgc2046.Curriculum.Output.upsert_content"]
          }
        ])

      # 前置：类消息本身确实带脚手架（否则本测试无意义——Ash 升版改了渲染即在此暴露）
      assert Exception.message(class) =~ "Bread Crumbs:"

      message = McpErrors.message(class, "failed to save course content")

      assert message =~ "objectives required"
      refute message =~ "Bread Crumbs:"
      refute message =~ "Invalid Error"
      refute message =~ "Error returned from"
      refute message =~ "Output.upsert_content"
      refute message =~ ~r/\%[A-Z][A-Za-z0-9_.]*\{/

      # 审计列同款（第二暴露通道）
      audit = McpErrors.audit_message(class)
      assert audit =~ ~r/^internal error \(error id: /
      refute audit =~ "objectives required"
      refute audit =~ "Bread Crumbs:"
    end

    test "非 Ash 异常 / 非异常 → 原 fallback 文案逐字（零回归）" do
      assert McpErrors.message(%RuntimeError{message: "boom"}, "failed to cancel course") ==
               "failed to cancel course"

      assert McpErrors.message(:some_atom, "failed to cancel course") == "failed to cancel course"
    end

    test "已是字符串的错误原样透传（with/else 直通语义不因收口改变）" do
      assert McpErrors.message("initiative not found", "failed to update initiative") ==
               "initiative not found"
    end

    test "审计出口 audit_message/1：**任何**非二进制错误都不落原文（固定摘要 + uuid）" do
      {audit, log} = with_log(fn -> McpErrors.audit_message(unknown_class()) end)

      assert audit =~ ~r/^database_error: database operation failed \(error id: [0-9a-f-]{36}\)$/
      refute audit =~ @leak
      assert log =~ "[database_error] error_id="

      # 非未映射（如裸 Postgrex / Ecto 约束错误）→ 固定摘要，inspect 已被彻底移除
      pg = %Postgrex.Error{
        postgres: %{
          code: :unique_violation,
          constraint: "initiatives_slug_index",
          table: "initiatives",
          detail: "Key (slug)=(probe-slug-value) already exists.",
          message: "duplicate key value violates unique constraint \"initiatives_slug_index\"",
          query: "INSERT INTO initiatives ..."
        }
      }

      {audit2, log2} = with_log(fn -> McpErrors.audit_message(pg) end)

      assert audit2 =~ ~r/^internal error \(error id: [0-9a-f-]{36}\)$/
      refute audit2 =~ @leak
      refute audit2 =~ "Postgrex"
      assert log2 =~ "[internal_error] error_id="
      assert log2 =~ "initiatives_slug_index"

      boom = %RuntimeError{message: "boom"}
      {audit3, _log3} = with_log(fn -> McpErrors.audit_message(boom) end)
      assert audit3 =~ ~r/^internal error \(error id: [0-9a-f-]{36}\)$/
      refute audit3 =~ "RuntimeError"
    end
  end

  describe "审计列第二暴露通道（ToolCallLog.error_message 会被 MCP/GraphQL 二次读出）" do
    test "经 Wrapper 落库的 error_message 不含底层细节且保留 uuid" do
      actor = Fixtures.platform_admin("612-audit")
      frame = Frame.new(current_user: actor)
      error = unknown_class()

      assert {:error, _} =
               Wrapper.run(
                 frame,
                 %{"workspace_id" => Ash.UUID.generate()},
                 "admin_create_initiative",
                 fn _actor, _workspace_id, _params -> {:error, error} end
               )

      [log] =
        ToolCallLog
        |> Ash.Query.filter(user_id == ^actor.id and tool == "admin_create_initiative")
        |> Ash.read!(authorize?: false)

      assert log.result_status == :error
      assert log.error_message =~ "database_error: database operation failed (error id: "
      refute log.error_message =~ @leak
    end

    test "非二进制原始错误（裸 Postgrex）落库也不含库内文本，且保留 uuid（#612 第二条通道）" do
      actor = Fixtures.platform_admin("612-audit-pg")
      frame = Frame.new(current_user: actor)

      pg = %Postgrex.Error{
        postgres: %{
          code: :unique_violation,
          constraint: "initiatives_slug_index",
          table: "initiatives",
          detail: "Key (slug)=(probe-slug-value) already exists.",
          message: "duplicate key value violates unique constraint \"initiatives_slug_index\"",
          query: "INSERT INTO initiatives ..."
        }
      }

      {result, log} =
        with_log(fn ->
          Wrapper.run(
            frame,
            %{"workspace_id" => Ash.UUID.generate()},
            "admin_create_initiative",
            fn _actor, _workspace_id, _params -> {:error, pg} end
          )
        end)

      assert {:error, ^pg} = result

      [row] =
        ToolCallLog
        |> Ash.Query.filter(user_id == ^actor.id and tool == "admin_create_initiative")
        |> Ash.read!(authorize?: false)

      assert row.result_status == :error
      assert row.error_message =~ ~r/^internal error \(error id: [0-9a-f-]{36}\)$/
      refute row.error_message =~ @leak
      refute row.error_message =~ "Postgrex"

      # 原文只进服务端日志
      assert log =~ "[internal_error] error_id="
      assert log =~ "initiatives_slug_index"
    end
  end

  describe "已知错误零回归" do
    test "BusinessError 的 code / message / short_message / fields 逐字不变" do
      payment = PaymentModeValidation.exclusive_error(:deposit_enabled)

      assert [entry] = graphql_errors(payment)
      assert entry.code == "event_payment_mode_exclusive"
      assert entry.message == Exception.message(payment)
      assert entry.short_message == Exception.message(payment)

      # MCP 出口在真实链路上收到的是归并后的类（Ash 把单一 invalid 类错误收进
      # Ash.Error.Invalid）——#631 起逐叶折叠：叶子文案（BusinessError message）
      # 逐字保留，类头不出面
      payment_class = Ash.Error.to_error_class([payment])

      assert McpErrors.message(payment_class, "failed to create event") ==
               Exception.message(payment)

      assert McpErrors.message(payment_class, "failed to create event") =~
               "an event cannot enable both pricing tiers and deposit"

      slug_locked =
        BusinessError.exception(
          message: @initiative_slug_locked_message,
          code: "initiative_slug_locked",
          fields: [:slug]
        )

      assert [slug_entry] = graphql_errors(slug_locked)
      assert slug_entry.code == "initiative_slug_locked"
      assert slug_entry.message == @initiative_slug_locked_message
      assert slug_entry.fields == [:slug]

      slug_class = Ash.Error.to_error_class([slug_locked])
      assert McpErrors.message(slug_class, "fb") == Exception.message(slug_locked)
      assert McpErrors.message(slug_class, "fb") =~ @initiative_slug_locked_message
    end

    test "已映射 Ash 错误的 GraphQL 形状逐字不变（invalid_attribute）" do
      known = %Ash.Error.Invalid{
        errors: [
          %Ash.Error.Changes.InvalidAttribute{
            field: :slug,
            message: "has already been taken",
            vars: []
          }
        ]
      }

      assert [%{code: "invalid_attribute", message: "has already been taken", fields: [:slug]}] =
               graphql_errors(known)
    end
  end
end
