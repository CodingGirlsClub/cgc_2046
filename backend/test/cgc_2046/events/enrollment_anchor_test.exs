defmodule Cgc2046.Events.EnrollmentAnchorTest do
  @moduledoc """
  learning 锚定单源（Enrollment.anchor/anchored_id）单测（架构深化 E；
  plan 2026-08-17-004 D6）。

  覆盖：anchored_id/1 双键超集（string 优先 / atom 兜底 / binary 直通 /
  无锚 / nil 防御）、anchor/1 无锚与读取失败坍缩 + 落库集成（存在 / 不存在）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures

  describe "anchored_id/1 双键提取（纯函数）" do
    test "binary 直通" do
      id = "11111111-1111-1111-1111-111111111111"
      assert {:ok, ^id} = Enrollment.anchored_id(id)
    end

    test "map string 键优先（双键超集）" do
      assert {:ok, "string-id"} =
               Enrollment.anchored_id(%{"enrollment_id" => "string-id", enrollment_id: "atom-id"})
    end

    test "map atom 键兜底（仅不可达 in-memory 输入）" do
      assert {:ok, "atom-id"} = Enrollment.anchored_id(%{enrollment_id: "atom-id"})
    end

    test "map 无锚 / 非 binary 值 → :no_enrollment_anchor" do
      assert {:error, :no_enrollment_anchor} = Enrollment.anchored_id(%{})
      assert {:error, :no_enrollment_anchor} = Enrollment.anchored_id(%{"event_id" => "x"})
      assert {:error, :no_enrollment_anchor} = Enrollment.anchored_id(%{"enrollment_id" => 42})
    end

    test "nil → :no_enrollment_anchor（防御 input_snapshot 可空，fail-closed 不放松）" do
      assert {:error, :no_enrollment_anchor} = Enrollment.anchored_id(nil)
    end
  end

  describe "anchor/1（错误坍缩 + 落库集成）" do
    test "无锚 → :no_enrollment_anchor（不触 DB）" do
      assert {:error, :no_enrollment_anchor} = Enrollment.anchor(%{})
      assert {:error, :no_enrollment_anchor} = Enrollment.anchor(nil)
    end

    test "有锚但 enrollment 不存在 → :enrollment_read_failed" do
      assert {:error, :enrollment_read_failed} =
               Enrollment.anchor("99999999-9999-4999-8999-999999999999")
    end

    test "落库集成：存在 → {:ok, %Enrollment{}}（binary 与 string 键 map 等价）" do
      admin = Fixtures.platform_admin("anchor-exists")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("anchor-learner")

      {:ok, enrollment} =
        Enrollment
        |> Ash.Changeset.for_create(:create_enrollment, %{
          event_id: event.id,
          user_id: learner.id
        })
        |> Ash.create(tenant: workspace.id, actor: learner)

      assert {:ok, %Enrollment{} = found} = Enrollment.anchor(enrollment.id)
      assert found.id == enrollment.id
      assert found.status == :confirmed

      # 信号 payload 形状（string 键）同样可锚
      assert {:ok, %Enrollment{id: payload_id}} =
               Enrollment.anchor(%{"enrollment_id" => enrollment.id})

      assert payload_id == enrollment.id
    end
  end
end
