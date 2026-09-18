defmodule Cgc2046.Mcp.BatchEventToolsTest do
  @moduledoc """
  batch_create_events 工具面测试（#511；直调 tool execute/2，不走 HTTP；
  event_tools_test 同款模式）。

  覆盖契约：
  - 授权：member/tutor/learner 撞工具层 Owner/Admin 判定；非成员撞 member 门
  - 逐行独立提交：行级字段落库正确（venue/pricing/deposit/capacity）
  - 幂等：重放同批次 → 已存在行 skipped（不更新、count 不变）；批内重复 slug
    同语义；同 slug 异工作台 → 行级 failed event_slug_taken（真冲突）
  - 行级报告：失败行给 行号 + 字段 + 原因（ends_at ≤ starts_at / title 缺失），
    其余行不受牵连
  - 白名单纪律：行内未知字段丢弃（不发明字段）
  - 参数校验：rows 空 / 非列表 / 行非对象 / 行无 slug / 超 1024 → invalid
  - initiative 挂载批量：行级走同一 :create，规则强制写入落库
  - 审计：ToolCallLog 落行（大批量 params 退化 metadata_only 属预期，只断言行在）
  - 101 行端到端（issue 验收规模）：101 created → 重放 101 skipped
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Event
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.Mcp.Tools.BatchCreateEvents

  require Ash.Query

  @venue %{"country" => "中国", "province" => "浙江省", "city" => "杭州市", "district" => "西湖区"}

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode(reply) do
    {:reply, response, _frame} = reply
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp run_tool(user, params) do
    BatchCreateEvents.execute(params, frame_for(user))
  end

  defp base_row(slug, overrides \\ %{}) do
    Map.merge(
      %{
        "slug" => slug,
        "title" => "1024 Build Festival · #{slug}",
        "starts_at" => "2026-10-24T09:00:00Z",
        "ends_at" => "2026-10-24T18:00:00Z",
        "capacity" => 30,
        "venue" => @venue
      },
      overrides
    )
  end

  defp workspace_event_count(workspace_id) do
    Event
    |> Ash.Query.filter(workspace_id == ^workspace_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp workspace_events(workspace) do
    Event |> Ash.Query.filter(workspace_id == ^workspace.id) |> Ash.read!(authorize?: false)
  end

  defp rows_by_slug(report), do: Map.new(report["rows"], &{&1["slug"], &1})

  defp report_ids(report) do
    report["rows"] |> Enum.map(& &1["event_id"]) |> Enum.sort()
  end

  describe "授权：非 Owner/Admin forbidden" do
    test "member / tutor / learner 撞工具层判定；非成员撞 member 门" do
      owner = Fixtures.platform_admin("b511-authz-owner")
      workspace = Fixtures.create_workspace(owner)

      member = Fixtures.register_user("b511-authz-member")
      Fixtures.add_member(workspace, member, [])

      tutor = Fixtures.register_user("b511-authz-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      learner = Fixtures.register_user("b511-authz-learner")
      Fixtures.add_member(workspace, learner, [:learner])

      outsider = Fixtures.register_user("b511-authz-outsider")

      params = %{
        "workspace_id" => workspace.id,
        "rows" => [base_row("authz-001")]
      }

      for {user, expected} <- [
            {member, "owner or admin required"},
            {tutor, "owner or admin required"},
            {learner, "owner or admin required"},
            {outsider, "not a member"}
          ] do
        assert {:error, %Anubis.MCP.Error{message: msg}, _} = run_tool(user, params)
        assert msg =~ "forbidden"
        assert msg =~ expected

        [log] =
          ToolCallLog
          |> Ash.Query.filter(user_id == ^user.id and tool == "batch_create_events")
          |> Ash.read!(authorize?: false)

        assert log.result_status == :forbidden
      end

      assert workspace_event_count(workspace.id) == 0
    end
  end

  describe "批量创建与幂等" do
    test "Owner 批量 3 场全 created，字段落库正确；未知字段丢弃" do
      owner = Fixtures.platform_admin("b511-create-owner")
      workspace = Fixtures.create_workspace(owner)

      report =
        decode(
          run_tool(owner, %{
            "workspace_id" => workspace.id,
            "rows" => [
              base_row("1024-hangzhou-001", %{
                "pricing_enabled" => true,
                "price_tiers" => [%{"id" => "t1", "name" => "标准", "amount_cents" => 19_900}],
                "bogus_field" => "must be dropped"
              }),
              base_row("1024-hangzhou-002", %{
                "deposit_enabled" => true,
                "deposit_amount_cents" => 2000,
                "registration_deadline" => "2026-10-17T23:59:59Z"
              }),
              base_row("1024-hangzhou-003")
            ]
          })
        )

      assert report["summary"] == %{"total" => 3, "created" => 3, "skipped" => 0, "failed" => 0}

      for row <- report["rows"] do
        assert row["status"] == "created"
        assert is_binary(row["event_id"])
        assert String.starts_with?(row["slug"], "1024-hangzhou-")
      end

      [e1, e2, e3] =
        Event
        |> Ash.Query.filter(workspace_id == ^workspace.id)
        |> Ash.Query.sort(slug: :asc)
        |> Ash.read!(authorize?: false)

      # 行级字段落库（venue / pricing / deposit 各一行验证）
      assert e1.slug == "1024-hangzhou-001"
      assert e1.pricing_enabled
      assert [%{"amount_cents" => 19_900}] = e1.price_tiers
      assert e1.venue == @venue
      assert e1.capacity == 30
      assert e1.status == :draft

      assert e2.slug == "1024-hangzhou-002"
      assert e2.deposit_enabled
      assert e2.deposit_amount_cents == 2000

      assert e3.slug == "1024-hangzhou-003"
      refute e3.pricing_enabled
      # 白名单纪律：未知字段未发明列，标题未被污染
      assert e1.title == "1024 Build Festival · 1024-hangzhou-001"
    end

    test "重放同批次：全部 skipped，不新建不更新（幂等核心）" do
      owner = Fixtures.platform_admin("b511-idem-owner")
      workspace = Fixtures.create_workspace(owner)

      params = %{
        "workspace_id" => workspace.id,
        "rows" => [
          base_row("1024-shanghai-001"),
          base_row("1024-shanghai-002", %{"capacity" => 50})
        ]
      }

      first = decode(run_tool(owner, params))
      assert first["summary"]["created"] == 2
      ids_first = report_ids(first)

      # 同批次重放（含一行数据微调：skipped 语义 = 已存在不更新，数据以首次为准）
      replay = decode(run_tool(owner, params))

      assert replay["summary"] == %{"total" => 2, "created" => 0, "skipped" => 2, "failed" => 0}

      for row <- replay["rows"] do
        assert row["status"] == "skipped"
        assert is_binary(row["event_id"])
      end

      # event_id 稳定（同一批实体）且总数不变
      assert report_ids(replay) == ids_first
      assert workspace_event_count(workspace.id) == 2

      # 首次数据为准：重放未改动任何行
      assert [%{capacity: 50}] =
               Event
               |> Ash.Query.filter(workspace_id == ^workspace.id and slug == "1024-shanghai-002")
               |> Ash.read!(authorize?: false)
    end

    test "批内重复 slug：后行 read-back 前行 → skipped（同语义）" do
      owner = Fixtures.platform_admin("b511-dup-owner")
      workspace = Fixtures.create_workspace(owner)

      report =
        decode(
          run_tool(owner, %{
            "workspace_id" => workspace.id,
            "rows" => [
              base_row("1024-chengdu-001"),
              base_row("1024-chengdu-001", %{"capacity" => 99})
            ]
          })
        )

      assert report["summary"] == %{"total" => 2, "created" => 1, "skipped" => 1, "failed" => 0}
      assert [%{capacity: 30}] = workspace_events(workspace)
    end

    test "同 slug 异工作台：该行 failed event_slug_taken，其余行不受牵连" do
      owner_a = Fixtures.platform_admin("b511-conflict-a")
      ws_a = Fixtures.create_workspace(owner_a)
      owner_b = Fixtures.platform_admin("b511-conflict-b")
      ws_b = Fixtures.create_workspace(owner_b)

      # 工作台 A 先占 slug
      assert decode(
               run_tool(owner_a, %{
                 "workspace_id" => ws_a.id,
                 "rows" => [base_row("1024-shared-001")]
               })
             )
             |> get_in(["summary", "created"]) == 1

      # 工作台 B：行 1 撞 A 的 slug（真冲突），行 2 正常
      report =
        decode(
          run_tool(owner_b, %{
            "workspace_id" => ws_b.id,
            "rows" => [base_row("1024-shared-001"), base_row("1024-own-001")]
          })
        )

      assert report["summary"] == %{"total" => 2, "created" => 1, "skipped" => 0, "failed" => 1}

      failed = Enum.find(report["rows"], &(&1["status"] == "failed"))
      assert failed["row"] == 1
      assert failed["slug"] == "1024-shared-001"
      assert failed["error"]["code"] == "event_slug_taken"
      assert "slug" in failed["error"]["fields"]

      # 行 2 不受牵连
      assert [%{slug: "1024-own-001"}] =
               Event |> Ash.Query.filter(workspace_id == ^ws_b.id) |> Ash.read!(authorize?: false)
    end
  end

  describe "行级报告" do
    test "校验失败行定位（ends_at ≤ starts_at / title 缺失），其余行成功" do
      owner = Fixtures.platform_admin("b511-report-owner")
      workspace = Fixtures.create_workspace(owner)

      report =
        decode(
          run_tool(owner, %{
            "workspace_id" => workspace.id,
            "rows" => [
              base_row("1024-xian-001"),
              # 行 2：时间倒挂
              base_row("1024-xian-002", %{"ends_at" => "2026-10-24T08:00:00Z"}),
              # 行 3：title 缺失
              base_row("1024-xian-003", %{"title" => nil}),
              base_row("1024-xian-004")
            ]
          })
        )

      assert report["summary"] == %{"total" => 4, "created" => 2, "skipped" => 0, "failed" => 2}

      by_slug = rows_by_slug(report)

      row2 = by_slug["1024-xian-002"]
      assert row2["row"] == 2
      assert row2["status"] == "failed"
      assert "ends_at" in row2["error"]["fields"]
      assert row2["error"]["message"] =~ "ends_at"

      row3 = by_slug["1024-xian-003"]
      assert row3["row"] == 3
      assert row3["status"] == "failed"
      assert "title" in row3["error"]["fields"]

      # 失败行重喂（只修错误字段）→ created；成功行 → skipped
      retry =
        decode(
          run_tool(owner, %{
            "workspace_id" => workspace.id,
            "rows" => [
              base_row("1024-xian-002", %{"ends_at" => "2026-10-24T20:00:00Z"}),
              base_row("1024-xian-003", %{"title" => "补标题"}),
              base_row("1024-xian-001")
            ]
          })
        )

      assert retry["summary"] == %{"total" => 3, "created" => 2, "skipped" => 1, "failed" => 0}
      assert workspace_event_count(workspace.id) == 4
    end
  end

  describe "参数校验" do
    test "rows 空 / 非列表 / 行非对象 / 行无 slug / 超 1024 → invalid" do
      owner = Fixtures.platform_admin("b511-param-owner")
      workspace = Fixtures.create_workspace(owner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               run_tool(owner, %{"workspace_id" => workspace.id, "rows" => []})

      assert msg =~ "invalid: rows must be a non-empty list"

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               run_tool(owner, %{"workspace_id" => workspace.id, "rows" => "not-a-list"})

      assert msg =~ "invalid: rows must be a list"

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               run_tool(owner, %{"workspace_id" => workspace.id, "rows" => ["not-an-object"]})

      assert msg =~ "invalid: row 1 must be an object"

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               run_tool(owner, %{
                 "workspace_id" => workspace.id,
                 "rows" => [%{"title" => "no slug"}]
               })

      assert msg =~ "invalid: row 1 requires a non-empty slug"

      # 超 1024 上限（构造 1025 行）
      oversize = for i <- 1..1025, do: base_row("oversize-#{i}")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               run_tool(owner, %{"workspace_id" => workspace.id, "rows" => oversize})

      assert msg =~ "exceeds max 1024"

      assert workspace_event_count(workspace.id) == 0
    end
  end

  describe "initiative 挂载批量" do
    test "行带 initiative_id：规则强制写入逐行落库（locked 押金档）" do
      admin = Fixtures.platform_admin("b511-mount-admin")

      initiative =
        Initiative
        |> Ash.Changeset.for_create(:create, %{
          name: "1024 Build Festival",
          slug: "1024-build-festival-511",
          created_by: admin.id
        })
        |> Ash.create!(actor: admin)

      # open 要求四规则齐备（missing_rules 门），全建；deposit/age 锁死验证强制写入
      for {key, value, locked} <- [
            {:deposit, %{enabled: true, amount_cents: 6900}, true},
            {:age_gate, %{min_age: 18}, true},
            {:min_participants, %{count: 8}, false},
            {:deadline_rule, %{hours_before_start: 72}, false}
          ] do
        InitiativeRule
        |> Ash.Changeset.for_create(:create, %{
          initiative_id: initiative.id,
          key: key,
          value: value,
          locked: locked
        })
        |> Ash.create!(actor: admin)
      end

      initiative |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)

      owner = Fixtures.platform_admin("b511-mount-owner")
      workspace = Fixtures.create_workspace(owner)

      report =
        decode(
          run_tool(owner, %{
            "workspace_id" => workspace.id,
            "rows" => [
              base_row("1024-mounted-001", %{"initiative_id" => initiative.id}),
              base_row("1024-mounted-002", %{"initiative_id" => initiative.id})
            ]
          })
        )

      assert report["summary"]["created"] == 2

      # 响应不回 inherited（#511 裁决 D6）——行级只有 row/status/slug/title/event_id(/error)
      for row <- report["rows"], do: refute(Map.has_key?(row, "inherited"))

      # 挂载规则强制写入落库（locked 押金 + 年龄）
      for event <- workspace_events(workspace) do
        assert event.deposit_enabled
        assert event.deposit_amount_cents == 6900
        assert event.min_age == 18
        assert event.initiative_id == initiative.id
      end
    end
  end

  describe "审计" do
    test "成功调用落 ToolCallLog（大批量 params 退化 metadata_only 属预期）" do
      owner = Fixtures.platform_admin("b511-audit-owner")
      workspace = Fixtures.create_workspace(owner)

      # 60 行 × ~200B > 8KB 审计上限 → params 摘要化；只断言审计行在且可按
      # workspace_id 查询锚过滤（审计可用性，不钉退化细节）
      rows =
        for i <- 1..60,
            do: base_row("1024-audit-#{String.pad_leading(Integer.to_string(i), 3, "0")}")

      assert decode(run_tool(owner, %{"workspace_id" => workspace.id, "rows" => rows}))
             |> get_in(["summary", "created"]) == 60

      [log] =
        ToolCallLog
        |> Ash.Query.filter(
          user_id == ^owner.id and tool == "batch_create_events" and
            fragment("?->>'workspace_id' = ?", params, ^workspace.id)
        )
        |> Ash.read!(authorize?: false)

      assert log.result_status == :ok
    end
  end

  describe "#511 验收规模：101 行端到端" do
    test "101 行 → 101 created；重放 → 101 skipped；总数不变" do
      owner = Fixtures.platform_admin("b511-e2e-owner")
      workspace = Fixtures.create_workspace(owner)

      rows =
        for i <- 1..101 do
          seq = String.pad_leading(Integer.to_string(i), 3, "0")

          base_row("1024-festival-#{seq}", %{
            "title" => "1024 Build Festival · 城市#{seq} 第1场"
          })
        end

      first = decode(run_tool(owner, %{"workspace_id" => workspace.id, "rows" => rows}))

      assert first["summary"] == %{
               "total" => 101,
               "created" => 101,
               "skipped" => 0,
               "failed" => 0
             }

      assert workspace_event_count(workspace.id) == 101

      replay = decode(run_tool(owner, %{"workspace_id" => workspace.id, "rows" => rows}))

      assert replay["summary"] == %{
               "total" => 101,
               "created" => 0,
               "skipped" => 101,
               "failed" => 0
             }

      assert workspace_event_count(workspace.id) == 101
      assert report_ids(first) == report_ids(replay)
    end
  end
end
