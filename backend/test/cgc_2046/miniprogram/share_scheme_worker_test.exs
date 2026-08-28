defmodule Cgc2046.Miniprogram.ShareSchemeWorkerTest do
  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Miniprogram.ShareScheme
  alias Cgc2046.Miniprogram.ShareSchemeWorker

  # P3 worker 契约：job → fetch_or_generate（外呼在 Oban 异步路径）；
  # :not_found → warning + :ok（answer 拍板：不重试）；平台错误走 Oban 默认重试。
  require Ash.Query
  alias Cgc2046.AccountsFixtures, as: Fixtures

  setup do
    test_pid = self()

    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/wxa/generatescheme" <> _} = env ->
        send(test_pid, {:scheme_request, Jason.decode!(env.body)})
        Tesla.Mock.json(%{"openlink" => "weixin://dl/business/?t=WORKER"})
    end)

    admin = Fixtures.platform_admin("ssw-admin")
    workspace = Fixtures.create_workspace(admin)
    %{workspace: workspace, admin: admin}
  end

  test "job 执行 → fetch_or_generate 成功落库", %{workspace: workspace, admin: admin} do
    event = EventFixtures.create_event(workspace, admin)

    assert :ok =
             perform_job(ShareSchemeWorker, %{
               target_kind: "event",
               target_id: event.id
             })

    assert {:ok, scheme} =
             ShareScheme
             |> Ash.Query.filter(target_id == ^event.id)
             |> Ash.read_one(authorize?: false)

    assert scheme.openlink == "weixin://dl/business/?t=WORKER"
    assert_receive {:scheme_request, _}
  end

  test "重复执行幂等：第二次零外呼（fetch_or_generate 复用）", %{
    workspace: workspace,
    admin: admin
  } do
    course = EventFixtures.create_course(workspace, admin)
    args = %{target_kind: "course", target_id: course.id}

    assert :ok = perform_job(ShareSchemeWorker, args)
    assert :ok = perform_job(ShareSchemeWorker, args)
    assert_receive {:scheme_request, _}
    refute_receive {:scheme_request, _}

    assert Ash.count!(ShareScheme, authorize?: false) == 1
  end

  test "目标不存在 → :ok 不重试（warning 路径）" do
    assert :ok =
             perform_job(ShareSchemeWorker, %{
               target_kind: "event",
               target_id: "00000000-0000-4000-8000-00000000dead"
             })

    refute_receive {:scheme_request, _}
    assert Ash.count!(ShareScheme, authorize?: false) == 0
  end

  test "平台限频 44990 → {:error, _} 交 Oban 默认重试", %{workspace: workspace, admin: admin} do
    event = EventFixtures.create_event(workspace, admin)

    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/wxa/generatescheme" <> _} ->
        Tesla.Mock.json(%{"errcode" => 44990, "errmsg" => "reach max api second frequence limit"})
    end)

    assert {:error, {:platform_rejected, 44990, _}} =
             perform_job(ShareSchemeWorker, %{
               target_kind: "event",
               target_id: event.id
             })

    assert Ash.count!(ShareScheme, authorize?: false) == 0
  end
end
