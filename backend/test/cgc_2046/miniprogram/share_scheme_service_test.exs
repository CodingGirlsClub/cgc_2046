defmodule Cgc2046.Miniprogram.ShareSchemeServiceTest do
  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Miniprogram.ShareScheme
  alias Cgc2046.Miniprogram.ShareSchemeService

  # P2 服务层契约（Tesla.Mock 008 模式，url_scheme_test.exs 先例）：
  # - 复用命中零外呼（关键断言，refute_receive）
  # - clamp：deadline+7d 与 now+30d 截断 / nil → now+30d（两 kind 同规则，
  #   plan owner 2026-08-18 应答选 A）
  # - errcode 传播不落库
  # - 安全红线：scheme query 只含 id+kind（断言请求体 jump_wxa.query 键集）

  setup do
    admin = Fixtures.platform_admin("share-scheme-admin")
    workspace = Fixtures.create_workspace(admin)
    %{workspace: workspace, admin: admin}
  end

  defp mock_scheme(test_pid, link \\ "weixin://dl/business/?t=GEN") do
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/wxa/generatescheme" <> _} = env ->
        send(test_pid, {:scheme_request, Jason.decode!(env.body)})
        Tesla.Mock.json(%{"openlink" => link})
    end)
  end

  describe "fetch_or_generate/2 复用（D2-A）" do
    test "命中未过期记录：返回复用且零外呼", %{workspace: workspace, admin: admin} do
      event = EventFixtures.create_event(workspace, admin)
      mock_scheme(self())

      assert {:ok, first} = ShareSchemeService.fetch_or_generate(:event, event.id)
      assert first.openlink == "weixin://dl/business/?t=GEN"
      assert_receive {:scheme_request, _}

      assert {:ok, second} = ShareSchemeService.fetch_or_generate(:event, event.id)
      assert second.id == first.id
      assert second.openlink == first.openlink
      # 复用生效的关键断言：第二次调用零外呼
      refute_receive {:scheme_request, _}
    end

    test "过期记录：重新生成并 upsert 覆盖（同 id）", %{workspace: workspace, admin: admin} do
      event = EventFixtures.create_event(workspace, admin)

      # 直接落一条已过期记录（资源 upsert 先例路径）
      {:ok, stale} =
        ShareScheme
        |> Ash.Changeset.for_create(:create, %{
          target_kind: :event,
          target_id: event.id,
          platform: :wechat,
          openlink: "weixin://dl/business/?t=STALE",
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        })
        |> Ash.create(authorize?: false)

      mock_scheme(self(), "weixin://dl/business/?t=REFRESH")

      assert {:ok, fresh} = ShareSchemeService.fetch_or_generate(:event, event.id)
      assert fresh.id == stale.id
      assert fresh.openlink == "weixin://dl/business/?t=REFRESH"
      assert DateTime.compare(fresh.expires_at, DateTime.utc_now()) == :gt
      assert_receive {:scheme_request, _}
    end
  end

  describe "fetch_or_generate/2 clamp（D-1，时间源 = registration_deadline，answer 选 A）" do
    test "deadline 近期：expires_at = deadline+7d", %{workspace: workspace, admin: admin} do
      deadline = DateTime.add(DateTime.utc_now(), 3, :day)
      event = EventFixtures.create_event(workspace, admin, %{registration_deadline: deadline})
      mock_scheme(self())

      assert {:ok, scheme} = ShareSchemeService.fetch_or_generate(:event, event.id)
      expected = DateTime.add(deadline, 7, :day)
      assert_in_range(scheme.expires_at, expected)
    end

    test "deadline+7d > now+30d：截断为 now+30d（event kind）", %{workspace: workspace, admin: admin} do
      deadline = DateTime.add(DateTime.utc_now(), 60, :day)
      event = EventFixtures.create_event(workspace, admin, %{registration_deadline: deadline})
      mock_scheme(self())

      assert {:ok, scheme} = ShareSchemeService.fetch_or_generate(:event, event.id)
      assert_in_range(scheme.expires_at, DateTime.add(DateTime.utc_now(), 30, :day))
    end

    test "deadline 缺失：now+30d（course kind）", %{workspace: workspace, admin: admin} do
      course =
        EventFixtures.create_course(workspace, admin, %{registration_deadline: nil})

      mock_scheme(self())

      assert {:ok, scheme} = ShareSchemeService.fetch_or_generate(:course, course.id)
      assert_in_range(scheme.expires_at, DateTime.add(DateTime.utc_now(), 30, :day))
    end
  end

  describe "fetch_or_generate/2 错误路径" do
    test "errcode 44990：传播且不落库", %{workspace: workspace, admin: admin} do
      event = EventFixtures.create_event(workspace, admin)

      Tesla.Mock.mock(fn
        %{method: :post, url: "https://api.weixin.qq.com/wxa/generatescheme" <> _} ->
          Tesla.Mock.json(%{
            "errcode" => 44990,
            "errmsg" => "reach max api second frequence limit"
          })
      end)

      assert {:error, {:platform_rejected, 44990, "reach max api second frequence limit"}} =
               ShareSchemeService.fetch_or_generate(:event, event.id)

      assert Ash.count!(ShareScheme, authorize?: false) == 0
    end

    test "errcode 40002：传播且不落库（course kind）", %{workspace: workspace, admin: admin} do
      course = EventFixtures.create_course(workspace, admin)

      Tesla.Mock.mock(fn
        %{method: :post, url: "https://api.weixin.qq.com/wxa/generatescheme" <> _} ->
          Tesla.Mock.json(%{"errcode" => 40002, "errmsg" => "invalid grant type"})
      end)

      assert {:error, {:platform_rejected, 40002, "invalid grant type"}} =
               ShareSchemeService.fetch_or_generate(:course, course.id)

      assert Ash.count!(ShareScheme, authorize?: false) == 0
    end

    test "目标不存在：{:error, :not_found} 且零外呼" do
      mock_scheme(self())

      assert {:error, :not_found} =
               ShareSchemeService.fetch_or_generate(
                 :event,
                 "00000000-0000-4000-8000-00000000dead"
               )

      refute_receive {:scheme_request, _}
    end
  end

  describe "安全红线（spike §5）" do
    test "scheme query 只含 id+kind：断言请求体无任何敏感键", %{workspace: workspace, admin: admin} do
      course = EventFixtures.create_course(workspace, admin)
      mock_scheme(self())

      assert {:ok, _} = ShareSchemeService.fetch_or_generate(:course, course.id)

      assert_receive {:scheme_request,
                      %{"jump_wxa" => %{"path" => path, "query" => query}} = body}

      assert path == "/pages/event-detail/index"
      assert query == "id=#{course.id}&kind=course"

      # 请求体整体只含 jump_wxa + is_expire + expire_time，无 token/openid/phone 等键
      assert Map.keys(body) |> Enum.sort() == ["expire_time", "is_expire", "jump_wxa"]
      assert body["jump_wxa"] |> Map.keys() |> Enum.sort() == ["path", "query"]
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp assert_in_range(actual, expected) do
    assert DateTime.compare(actual, DateTime.add(expected, -5, :second)) in [:gt, :eq]
    assert DateTime.compare(actual, DateTime.add(expected, 5, :second)) in [:lt, :eq]
  end
end
