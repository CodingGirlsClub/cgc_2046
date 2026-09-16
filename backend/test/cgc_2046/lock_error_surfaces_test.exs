defmodule Cgc2046.LockErrorSurfacesTest do
  @moduledoc """
  #621 锁超时/死锁结构化错误码——真构造钉测（非 mock）。

  ## 为什么本文件 async: false、且三条用例各自真等

  走的是**真 advisory lock + 真事务**：

  - lock_timeout 用例：持锁方在另一个连接占住键，被测路径必须等满
    `Repo.acquire_lock/2` 设的 `lock_timeout = 5s` 才会拿到 `lock_not_available`；
  - deadlock 用例：两个事务反向取两把锁，必须等 Postgres `deadlock_timeout`
    （默认 1s）检出环。

  两者都真占连接与锁，并行会互相抢键/自造死锁，故整文件 `async: false` 串行；
  单条用例固定 ~5s / ~1.5s，不是可并行化的慢测试——**不要改成 async: true**。

  持锁方一律走 `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`（sandbox 事务之外的
  真实连接 + 真实事务）：sandbox 事务里的 advisory lock 只挂在 savepoint 上，
  另一个连接看不见（先例 `payments/order_enrollment_lock_test.exs` 同款纪律）。

  ## 形状契约（#621 R1 后）

  - **GraphQL**（auto mutation `assignRoles`）：锁失败以返回型 BusinessError 投递
    → Ash 归一为 `%Ash.Error.Invalid{errors: [%BusinessError{}]}` → AshGraphql
    `unwrap_errors/1` 剥壳 → `AshGraphql.Error` impl（`errors/business_error.ex`）
    → **payload `errors[].code`**。两条反面断言：
    ① 不得落顶层 GraphQL errors——AshGraphql `show_raised_errors?` 默认 false，
    raise 出来的错误只会落 `something_went_wrong`（code/message 全丢）；
    ② 不得被 #612 的 `database_error` 兜底吞并——锁超时/死锁是用户可动作的
    可自愈并发冲突，混进「我们坏了」的故障面即错误分类。
  - **MCP**（`assign_roles` 确认段经 `confirm_operation`）：工具层把
    `{:error, %Ash.Error.Invalid{}}` 折成 `Exception.message/1` 字符串 →
    `{:error, %Anubis.MCP.Error{message: msg}}`，中文文案逐字在 msg 内
    （code 不出 MCP 面——工具层唯一出口，本 PR 不改工具）。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Mcp.Tools.{AssignRoles, ConfirmOperation}
  alias Cgc2046.Repo

  @lock_timeout_message "工作台操作暂时繁忙，请稍后重试"
  @deadlock_message "检测到锁冲突，请稍后重试"

  setup do
    %{owner: owner, workspace: workspace, member: member, membership: membership} =
      Fixtures.workspace_with_member()

    %{owner: owner, workspace: workspace, member: member, membership: membership}
  end

  test "lock_timeout：真等 5s 锁超时 → GraphQL payload code（非 database_error / 非 something_went_wrong）",
       %{owner: owner, workspace: workspace, membership: membership} do
    holder = hold_advisory_lock!(workspace.id)

    body = graphql(assign_roles_mutation(membership.id, ["learner"]), sign_in_token(owner))

    release_advisory_lock(holder)

    assert body["errors"] in [nil, []],
           "锁失败必须以 payload errors 出面；落顶层 errors 即 code 丢失" <>
             "（show_raised_errors? 默认 false → something_went_wrong）：#{inspect(body["errors"])}"

    assert %{"data" => %{"assignRoles" => %{"result" => nil, "errors" => [error]}}} = body
    assert error["code"] == "lock_timeout"
    assert error["message"] == @lock_timeout_message
    refute error["code"] == "database_error", "#612 兜底不得吞并可自愈并发冲突"
    refute error["code"] == "something_went_wrong", "不得落 raise 的通用错误面"
  end

  test "lock_timeout：MCP confirm_operation 面 {:error, %Anubis.MCP.Error{}} 且中文文案逐字",
       %{owner: owner, workspace: workspace, membership: membership} do
    assert {:reply, _, _} =
             reply =
             AssignRoles.execute(
               %{
                 "workspace_id" => workspace.id,
                 "membership_id" => membership.id,
                 "role_names" => ["learner"]
               },
               frame_for(owner)
             )

    %{"pending_id" => pending_id} = decode_reply(reply)

    holder = hold_advisory_lock!(workspace.id)

    result = ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(owner))

    release_advisory_lock(holder)

    assert {:error, %Anubis.MCP.Error{message: msg}, _} = result
    assert msg =~ @lock_timeout_message
  end

  test "deadlock_detected：两事务反向取两把锁真构造 → 结构化死锁码（非 database_error）" do
    results = race_opposite_locks(&Repo.acquire_lock/1)

    assert [error_result] = Enum.filter(results, &match?({:error, _}, &1))

    assert {:error, {:lock_error, %BusinessError{code: code, message: message}}} = error_result
    assert code == "deadlock_detected"
    assert message == @deadlock_message
    refute code == "database_error", "#612 兜底不得吞并可自愈并发冲突"
    refute Enum.any?(results, &match?({:raised, _}, &1)), "锁失败不得 raise（raise 会丢失 code）"
    assert Enum.count(results, &match?({:ok, :ok}, &1)) == 1, "恰一方应为幸存者"
  end

  # ── 持锁/竞争编排（消息握手，无 sleep）──────────────────────────────────

  # 独立连接的真实事务持 advisory lock，直到 release_advisory_lock/1。
  # 键与 Repo.acquire_lock/2 同域：hashtext($1)（默认 hash 选项）。
  defp hold_advisory_lock!(key) do
    test_pid = self()

    task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
            send(test_pid, {:advisory_lock_held, self()})

            receive do
              :release -> :ok
            after
              30_000 -> :ok
            end
          end)
        end)
      end)

    assert_receive {:advisory_lock_held, _pid}, 5_000
    task
  end

  defp release_advisory_lock(task) do
    send(task.pid, :release)
    Task.await(task, 10_000)
  end

  # 两个真实事务反向取两把 advisory lock：A 先 a 后 b、B 先 b 后 a。
  # 握手确保双方都持第一把后才请求第二把 → 必然成环 → Postgres 检出死锁，
  # 恰一方被 40P01 中止（受害方由 PG 选，不做方向断言）。
  # 返回值：幸存者 {:ok, :ok}；受害者 {:error, {:lock_error, %BusinessError{}}}；
  # 若实现回退成 raise，则为 {:raised, error}（断言显式排除）。
  defp race_opposite_locks(acquire) do
    test_pid = self()

    acquirer = fn first, second, tag ->
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          try do
            Repo.transaction(fn ->
              :ok = acquire.(first)
              send(test_pid, {:first_lock_held, tag})

              receive do
                :go -> :ok
              after
                10_000 -> Repo.rollback(:go_timeout)
              end

              case acquire.(second) do
                :ok -> :ok
                {:error, error} -> Repo.rollback({:lock_error, error})
              end
            end)
          rescue
            error -> {:raised, error}
          end
        end)
      end)
    end

    a = acquirer.("lock-error-deadlock-a", "lock-error-deadlock-b", :a)
    assert_receive {:first_lock_held, :a}, 5_000

    b = acquirer.("lock-error-deadlock-b", "lock-error-deadlock-a", :b)
    assert_receive {:first_lock_held, :b}, 5_000

    send(a.pid, :go)
    send(b.pid, :go)

    [Task.await(a, 15_000), Task.await(b, 15_000)]
  end

  # ── HTTP / MCP 面工具 ─────────────────────────────────────────────────────

  defp assign_roles_mutation(membership_id, role_names) do
    roles = Enum.map_join(role_names, ", ", &~s("#{&1}"))

    """
    mutation {
      assignRoles(id: "#{membership_id}", input: {roleNames: [#{roles}]}) {
        result { id }
        errors { message code }
      }
    }
    """
  end

  defp sign_in_token(user) do
    mutation = """
    mutation {
      signIn(login: "#{user.email}", password: "#{Fixtures.password()}") { id }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql(query, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode_reply({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end
end
