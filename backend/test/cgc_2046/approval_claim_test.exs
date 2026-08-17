defmodule Cgc2046.ApprovalClaimTest do
  @moduledoc """
  原子抢占唯一真源（Cgc2046.ApprovalClaim）契约测试（plan 2026-08-17-001 D9）。

  表驱动契约（join_requests 表，直接 SQL 布置行——测原语非测资源 action）：
  from 数组 / set 取值（字面值、{:arg, atom}、{:sql, fragment}）/ deadline 双方向
  / extra_where（含占位符重编号）/ returning 回读 / nil-deadline 放行 / ==now 双方向
  边界 / 二次抢占 0 行 / SQL 守卫 ≡ ApprovalDeadline 谓词对偶（D8）/ 参数校验。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.ApprovalClaim
  alias Cgc2046.Repo

  setup do
    workspace = Fixtures.create_workspace(Fixtures.platform_admin("aclaim-admin"))

    %{workspace: workspace}
  end

  defp insert_join_request!(workspace, attrs \\ []) do
    user = Fixtures.register_user("aclaim-row")
    id = Ecto.UUID.generate()
    status = Keyword.get(attrs, :status, "pending")
    deadline = Keyword.get(attrs, :deadline)
    message = Keyword.get(attrs, :message)

    {:ok, _} =
      Repo.query(
        """
        INSERT INTO join_requests (id, workspace_id, user_id, status, approval_deadline, message)
        VALUES ($1, $2, $3, $4, $5, $6)
        """,
        [Repo.uuid!(id), Repo.uuid!(workspace.id), Repo.uuid!(user.id), status, deadline, message]
      )

    %{id: id, status: status, deadline: deadline, message: message}
  end

  # join_request approve 同构 claim（:future 方向，复用同一 now 变量）
  defp claim_future(record, now) do
    ApprovalClaim.claim(record,
      table: :join_requests,
      from: [:pending],
      set: [
        status: "approved",
        approved_at: {:arg, :now},
        approved_by: {:arg, :actor_id}
      ],
      deadline: {:approval_deadline, :future},
      now: now,
      actor_id: Repo.uuid!(Ecto.UUID.generate())
    )
  end

  # 过期方向 claim（:passed 方向，prepare_expire 同构）
  defp claim_passed(record, now) do
    ApprovalClaim.claim(record,
      table: :join_requests,
      from: [:pending],
      set: [status: "expired", expired_at: {:arg, :now}],
      deadline: {:approval_deadline, :passed},
      now: now
    )
  end

  describe "claim/2 基础契约" do
    test "set 字面值 + from 守卫 + deadline :future 命中 → {:ok, %{}} 且行已更新",
         %{workspace: ws} do
      now = DateTime.utc_now()
      record = insert_join_request!(ws, deadline: DateTime.add(now, 3_600, :second))

      assert {:ok, %{}} = claim_future(record, now)

      {:ok, %{rows: [[status, approved_by]]}} =
        Repo.query("SELECT status, approved_by FROM join_requests WHERE id = $1", [
          Repo.uuid!(record.id)
        ])

      assert status == "approved"
      assert is_binary(approved_by)
    end

    test "from 守卫：非 pending 行 0 行", %{workspace: ws} do
      now = DateTime.utc_now()
      record = insert_join_request!(ws, status: "rejected")

      assert {:error, :not_claimed} = claim_future(record, now)
    end

    test "未知 table 拒绝（编译期枚举）", %{workspace: ws} do
      now = DateTime.utc_now()
      record = insert_join_request!(ws)

      assert_raise ArgumentError, fn ->
        ApprovalClaim.claim(record,
          table: :join_requests_evil,
          from: [:pending],
          set: [status: "approved"],
          now: now
        )
      end
    end

    test "from 空列表/非 atom 拒绝", %{workspace: ws} do
      now = DateTime.utc_now()
      record = insert_join_request!(ws)

      assert_raise ArgumentError, fn ->
        ApprovalClaim.claim(record, table: :join_requests, from: [], set: [status: "x"], now: now)
      end

      assert_raise ArgumentError, fn ->
        ApprovalClaim.claim(record,
          table: :join_requests,
          from: ["pending"],
          set: [status: "x"],
          now: now
        )
      end
    end
  end

  describe "claim/2 deadline 双方向边界" do
    test ":future 四边界：nil 放行 / ==now 拒绝 / <now 拒绝 / >now 命中",
         %{workspace: ws} do
      # 列是 timestamp(0)（秒精度）：now 截断到秒，保证==now 边界经 DB 往返后仍精确
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      nil_record = insert_join_request!(ws, deadline: nil)
      assert {:ok, %{}} = claim_future(nil_record, now)

      eq_record = insert_join_request!(ws, deadline: now)
      assert {:error, :not_claimed} = claim_future(eq_record, now)

      past_record = insert_join_request!(ws, deadline: DateTime.add(now, -1, :second))
      assert {:error, :not_claimed} = claim_future(past_record, now)

      future_record = insert_join_request!(ws, deadline: DateTime.add(now, 1, :second))
      assert {:ok, %{}} = claim_future(future_record, now)
    end

    test ":passed 四边界：nil 拒绝 / ==now 拒绝 / <now 命中 / >now 拒绝",
         %{workspace: ws} do
      # 列是 timestamp(0)（秒精度）：now 截断到秒，保证==now 边界经 DB 往返后仍精确
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      nil_record = insert_join_request!(ws, deadline: nil)
      assert {:error, :not_claimed} = claim_passed(nil_record, now)

      eq_record = insert_join_request!(ws, deadline: now)
      assert {:error, :not_claimed} = claim_passed(eq_record, now)

      past_record = insert_join_request!(ws, deadline: DateTime.add(now, -1, :second))
      assert {:ok, %{}} = claim_passed(past_record, now)

      future_record = insert_join_request!(ws, deadline: DateTime.add(now, 1, :second))
      assert {:error, :not_claimed} = claim_passed(future_record, now)
    end

    test "SQL 守卫 ≡ ApprovalDeadline 谓词对偶（D8：同输入下行为一致）",
         %{workspace: ws} do
      # 列是 timestamp(0)（秒精度）：now 截断到秒，deadline 与 SQL 守卫、Elixir 谓词
      # 三者看到同一存储值（生产路径经 Ash :utc_datetime 同为秒精度落库）
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # {deadline_delta, not_expired?, overdue?}
      for {delta, not_expired?, overdue?} <- [
            {nil, true, false},
            {-1, false, true},
            {0, false, false},
            {1, true, false}
          ] do
        deadline = if is_nil(delta), do: nil, else: DateTime.add(now, delta, :second)

        assert match?({:ok, _}, claim_future(insert_join_request!(ws, deadline: deadline), now)) ==
                 not_expired?

        assert match?({:ok, _}, claim_passed(insert_join_request!(ws, deadline: deadline), now)) ==
                 overdue?
      end
    end
  end

  describe "claim/2 set 与 extra_where" do
    test "set {:arg, atom} 取值 + {:sql, fragment} 内联", %{workspace: ws} do
      now = DateTime.utc_now()
      record = insert_join_request!(ws, deadline: DateTime.add(now, 3_600, :second))
      actor_uuid = Repo.uuid!(Ecto.UUID.generate())

      assert {:ok, %{}} =
               ApprovalClaim.claim(record,
                 table: :join_requests,
                 from: [:pending],
                 set: [
                   status: {:arg, :status},
                   approved_by: {:arg, :actor_id},
                   approved_at: {:arg, :now},
                   updated_at: {:sql, "NOW()"}
                 ],
                 deadline: {:approval_deadline, :future},
                 status: "approved",
                 actor_id: actor_uuid,
                 now: now
               )

      {:ok, %{rows: [[status, approved_by]]}} =
        Repo.query("SELECT status, approved_by FROM join_requests WHERE id = $1", [
          Repo.uuid!(record.id)
        ])

      assert status == "approved"
      assert approved_by == actor_uuid
    end

    test "extra_where 命中/未命中 + 占位符重编号", %{workspace: ws} do
      now = DateTime.utc_now()

      hit =
        insert_join_request!(ws,
          deadline: DateTime.add(now, 3_600, :second),
          message: "let me in"
        )

      assert {:ok, %{}} =
               ApprovalClaim.claim(hit,
                 table: :join_requests,
                 from: [:pending],
                 set: [status: "approved", approved_at: {:arg, :now}],
                 deadline: {:approval_deadline, :future},
                 extra_where: {"message = $1", ["let me in"]},
                 now: now
               )

      miss =
        insert_join_request!(ws,
          deadline: DateTime.add(now, 3_600, :second),
          message: "wrong note"
        )

      assert {:error, :not_claimed} =
               ApprovalClaim.claim(miss,
                 table: :join_requests,
                 from: [:pending],
                 set: [status: "approved", approved_at: {:arg, :now}],
                 deadline: {:approval_deadline, :future},
                 extra_where: {"message = $1", ["let me in"]},
                 now: now
               )
    end

    test "deadline 守卫但 set 无 {:arg, :now} → 编程错误", %{workspace: ws} do
      record = insert_join_request!(ws)

      assert_raise ArgumentError, fn ->
        ApprovalClaim.claim(record,
          table: :join_requests,
          from: [:pending],
          set: [status: "approved"],
          deadline: {:approval_deadline, :future}
        )
      end
    end
  end

  describe "claim/2 returning 与二次抢占" do
    test "returning 列值回读", %{workspace: ws} do
      now = DateTime.utc_now()
      record = insert_join_request!(ws, deadline: DateTime.add(now, 3_600, :second))

      assert {:ok, %{status: "approved"}} =
               ApprovalClaim.claim(record,
                 table: :join_requests,
                 from: [:pending],
                 set: [status: "approved", approved_at: {:arg, :now}],
                 deadline: {:approval_deadline, :future},
                 returning: [:status],
                 now: now
               )
    end

    test "二次抢占 → 0 行（原子性：首个赢家后不再命中）", %{workspace: ws} do
      now = DateTime.utc_now()
      record = insert_join_request!(ws, deadline: DateTime.add(now, 3_600, :second))

      assert {:ok, %{}} = claim_future(record, now)
      assert {:error, :not_claimed} = claim_future(record, now)
    end
  end
end
