defmodule Cgc2046.Reconciliation.FindingTest do
  @moduledoc """
  Reconciliation.Finding 资源测试（E-10 #125，D1/D9）。

  覆盖：policy 门控（仅 PlatformAdmin 可读，worker 平台读旁路）、create/refresh
  时间戳语义（refresh 保 first_seen_at）、唯一索引 (rule, entity_type, entity_id)、
  apply_rule/3 全量拍钉测（#848：命中刷新 + 未命中删除 + 新实体落库）。
  """

  use Cgc2046.DataCase, async: true
  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Reconciliation.Finding

  defp create_finding(attrs \\ %{}) do
    assert {:ok, finding} =
             Finding
             |> Ash.Changeset.for_create(
               :create,
               Map.merge(
                 %{
                   rule: :confirmed_enrollment_without_run,
                   entity_type: :enrollment,
                   entity_id: Ecto.UUID.generate(),
                   detail: %{user_id: Ecto.UUID.generate()}
                 },
                 Map.new(attrs)
               )
             )
             |> Ash.create(authorize?: false)

    finding
  end

  describe "policy（D1：read 仅 PlatformAdmin）" do
    test "平台管理员可读" do
      admin = Fixtures.platform_admin("finding-admin")
      finding = create_finding()

      assert Ash.get!(Finding, finding.id, actor: admin).id == finding.id
    end

    test "非平台管理员拒读" do
      user = Fixtures.register_user("finding-user")
      finding = create_finding()

      assert {:error, error} = Ash.get(Finding, finding.id, actor: user)
      assert Exception.message(error) =~ "forbidden"
    end

    test "匿名拒读" do
      finding = create_finding()

      assert {:error, error} = Ash.get(Finding, finding.id, actor: nil)
      assert Exception.message(error) =~ "forbidden"
    end

    test "扫描 worker 平台读旁路（authorize?: false）不依赖 actor" do
      finding = create_finding()
      assert Ash.get!(Finding, finding.id, authorize?: false).id == finding.id
    end
  end

  describe "create/refresh 时间戳语义（D2 刷新语义）" do
    test "create：first_seen_at = last_seen_at = now" do
      finding = create_finding()
      refute is_nil(finding.first_seen_at)
      assert finding.first_seen_at == finding.last_seen_at
    end

    test "refresh：保 first_seen_at、刷新 last_seen_at、覆盖 detail" do
      finding = create_finding(detail: %{cause: "original"})

      # 回拨 last_seen_at，验证 refresh 只推 last_seen_at（first_seen_at 不动）
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE reconciliation_findings SET last_seen_at = NOW() - INTERVAL '1 day' WHERE id = $1",
          [Ecto.UUID.dump!(finding.id)]
        )

      original_first = finding.first_seen_at

      assert {:ok, refreshed} =
               finding
               |> Ash.Changeset.for_update(:refresh, %{detail: %{cause: "seen again"}})
               |> Ash.update(authorize?: false)

      assert refreshed.first_seen_at == original_first
      assert DateTime.compare(refreshed.last_seen_at, original_first) == :gt
      # jsonb 落库后键为字符串形态
      assert refreshed.detail == %{"cause" => "seen again"}
    end
  end

  describe "唯一索引（(rule, entity_type, entity_id) 判重键）" do
    test "同规则同实体重复 create 报唯一冲突" do
      entity_id = Ecto.UUID.generate()
      create_finding(entity_id: entity_id)

      assert {:error, error} =
               Finding
               |> Ash.Changeset.for_create(:create, %{
                 rule: :confirmed_enrollment_without_run,
                 entity_type: :enrollment,
                 entity_id: entity_id
               })
               |> Ash.create(authorize?: false)

      # identity 先于 DB 唯一索引触发（"has already been taken"）
      assert Exception.message(error) =~ "taken"
    end
  end

  describe "apply_rule/3（D2 共享驱动全量拍；#848 钉现状）" do
    test "命中已有记录 → 刷新 last_seen_at、保 first_seen_at、覆盖 detail" do
      finding = create_finding(detail: %{cause: "original"})

      # 回拨 last_seen_at：apply_rule 命中后只推 last_seen_at（first_seen_at 不动）
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE reconciliation_findings SET last_seen_at = NOW() - INTERVAL '1 day' WHERE id = $1",
          [Ecto.UUID.dump!(finding.id)]
        )

      original_first = finding.first_seen_at

      :ok =
        Finding.apply_rule(:confirmed_enrollment_without_run, [
          %{
            entity_type: :enrollment,
            entity_id: finding.entity_id,
            workspace_id: nil,
            detail: %{cause: "seen again"}
          }
        ])

      refreshed = Ash.get!(Finding, finding.id, authorize?: false)
      assert refreshed.first_seen_at == original_first
      assert DateTime.compare(refreshed.last_seen_at, original_first) == :gt
      assert refreshed.detail == %{"cause" => "seen again"}
    end

    test "新实体落新记录；本轮未命中的旧记录被删" do
      stale = create_finding(detail: %{cause: "stale"})
      fresh_id = Ecto.UUID.generate()

      :ok =
        Finding.apply_rule(:confirmed_enrollment_without_run, [
          %{
            entity_type: :enrollment,
            entity_id: fresh_id,
            workspace_id: nil,
            detail: %{cause: "fresh"}
          }
        ])

      # 未命中候选的旧记录被删（无孤儿 → 空报告由结构保证）
      assert [] =
               Finding
               |> Ash.Query.filter(id == ^stale.id)
               |> Ash.read!(authorize?: false)

      # 新候选落新记录（first_seen_at = last_seen_at = now）
      created =
        Finding
        |> Ash.Query.filter(rule == :confirmed_enrollment_without_run and entity_id == ^fresh_id)
        |> Ash.read_one!(authorize?: false)

      assert created.first_seen_at == created.last_seen_at
      assert created.detail == %{"cause" => "fresh"}
    end
  end

  describe "apply_rule/3 sweep 模式（#848）" do
    test ":partial（降级拍）——upsert 照常，未命中的旧记录保留" do
      stale = create_finding(detail: %{cause: "stale"})
      fresh_id = Ecto.UUID.generate()

      :ok =
        Finding.apply_rule(
          :confirmed_enrollment_without_run,
          [
            %{
              entity_type: :enrollment,
              entity_id: fresh_id,
              workspace_id: nil,
              detail: %{cause: "degraded hit"}
            }
          ],
          sweep: :partial
        )

      # 账单面残缺下「未命中即删」不成立：旧记录保留
      assert Ash.get!(Finding, stale.id, authorize?: false).id == stale.id

      # upsert 照常：新实体仍落新记录
      created =
        Finding
        |> Ash.Query.filter(rule == :confirmed_enrollment_without_run and entity_id == ^fresh_id)
        |> Ash.read_one!(authorize?: false)

      assert created.detail == %{"cause" => "degraded hit"}
    end

    test ":one_shot（单事件拍）——命中刷新 last_seen_at，旧记录保留" do
      finding = create_finding(detail: %{cause: "original"})

      # 回拨 last_seen_at：one_shot 命中后必被推回（Q2：不再冻结）
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Cgc2046.Repo,
          "UPDATE reconciliation_findings SET last_seen_at = NOW() - INTERVAL '1 day' WHERE id = $1",
          [Ecto.UUID.dump!(finding.id)]
        )

      stale = create_finding(detail: %{cause: "unrelated stale"})

      original_first = finding.first_seen_at

      :ok =
        Finding.apply_rule(
          :confirmed_enrollment_without_run,
          [
            %{
              entity_type: :enrollment,
              entity_id: finding.entity_id,
              workspace_id: nil,
              detail: %{cause: "hit again"}
            }
          ],
          sweep: :one_shot
        )

      refreshed = Ash.get!(Finding, finding.id, authorize?: false)
      assert refreshed.first_seen_at == original_first
      assert DateTime.compare(refreshed.last_seen_at, original_first) == :gt

      # 单事件拍无全量视图：未涉及的旧记录保留，本条也只刷新不删
      assert Ash.get!(Finding, stale.id, authorize?: false).id == stale.id
      assert refreshed.id == finding.id
    end

    test "非法 sweep 值被拒绝" do
      assert_raise ArgumentError, ~r/unknown sweep mode/, fn ->
        Finding.apply_rule(:confirmed_enrollment_without_run, [], sweep: :sometimes)
      end
    end
  end
end
