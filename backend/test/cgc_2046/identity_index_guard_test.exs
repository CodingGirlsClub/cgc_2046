defmodule Cgc2046.IdentityIndexGuardTest do
  use Cgc2046.DataCase, async: true

  @moduledoc """
  全仓 identity 索引名守卫（#611）。

  方向 = **resource 的 identity 定义 → `pg_indexes`**（不是反向从手写索引出发）：
  期望名走 `Cgc2046.Repo.IndexCatalog.expected_identity_indexes/0`，与 ash_postgres
  注册 `unique_constraint(name: ..., match: :exact)` 的公式逐字同源，故三条都能抓到：

  1. 手写 migration 的索引命名漂移（今天本测试原本应红的 5 条 = #611 修的 5 处）；
  2. **新增 identity 却忘了建索引**（反向断言永远抓不到这条）；
  3. 名字对但索引退化成非唯一（`match: :exact` 一样接不上）。

  为什么必须有它：`mix ash_postgres.generate_migrations --check` 比对的是 snapshot、
  **不比对 DB**——手写 migration 的索引命名漂移它看不见（见 backend/AGENTS.md）。

  第二个 describe 是**配码分类表**（白名单载体）：`@drift_sites` 逐条列出 #611 触及的
  漂移位点，配码的断言真能映射（合成 leaf 调 `handle_write_error/2`，范式同
  `payment_mode_validation_test.exs`），`暂不配码` 的断言 fail-closed 且**必须写明理由**。
  白名单粒度 = 按 **identity**（表级会把 `speaker_invitations` 的 `unique_token_hash`
  一起放行，两个 identity 语义完全不同）。
  """

  alias Cgc2046.Errors.{BusinessError, ErrorCodeContract}
  alias Cgc2046.Repo.IndexCatalog

  # #611 的 5 处漂移位点 + 各自处置（白名单粒度 = {table, identity}）
  @drift_sites [
    %{
      table: "initiative_rules",
      identity: :unique_initiative_key,
      disposition: {:code, "initiative_rule_already_exists"}
    },
    %{
      table: "event_moderators",
      identity: :unique_event_user,
      disposition: {:code, "event_moderator_already_assigned"}
    },
    %{
      table: "mcp_tokens",
      identity: :unique_token_hash,
      disposition: :no_code_yet,
      reason:
        "当前实现不可达：token_hash = SHA256(随机 32 字节 token)（mcp/token.ex:150），无人工输入路径。" <>
          "**非契约保证**——将来加人工输入路径即可能可达，故只记「暂不配码」不结案"
    },
    %{
      table: "speaker_invitations",
      identity: :unique_event_speaker,
      disposition: :no_code_yet,
      reason:
        "域层已有 get-existing 预查（events/speaker_invitation.ex:566 → :duplicate_invitation），" <>
          "唯一索引只在并发窗口兜底，冲突现状落 #612 的 database_error，可接受"
    },
    %{
      table: "wechat_login_tickets",
      identity: :unique_state,
      disposition: :no_code_yet,
      reason:
        "结构上不可达：资源无 create action（defaults([:read])），发新票走裸 insert_all + " <>
          "随机 uuid state（accounts/wechat_login_ticket.ex:101-118），连可挂 error_handler 的写 action 都不存在"
    }
  ]

  describe "identity 推导索引名 ↔ DB（DSL → pg_indexes）" do
    test "每个 identity 的推导索引名都真实存在且唯一（命名漂移 / 漏建索引即红）" do
      expected = IndexCatalog.expected_identity_indexes()

      # 防"守卫空转"：枚举逻辑坏掉（domain 配置变更 / Ash API 变更）时必须红，
      # 而不是静默 0 条全绿。实测 2026-09-16：46 resource / 42 identity。
      assert length(expected) >= 40,
             "identity 枚举异常缩水（#{length(expected)} 条）——守卫空转即红"

      present = IndexCatalog.present_unique_indexes(Enum.map(expected, & &1.index_name))

      missing =
        expected
        |> Enum.reject(&MapSet.member?(present, &1.index_name))
        |> Enum.map(fn site ->
          "  #{site.table} identity=#{site.identity} expected=#{site.index_name} " <>
            "actual=#{inspect(IndexCatalog.index_names(site.table))}"
        end)

      assert missing == [],
             """
             以下 identity 的推导唯一索引在 DB 中缺失或非唯一
             （手写 migration 命名漂移 / 新增 identity 未建索引 / 索引退化为非唯一）：

             #{Enum.join(missing, "\n")}
             """
    end
  end

  describe "漂移位点配码分类表（白名单只记「暂不配码」并注明理由）" do
    test "分类表位点自洽：存在于 identity 全集、暂不配码必带理由" do
      universe =
        IndexCatalog.expected_identity_indexes()
        |> Map.new(&{{&1.table, &1.identity}, &1})

      for site <- @drift_sites do
        assert Map.has_key?(universe, {site.table, site.identity}),
               "分类表位点 {#{site.table}, #{site.identity}} 不在 identity 全集中" <>
                 "（表名/identity 名拼错、或该 identity 已被删除——清单必须跟着改）"

        case site.disposition do
          :no_code_yet ->
            assert is_binary(site[:reason]) and String.trim(site.reason) != "",
                   "#{site.table}.#{site.identity} 标为「暂不配码」但未注明理由"

          {:code, code} ->
            assert is_binary(code)
        end
      end
    end

    test "配码位点真能映射到稳定 code，且未登记约束 fail-closed 不被误归因" do
      universe =
        IndexCatalog.expected_identity_indexes()
        |> Map.new(&{{&1.table, &1.identity}, &1})

      contract = MapSet.new(ErrorCodeContract.codes())

      for site <- @drift_sites, {:code, code} <- [site.disposition] do
        expected = Map.fetch!(universe, {site.table, site.identity})

        assert MapSet.member?(contract, code),
               "code #{code} 不在 priv/error_codes_contract.json（#241 四清单漏配）"

        assert %BusinessError{code: ^code} =
                 expected.resource.handle_write_error(
                   nil,
                   unique_conflict(expected.resource, site.identity, expected.index_name)
                 ),
               "#{site.table}.#{site.identity} 撞 #{expected.index_name} 未映射成 #{code}"

        # fail-closed：本表未登记的约束名不得被吞成任何业务码（日后加 identity 时
        # 泛化判据会在这里红，逼一次显式分派）
        unregistered =
          unique_conflict(expected.resource, site.identity, "#{site.table}_future_index")

        assert expected.resource.handle_write_error(nil, unregistered) == unregistered,
               "#{site.table} 把未登记的约束名误归因（泛化 unique 判据）"

        # 非 unique 冲突（DB 真故障）同样原样上抛
        other = %Ash.Error.Changes.InvalidAttribute{field: :id, message: "boom"}
        assert expected.resource.handle_write_error(nil, other) == other
      end
    end

    test "暂不配码位点 fail-closed：冲突不得被吞成任何业务码" do
      universe =
        IndexCatalog.expected_identity_indexes()
        |> Map.new(&{{&1.table, &1.identity}, &1})

      for site <- @drift_sites, site.disposition == :no_code_yet do
        expected = Map.fetch!(universe, {site.table, site.identity})
        error = unique_conflict(expected.resource, site.identity, expected.index_name)

        result =
          if function_exported?(expected.resource, :handle_write_error, 2) do
            expected.resource.handle_write_error(nil, error)
          else
            error
          end

        assert result == error,
               "#{site.table}.#{site.identity} 标为「暂不配码」却吞成了业务码" <>
                 "（要么补码并改分类表，要么保留 fail-closed）"
      end
    end
  end

  # 合成 ash_postgres 唯一约束冲突 leaf（范式：payment_mode_validation_test.exs 的
  # CHECK 冲突合成；ConstraintConflict 判据读的就是 private_vars 这两个键）
  defp unique_conflict(resource, identity_name, constraint_name) do
    keys =
      resource
      |> Ash.Resource.Info.identities()
      |> Enum.find(&(&1.name == identity_name))
      |> Map.fetch!(:keys)

    %Ash.Error.Changes.InvalidAttribute{
      field: List.first(keys),
      message: "has already been taken",
      private_vars: [constraint_type: :unique, constraint: constraint_name]
    }
  end
end
