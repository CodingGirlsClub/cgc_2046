defmodule Cgc2046.Miniprogram.LoginArtifactPrunerWorkerTest do
  @moduledoc """
  #252 登录支撑表清理测试：只删 expires_at 早于 now()-1day 的行，
  保留窗口内（含已过期未满 1 天）的行不动；cron 接线生效。
  """

  use Cgc2046Web.ConnCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Accounts.{PhoneVerificationCode, WechatLoginTicket}
  alias Cgc2046.Miniprogram.LoginArtifactPrunerWorker

  @phone "+8613800136000"

  defp insert_code_row(expires_at) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Cgc2046.Repo.insert_all("phone_verification_codes", [
      %{
        id: Cgc2046.Repo.uuid!(Ecto.UUID.generate()),
        phone: @phone,
        code_hash: "hash-" <> Ecto.UUID.generate(),
        purpose: "login",
        expires_at: DateTime.truncate(expires_at, :second),
        attempts_left: 3,
        consumed_at: nil,
        send_request_id: Ecto.UUID.generate(),
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp insert_ticket_row(expires_at) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Cgc2046.Repo.insert_all("wechat_login_tickets", [
      %{
        id: Cgc2046.Repo.uuid!(Ecto.UUID.generate()),
        state: Ecto.UUID.generate(),
        openid: nil,
        unionid: nil,
        access_token: nil,
        status: "pending",
        expires_at: DateTime.truncate(expires_at, :second),
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp count_rows(table) do
    {:ok, %Postgrex.Result{rows: [[count]]}} =
      Ecto.Adapters.SQL.query(Cgc2046.Repo, "SELECT count(*) FROM #{table}", [])

    count
  end

  test "删超过 1 天保留窗的行，窗口内（含已过期未满 1 天）不动" do
    hour = 3600

    # 过期超 1 天 → 删
    insert_code_row(DateTime.add(DateTime.utc_now(), -48 * hour, :second))
    insert_code_row(DateTime.add(DateTime.utc_now(), -25 * hour, :second))
    insert_ticket_row(DateTime.add(DateTime.utc_now(), -48 * hour, :second))

    # 窗口内：未过期 / 刚过期几分钟 / 未满 1 天 → 全保留
    insert_code_row(DateTime.add(DateTime.utc_now(), 5 * 60, :second))
    insert_code_row(DateTime.add(DateTime.utc_now(), -10 * 60, :second))
    insert_ticket_row(DateTime.add(DateTime.utc_now(), -23 * hour, :second))

    assert :ok = perform_job(LoginArtifactPrunerWorker, %{})

    # phone_verification_codes：4 行中 2 过期超 1 天删，2 窗口内留
    assert count_rows("phone_verification_codes") == 2
    # wechat_login_tickets：2 行中 1 过期删，1 窗口内（-23h）留
    assert count_rows("wechat_login_tickets") == 1
  end

  test "幂等：无过期行时零删除仍 :ok" do
    insert_code_row(DateTime.add(DateTime.utc_now(), 5 * 60, :second))

    assert :ok = perform_job(LoginArtifactPrunerWorker, %{})
    assert count_rows("phone_verification_codes") == 1

    # 二次执行不重复删/不报错
    assert :ok = perform_job(LoginArtifactPrunerWorker, %{})
    assert count_rows("phone_verification_codes") == 1
  end

  test "边界：cutoff 两侧 60s 一留一删（严格小于才删）" do
    # cutoff = perform 时刻的 now - 24h（秒级 truncate）
    keep_edge = DateTime.add(DateTime.utc_now(), -(24 * 3600 - 60), :second)
    del_edge = DateTime.add(DateTime.utc_now(), -(24 * 3600 + 120), :second)
    insert_ticket_row(keep_edge)
    insert_ticket_row(del_edge)

    assert :ok = perform_job(LoginArtifactPrunerWorker, %{})
    assert count_rows("wechat_login_tickets") == 1
  end

  describe "Oban 接线" do
    test "cron 注册 LoginArtifactPrunerWorker（每小时）" do
      plugins = Application.get_env(:cgc_2046, Oban)[:plugins]
      assert {Oban.Plugins.Cron, cron_opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)
      crontab = Keyword.fetch!(cron_opts, :crontab)

      assert Enum.any?(crontab, fn {schedule, worker} ->
               worker == LoginArtifactPrunerWorker and schedule =~ " * * * *"
             end)
    end

    test "队列归属 maintenance + manual 模式入队不执行" do
      {:ok, job} = LoginArtifactPrunerWorker.new(%{}) |> Oban.insert()

      assert job.state == "available"
      assert_enqueued(worker: LoginArtifactPrunerWorker, queue: :maintenance)
    end
  end
end
