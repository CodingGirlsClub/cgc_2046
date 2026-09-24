defmodule Cgc2046.StatusTransition.Change do
  @moduledoc """
  StatusTransition 原语的 action 级声明式入口（#846）：资源在 update action 上
  声明 `change {StatusTransition.Change, from: :draft, to: :open}`，取代原先
  复制在 Event / Course 六个 action 里的约 40 行匿名 before_action 块。

  行为与被替换的内联块完全一致，错误文案逐字节不变（D2 硬契约：web
  offering-pages.tsx 正则与 MCP 测试逐字依赖这两句）：

  - from 匹配内存态 status：`StatusTransition.run/3` 条件 UPDATE 原子抢占，
    成功后 `force_change_attribute(:status, to)`（Ash 后续写同值幂等）；
  - DB 命中 0 行（并发竞态）：`"<action> failed: status changed concurrently,
    retry on fresh read"`；
  - DB 错误：`{:database, reason}` 原样 add_error（与原块处理方式一致）；
  - from 不匹配（状态非法）：`"cannot <action> from status=<status>"`。

  动词取 action 名（launch / close / cancel 与文案动词一致）；table 由资源
  postgres 配置推出，`StatusTransition` 的编译期白名单不放宽、仍然兜底。

  **刻意不纳入**（#846 D1，防后续评审再议）：Initiative `transition/3` 与
  Event / Course `:delete` 是行锁族（`SELECT … FOR UPDATE`）而非条件 UPDATE，
  `from` 是列表、带 ready 门控、统一一句话报错——两种机制不进同一接口
  （course.ex `:delete` 注释已论证 StatusTransition 在此不适用的原因）。
  """

  use Ash.Resource.Change

  alias Cgc2046.StatusTransition

  @impl true
  def change(changeset, opts, _context) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)

    Ash.Changeset.before_action(changeset, fn cs ->
      case Ash.Changeset.get_data(cs, :status) do
        ^from ->
          case StatusTransition.run(cs, table_for(cs.resource), to) do
            :ok ->
              Ash.Changeset.force_change_attribute(cs, :status, to)

            {:error, :status_race} ->
              Ash.Changeset.add_error(
                cs,
                "#{cs.action.name} failed: status changed concurrently, retry on fresh read"
              )

            {:error, {:database, _} = reason} ->
              Ash.Changeset.add_error(cs, reason)
          end

        status ->
          Ash.Changeset.add_error(cs, "cannot #{cs.action.name} from status=#{status}")
      end
    end)
  end

  # 资源 postgres 配置的表名（"events" / "courses"）转白名单 atom。
  # String.to_existing_atom 安全：表名来自资源 DSL（开发者控制，非用户输入），
  # 且 StatusTransition.run 的编译期白名单对任意越界表仍 raise 兜底。
  defp table_for(resource) do
    resource
    |> AshPostgres.DataLayer.Info.table()
    |> String.to_existing_atom()
  end
end
