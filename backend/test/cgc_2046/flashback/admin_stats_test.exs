defmodule Cgc2046.Flashback.AdminStatsTest do
  @moduledoc """
  U11/R24/KTD10 看板度量契约 + R25 兑换队列。

  合成事件流钉住：分子（touch distinct person）/ 分母（sent 送达，硬退信与
  退订剔除）/ 分线（participation）。变异验证（随附记录）：分母去掉退订
  剔除 / 分子改 count 非 distinct → 对应断言红。
  """
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{AdminStats, Person}
  alias Cgc2046.Repo

  @moduletag :capture_log

  defp create_archive(key \\ "2014-01-11-bj") do
    Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: key,
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, participation, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: archive.id,
          full_name: "人#{n}",
          surname: "人",
          city: "北京",
          role: :learner,
          participation: participation,
          phone: "139#{String.pad_leading(Integer.to_string(rem(n, 100_000_000)), 8, "0")}",
          email: "p#{n}@example.com"
        },
        Map.new(attrs)
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp touch(person, events) do
    Enum.each(events, fn event ->
      Flashback.Touch
      |> Ash.Changeset.for_create(:create, %{person_id: person.id, event: event})
      |> Ash.create!(authorize?: false)
    end)
  end

  # outreach 行：sent（送达）/ failed（硬退信）；退订由 person 字段承载。
  # status 是 writable?: false（只由 worker 推进）——测试 force 落列。
  defp outreach(person, status) do
    Flashback.Outreach
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      channel: :email,
      template: "reconnect",
      batch: "test-batch"
    })
    |> Ash.Changeset.force_change_attribute(:status, status)
    |> Ash.create!(authorize?: false)
  end

  defp unsubscribe(person) do
    person
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:outreach_unsubscribed_at, DateTime.utc_now())
    |> Ash.update!(authorize?: false)
  end

  describe "四率 + 分线（KTD10 度量契约）" do
    test "分子=distinct person（重复 touch 不重计）；分母=sent 送达；分线正确" do
      archive = create_archive()

      # 记忆线：2 人送达——A 走完全漏斗（重复打开不重计），B 只打开
      memory_a = create_person(archive, :attended)
      memory_b = create_person(archive, :attended)
      # 圆梦线：1 人送达走完，1 人硬退信（不进分母）
      dream_c = create_person(archive, :not_selected)
      dream_bounced = create_person(archive, :not_selected)
      # 退订者：曾送达、曾打开——分母分子双双剔除
      unsubscribed = create_person(archive, :attended)

      outreach(memory_a, :sent)
      outreach(memory_b, :sent)
      outreach(dream_c, :sent)
      outreach(dream_bounced, :failed)
      outreach(unsubscribed, :sent)
      unsubscribe(unsubscribed)

      touch(memory_a, [:link_opened, :link_opened, :revealed, :sent_to_wall, :intent_submitted])
      touch(memory_b, [:link_opened])
      touch(dream_c, [:link_opened, :revealed, :intent_submitted])
      touch(unsubscribed, [:link_opened])

      assert {:ok, stats} = AdminStats.stats()

      assert stats.memory == %{
               delivered: 2,
               link_opened: 2,
               revealed: 1,
               sent_to_wall: 1,
               intent_submitted: 1
             }

      assert stats.dream == %{
               delivered: 1,
               link_opened: 1,
               revealed: 1,
               sent_to_wall: 0,
               intent_submitted: 1
             }

      assert stats.overall == %{
               delivered: 3,
               link_opened: 3,
               revealed: 2,
               sent_to_wall: 1,
               intent_submitted: 2
             }
    end

    test "空库全零（pilot 前看板可用）" do
      assert {:ok, stats} = AdminStats.stats()

      assert stats.overall == %{
               delivered: 0,
               link_opened: 0,
               revealed: 0,
               sent_to_wall: 0,
               intent_submitted: 0
             }
    end
  end

  describe "兑换申请（R25：一人一行幂等 + 状态机 fail-closed）" do
    test "提交幂等：再交=更新渠道信息，状态不动；队列掩码署名" do
      archive = create_archive()
      person = create_person(archive, :attended)

      assert {:ok, %{status: "pending"}} =
               AdminStats.submit(person.id, "支付宝 138****5678")

      assert {:ok, %{status: "pending"}} =
               AdminStats.submit(person.id, "微信 wxid_updated")

      {:ok, rows} = AdminStats.redemptions()
      row = hd(rows)
      assert row.channel_note == "微信 wxid_updated"
      assert row.status == "pending"
      assert row.masked_name == "人**"
      # 一人一行
      assert length(rows) == 1
    end

    test "渠道信息过短被拒" do
      archive = create_archive()
      person = create_person(archive, :attended)

      assert {:error, %{code: "flashback_invalid_input"}} =
               AdminStats.submit(person.id, "短")
    end

    test "状态机：pending→contacted→settled 合法；settled→contacted 拒绝；不存在拒绝" do
      archive = create_archive()
      person = create_person(archive, :attended)
      AdminStats.submit(person.id, "支付宝 someone@example.com")

      {:ok, rows} = AdminStats.redemptions()
      id = hd(rows).id

      assert {:ok, %{status: "contacted"}} = AdminStats.update_status(id, "contacted", "已电话联系")
      assert {:ok, %{status: "settled"}} = AdminStats.update_status(id, "settled", "已打款")

      assert {:error, %{code: "flashback_redemption_invalid_transition"}} =
               AdminStats.update_status(id, "contacted", nil)

      assert {:error, %{code: "flashback_redemption_not_found"}} =
               AdminStats.update_status(Ecto.UUID.generate(), "settled", nil)
    end
  end

  describe "投影纪律（KTD3：导出与队列无手机/邮箱）" do
    test "redemptions 行不含明文联系方式列（channel_note 为用户主动提交项，键白名单外无 PII 列）" do
      archive = create_archive()
      person = create_person(archive, :attended, %{})
      AdminStats.submit(person.id, "支付宝 test-channel")

      {:ok, rows} = AdminStats.redemptions()
      row = hd(rows) |> Map.delete(:channel_note)

      # 键白名单：结构性无 phone/email 字段
      refute Map.has_key?(row, :phone)
      refute Map.has_key?(row, :email)
      refute Map.has_key?(row, :full_name)
      assert Repo.aggregate(Person, :count) >= 1
    end
  end
end
