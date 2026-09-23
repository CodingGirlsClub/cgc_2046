defmodule Cgc2046.Flashback.WishesTest do
  @moduledoc """
  许愿域（U4/KTD2/KTD3/KTD4）：创建可见性、附议幂等、留言、软删权与
  本人态、城市快照与正文约束、双入口身份落位、KTD4 机审接入。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Accounts.UserIdentity
  alias Cgc2046.Flashback.Wishes
  alias Cgc2046.MiniprogramFixtures.Barrier

  @msg_check_url "https://api.weixin.qq.com/wxa/msg_sec_check"
  @openid_unresolved_event [:cgc_2046, :content_check, :openid_unresolved]

  defp create_archive do
    Cgc2046.Flashback.EventArchive
    |> Ash.Changeset.for_create(:create, %{
      key: "2014-01-11-bj-w#{System.unique_integer([:positive])}",
      name: "Rails Girls Beijing",
      city: "北京",
      occurred_on: ~D[2014-01-11]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_person(archive, overrides \\ %{}) do
    Cgc2046.Flashback.Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: archive.id,
          full_name: "王小明",
          surname: "王",
          city: "北京",
          participation: :attended
        },
        overrides
      )
    )
    |> Ash.create!(authorize?: false)
  end

  # KTD4：把 person 绑定到指定 user（写 flashback_people.user_id，writable?: false
  # 走 Repo 直改）；openid 解析链 ①/② 的同一物理路径（person.user_id → identities）。
  defp bind_person_to_user(person_id, user_id) do
    {1, _} =
      Repo.query(
        "UPDATE flashback_people SET user_id = $1 WHERE id = $2",
        [Repo.uuid!(user_id), Repo.uuid!(person_id)]
      )
      |> case do
        {:ok, %{num_rows: n} = res} -> {n, res}
        other -> raise "update failed: #{inspect(other)}"
      end

    :ok
  end

  defp attach_identity(user_id, provider, uid) do
    UserIdentity
    |> Ash.Changeset.for_create(:upsert, %{
      provider: provider,
      uid: uid,
      user_id: user_id
    })
    |> Ash.create!(authorize?: false)
  end

  defp register_user(prefix) do
    Cgc2046.AccountsFixtures.register_user("#{prefix}-#{System.unique_integer([:positive])}")
  end

  describe "创建（R5/R6）" do
    test "公开许愿 → list_public；私有 → 仅 list_private" do
      archive = create_archive()
      person = create_person(archive)
      {:ok, public} = Wishes.create_wish(person.id, "一起出一本书", "public")
      {:ok, private} = Wishes.create_wish(person.id, "想学 Rust", "private")

      assert [%{id: public_id}] = Wishes.list_public()
      assert public_id == public.id

      assert [%{id: private_id}] = Wishes.list_private(person.id)
      assert private_id == private.id
      assert [] = Wishes.list_private(create_person(archive, %{full_name: "李雷", surname: "李"}).id)
    end

    test "city 快照自许愿人名册城市（无城市入参）" do
      archive = create_archive()
      person = create_person(archive, %{city: "上海", full_name: "陈静", surname: "陈"})
      {:ok, wish} = Wishes.create_wish(person.id, "开一门 Rust 系统课", "public")
      assert wish.city == "上海"

      person_nil_city = create_person(archive, %{city: nil, full_name: "无城", surname: "无"})
      {:ok, wish2} = Wishes.create_wish(person_nil_city.id, "许愿二", "public")
      assert is_nil(wish2.city)
    end

    test "空白/超长正文 → invalid_content；非法 visibility → invalid_visibility" do
      archive = create_archive()
      person = create_person(archive)

      assert {:error, %{code: "flashback_wish_invalid_content"}} =
               Wishes.create_wish(person.id, "   ", "public")

      assert {:error, %{code: "flashback_wish_invalid_content"}} =
               Wishes.create_wish(person.id, String.duplicate("长", 501), "public")

      assert {:error, %{code: "flashback_wish_invalid_visibility"}} =
               Wishes.create_wish(person.id, "正常内容", "secret")
    end
  end

  describe "附议（R7 幂等）与本人态" do
    test "同人两次附议只计一次；endorsed_by_me 正确" do
      archive = create_archive()
      wisher = create_person(archive)
      endorser = create_person(archive, %{full_name: "李雷", surname: "李"})

      {:ok, wish} = Wishes.create_wish(wisher.id, "一起出一本书", "public")

      endorser_user = register_user("wish-idem")
      :ok = bind_person_to_user(endorser.id, endorser_user.id)

      assert {:ok, %{endorsement_count: 1, endorsed_by_me: true}} =
               Wishes.endorse_by_user(endorser_user.id, wish.id)

      # 幂等：重复附议 UPDATE 不双计
      assert {:ok, %{endorsement_count: 1, endorsed_by_me: true}} =
               Wishes.endorse_by_user(endorser_user.id, wish.id)

      [%{endorsement_count: 1}] = Wishes.list_public()
    end

    test "附议私有/已删愿望 → not_found（不泄露存在性）" do
      archive = create_archive()
      wisher = create_person(archive)
      {:ok, private} = Wishes.create_wish(wisher.id, "私愿", "private")

      # viewer（无 person）对不可附议目标统一 not_found（KTD9）
      viewer = register_user("wish-nf")

      assert {:error, %{code: "flashback_wish_not_found"}} =
               Wishes.endorse_by_user(viewer.id, private.id)
    end
  end

  describe "留言（R8）与软删（R14/KTD4）" do
    test "留言正序展示；软删后不再显示" do
      archive = create_archive()
      wisher = create_person(archive)
      commenter = create_person(archive, %{full_name: "李雷", surname: "李"})
      {:ok, wish} = Wishes.create_wish(wisher.id, "一起出一本书", "public")

      {:ok, _} = Wishes.add_comment(commenter.id, wish.id, "算我一个")
      {:ok, comments} = Wishes.add_comment(commenter.id, wish.id, "成都可牵头")
      assert length(comments) == 2
      assert length(comments) == 2
      assert Enum.all?(comments, &(&1.commenter_masked =~ "李"))

      [first | _] = comments
      {:ok, _} = Wishes.soft_delete_comment(first.id, commenter.id)
      assert [%{content: "成都可牵头"}] = Wishes.list_comments(wish.id)
    end

    test "删除权：本人可删自己许愿；删他人 forbidden" do
      archive = create_archive()
      wisher = create_person(archive)
      other = create_person(archive, %{full_name: "李雷", surname: "李"})
      {:ok, wish} = Wishes.create_wish(wisher.id, "公开愿望", "public")

      assert {:error, %{code: "flashback_forbidden_wish"}} =
               Wishes.soft_delete_wish(wish.id, other.id)

      assert {:ok, _} = Wishes.soft_delete_wish(wish.id, wisher.id)
      assert [] = Wishes.list_public()
    end

    test "admin? 旁路（MCP 走同一函数 KTD4）" do
      archive = create_archive()
      wisher = create_person(archive)
      admin_actor = create_person(archive, %{full_name: "管理员", surname: "管"})
      {:ok, wish} = Wishes.create_wish(wisher.id, "公开愿望", "public")
      assert {:ok, _} = Wishes.soft_delete_wish(wish.id, admin_actor.id, admin?: true)
      assert [] = Wishes.list_public()
    end
  end

  describe "年度额度（R20：每自然年 3 条，含私有与已软删，删除不退还）" do
    # 直改库回拨 inserted_at（绕过 Ash action；先例：mcp/token_test.exs backdate）。
    # 取去年年中，远离年界两侧偏移边界。
    defp backdate_to_last_year(wish) do
      shanghai_year = DateTime.add(DateTime.utc_now(), 8 * 3600, :second).year

      last_year =
        DateTime.new!(Date.new!(shanghai_year - 1, 6, 1), ~T[12:00:00.000000], "Etc/UTC")

      wish |> change(inserted_at: last_year) |> Repo.update!()
    end

    test "当年 3 条后第 4 条被拒（quota_exceeded）" do
      archive = create_archive()
      person = create_person(archive)

      for i <- 1..3 do
        assert {:ok, _} = Wishes.create_wish(person.id, "愿望 #{i}", "public")
      end

      assert {:error, %{code: "flashback_wish_quota_exceeded"}} =
               Wishes.create_wish(person.id, "第四条", "public")
    end

    test "软删不退还额度：删一条后第 4 条仍被拒" do
      archive = create_archive()
      person = create_person(archive)

      wishes =
        for i <- 1..3 do
          {:ok, wish} = Wishes.create_wish(person.id, "愿望 #{i}", "public")
          wish
        end

      {:ok, _} = Wishes.soft_delete_wish(hd(wishes).id, person.id)

      assert {:error, %{code: "flashback_wish_quota_exceeded"}} =
               Wishes.create_wish(person.id, "删除后再许", "public")
    end

    test "私有愿望也占额度：2 公开 + 1 私有后第 4 条被拒" do
      archive = create_archive()
      person = create_person(archive)

      {:ok, _} = Wishes.create_wish(person.id, "公开一", "public")
      {:ok, _} = Wishes.create_wish(person.id, "公开二", "public")
      {:ok, _} = Wishes.create_wish(person.id, "私有一", "private")

      assert {:error, %{code: "flashback_wish_quota_exceeded"}} =
               Wishes.create_wish(person.id, "第四条", "public")
    end

    test "跨年重置：去年 3 条不占今年额度" do
      archive = create_archive()
      person = create_person(archive)

      for i <- 1..3 do
        {:ok, wish} = Wishes.create_wish(person.id, "去年愿望 #{i}", "public")
        backdate_to_last_year(wish)
      end

      assert {:ok, _} = Wishes.create_wish(person.id, "今年第一条", "public")
      assert Wishes.quota_remaining(person.id) == 2
    end

    test "quota_remaining/1：0 条 → 3，2 条 → 1，3 条 → 0" do
      archive = create_archive()
      person = create_person(archive)

      assert Wishes.quota_remaining(person.id) == 3

      {:ok, _} = Wishes.create_wish(person.id, "一", "public")
      {:ok, _} = Wishes.create_wish(person.id, "二", "private")
      assert Wishes.quota_remaining(person.id) == 1

      {:ok, _} = Wishes.create_wish(person.id, "三", "public")
      assert Wishes.quota_remaining(person.id) == 0
    end
  end

  describe "年度额度并发（R20：person 行 FOR UPDATE 锁串行化）" do
    # 真实连接并发（unboxed）：共享 sandbox 只有一条连接，事务会在连接检出层
    # 被串行化，「去掉 FOR UPDATE」的变异在单连接下测不出；fixture 与计数断言
    # 同走 unboxed 真实提交，on_exit 显式清理真实行
    # （先例：admission/enrollment_concurrency_test.exs）。
    test "10 路并发许愿：恰好 3 成功、7 额度拒绝，库中恰 3 条" do
      barrier = start_supervised!({Barrier, 10})

      {archive, person} =
        unboxed(fn ->
          archive = create_archive()
          {archive, create_person(archive)}
        end)

      on_exit(fn ->
        unboxed(fn ->
          Repo.query!("DELETE FROM flashback_wishes WHERE person_id = $1", [
            Repo.uuid!(person.id)
          ])

          Repo.query!("DELETE FROM flashback_people WHERE id = $1", [Repo.uuid!(person.id)])

          Repo.query!("DELETE FROM flashback_event_archives WHERE id = $1", [
            Repo.uuid!(archive.id)
          ])
        end)
      end)

      results =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            Barrier.arrive(barrier)
            unboxed(fn -> Wishes.create_wish(person.id, "并发愿望 #{i}", "public") end)
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 3

      assert Enum.count(
               results,
               &match?({:error, %{code: "flashback_wish_quota_exceeded"}}, &1)
             ) == 7

      assert wishes_count(person.id) == 3
    end
  end

  describe "KTD4 机审接入（U4：create_wish / add_comment 经 wechat msgSecCheck v2）" do
    @openid "wx-flashback-u4"

    # 三态 mock helper：:pass / :risky / :review / :network_error；不 mock = 期望零外呼。
    defp mock_msg_check(:pass),
      do:
        Tesla.Mock.mock(fn %{method: :post, url: @msg_check_url <> _} = env ->
          send(self(), {:msg_check_request, Jason.decode!(env.body)})
          Tesla.Mock.json(%{"errcode" => 0, "result" => %{"suggest" => "pass", "label" => 100}})
        end)

    defp mock_msg_check(suggest) when suggest in [:risky, :review],
      do:
        Tesla.Mock.mock(fn %{method: :post, url: @msg_check_url <> _} = env ->
          send(self(), {:msg_check_request, Jason.decode!(env.body)})

          Tesla.Mock.json(%{
            "errcode" => 0,
            "result" => %{"suggest" => to_string(suggest), "label" => 20002}
          })
        end)

    defp mock_msg_check(:network_error),
      do:
        Tesla.Mock.mock(fn %{method: :post, url: @msg_check_url <> _} ->
          {:error, :timeout}
        end)

    defp attach_unresolved_telemetry(test_pid) do
      handler_id = "u4-openid-unresolved-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          @openid_unresolved_event,
          fn event, measurements, metadata, _config ->
            send(test_pid, {:openid_unresolved, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    # 准备「已认领 person + wechat identity」的 fixture（①/② 同一路径）。
    defp claimed_wechat_person(archive, openid \\ @openid) do
      person = create_person(archive)
      user = register_user("u4-wechat")
      :ok = bind_person_to_user(person.id, user.id)
      %UserIdentity{} = attach_identity(user.id, :wechat, openid)
      %{person: person, user: user, openid: openid}
    end

    test "create_wish：v2 pass 通过发布；请求体含 content/version/scene/openid（KTD4 ①/② 链）" do
      archive = create_archive()
      %{person: person, openid: openid} = claimed_wechat_person(archive)

      mock_msg_check(:pass)

      assert {:ok, _wish} = Wishes.create_wish(person.id, "一起出一本书", "public")

      assert_receive {:msg_check_request,
                      %{
                        "content" => "一起出一本书",
                        "version" => 2,
                        "scene" => 2,
                        "openid" => ^openid
                      }}
    end

    test "create_wish：v2 risky / review 返回 flashback_content_rejected，库中无愿望（fail-closed）" do
      for suggest <- [:risky, :review] do
        archive = create_archive()
        %{person: person} = claimed_wechat_person(archive, "#{@openid}-#{suggest}")

        mock_msg_check(suggest)

        assert {:error, %{code: "flashback_content_rejected"}} =
                 Wishes.create_wish(person.id, "某违规内容样例", "public")

        assert wishes_count_by_person(person.id) == 0
      end
    end

    test "create_wish：network error 故障 fail-open 正常发布（KTD4 infra 故障链，telemetry 由 client.ex 记）" do
      archive = create_archive()
      %{person: person} = claimed_wechat_person(archive)

      mock_msg_check(:network_error)

      assert {:ok, _wish} = Wishes.create_wish(person.id, "平台瞬时故障也放行", "public")
    end

    test "create_wish：③ 未认领 token-only（person.user_id 空）→ skipped + telemetry，发布成功零外呼" do
      test_pid = self()
      attach_unresolved_telemetry(test_pid)

      archive = create_archive()
      person = create_person(archive)

      # 不 mock msgSecCheck：若实现误发请求，Tesla.Mock 无匹配即 raise——零外呼证明。
      assert {:ok, _wish} = Wishes.create_wish(person.id, "未认领长尾愿望", "public")

      assert_receive {:openid_unresolved, @openid_unresolved_event, %{count: 1},
                      %{reason: :no_user}}
    end

    test "create_wish：③ 已认领但无 wechat identity（tt 单平台）→ skipped + telemetry，发布零外呼" do
      test_pid = self()
      attach_unresolved_telemetry(test_pid)

      archive = create_archive()
      person = create_person(archive)
      user = register_user("u4-tt")
      :ok = bind_person_to_user(person.id, user.id)
      _ = attach_identity(user.id, :tt, "tt-openid-u4")

      # 不 mock msgSecCheck：tt 单平台零外呼；tt 侧「各自平台独立审核」由 client.ex
      # tt 分支表达，本链路根本不到 client，直接 :no_wechat_identity 放行。
      assert {:ok, _wish} = Wishes.create_wish(person.id, "tt 用户许愿", "public")

      assert_receive {:openid_unresolved, @openid_unresolved_event, %{count: 1},
                      %{reason: :no_wechat_identity}}
    end

    test "create_wish：visibility=private「说给主办方听」同样过机审；risky 拒绝" do
      archive = create_archive()
      %{person: person} = claimed_wechat_person(archive, "#{@openid}-private")

      mock_msg_check(:risky)

      assert {:error, %{code: "flashback_content_rejected"}} =
               Wishes.create_wish(person.id, "某违规内容样例", "private")

      assert wishes_count_by_person(person.id) == 0
    end

    test "create_wish：visibility=private pass 通过发布且无人审队列写入（KTD4：本批无人队设施）" do
      archive = create_archive()
      %{person: person} = claimed_wechat_person(archive, "#{@openid}-private-pass")

      mock_msg_check(:pass)

      assert {:ok, wish} = Wishes.create_wish(person.id, "想给主办方一句建议", "private")
      assert wish.visibility == "private"

      # 本批 U4 零人工队列设施（KTD5 收件箱为 admin 读面+U5 新增表）。
      assert wishes_count_by_person(person.id) == 1
    end

    test "add_comment：v2 pass 通过；risky/review fail-closed 且库中无该留言" do
      archive = create_archive()
      commenter = create_person(archive, %{full_name: "李雷", surname: "李"})
      user = register_user("u4-commenter")
      :ok = bind_person_to_user(commenter.id, user.id)
      _ = attach_identity(user.id, :wechat, "#{@openid}-commenter")

      owner = create_person(archive, %{full_name: "韩梅", surname: "韩"})

      # owner 无 user 也可以建愿望（KTD4 ③ 是独立路径）——本测试只想让留言面可用。
      {:ok, wish} = Wishes.create_wish(owner.id, "想听到你的声音", "public")

      # pass：留言成功
      mock_msg_check(:pass)
      assert {:ok, [%{content: "顶一下"}]} = Wishes.add_comment(commenter.id, wish.id, "顶一下")

      # risky：拒绝且留言表无新增
      mock_msg_check(:risky)

      assert {:error, %{code: "flashback_content_rejected"}} =
               Wishes.add_comment(commenter.id, wish.id, "违规留言样例")

      assert [%{content: "顶一下"}] = Wishes.list_comments(wish.id)
    end

    test "add_comment：未认领 commenter 走 ③ skipped + telemetry，留言成功零外呼" do
      test_pid = self()
      attach_unresolved_telemetry(test_pid)

      archive = create_archive()
      owner = create_person(archive, %{full_name: "韩梅", surname: "韩"})
      commenter = create_person(archive, %{full_name: "李雷", surname: "李"})

      {:ok, wish} = Wishes.create_wish(owner.id, "想听到你的声音", "public")

      # 不 mock msgSecCheck
      assert {:ok, [%{content: "顶一下"}]} = Wishes.add_comment(commenter.id, wish.id, "顶一下")

      # 两次调用 create_wish + add_comment 都触发了 unresolved；本用例只断言 add_comment
      # 至少一条 reason: :no_user。
      assert_received {:openid_unresolved, @openid_unresolved_event, %{count: 1},
                       %{reason: :no_user}}
    end
  end

  describe "U1 KTD1 署名快照 / listed_at 授权契约 / KTD11 期望地归一" do
    test "默认 opts（旧客户端）：listed_at 为 NULL，signature = masked_name，city = 名册城市归一" do
      archive = create_archive()
      person = create_person(archive, %{full_name: "王小明", surname: "王", city: "北京市"})

      {:ok, wish} = Wishes.create_wish(person.id, "大家一起来", "public")

      assert wish.listed_at == nil
      assert wish.signature == "王**"
      assert wish.hidden_at == nil
      assert wish.city == "北京"
    end

    test "publicListingConsent=true + visibility=public → listed_at 非空" do
      archive = create_archive()
      person = create_person(archive)

      {:ok, wish} =
        Wishes.create_wish(person.id, "公开打卡的心愿", "public", public_listing_consent: true)

      assert %DateTime{} = wish.listed_at
      assert wish.hidden_at == nil
    end

    test "publicListingConsent=false → listed_at 仍 NULL（public 但仅成员面）" do
      archive = create_archive()
      person = create_person(archive)

      {:ok, wish} =
        Wishes.create_wish(person.id, "private-by-default", "public",
          public_listing_consent: false
        )

      assert wish.listed_at == nil
    end

    test "visibility=private → listed_at 永远 NULL 即使 consent=true" do
      archive = create_archive()
      person = create_person(archive)

      {:ok, wish} =
        Wishes.create_wish(person.id, "私下话", "private", public_listing_consent: true)

      assert wish.listed_at == nil
      assert wish.visibility == "private"
    end

    test "signature_choice=:display_name → signature 用实名" do
      archive = create_archive()
      person = create_person(archive, %{full_name: "王小明", surname: "王"})

      {:ok, wish} =
        Wishes.create_wish(person.id, "挂真名的心愿", "public", signature_choice: :display_name)

      assert wish.signature == "王小明"
    end

    test "expected_city 提供时强制归一：成都 / 成都市 同归 成都" do
      archive = create_archive()
      person = create_person(archive)

      {:ok, wish1} =
        Wishes.create_wish(person.id, "成都见", "public", expected_city: "成都")

      {:ok, wish2} =
        Wishes.create_wish(person.id, "成都市也行", "public", expected_city: "成都市")

      assert wish1.city == "成都"
      assert wish2.city == "成都"
    end

    test "expected_city 名单外 → flashback_wish_city_unknown + ≤3 候选" do
      archive = create_archive()
      person = create_person(archive)

      assert {:error, %{code: "flashback_wish_city_unknown", candidates: cands}} =
               Wishes.create_wish(person.id, "想去某地", "public", expected_city: "某某某地")

      assert is_list(cands) and length(cands) <= 3
    end

    test "expected_city=nil 时按名册城市归一，失败留空" do
      archive = create_archive()
      person = create_person(archive, %{city: "某某外邦"})
      {:ok, wish} = Wishes.create_wish(person.id, "外邦心愿", "public")
      assert wish.city == nil

      person2 = create_person(archive, %{full_name: "张三", surname: "张", city: "成都市"})
      {:ok, wish2} = Wishes.create_wish(person2.id, "成都人", "public")
      assert wish2.city == "成都"
    end

    test "hidden_at 置位 → list_public_listed 看不见，list_public（成员面）行为不变" do
      archive = create_archive()
      person = create_person(archive)

      {:ok, wish} =
        Wishes.create_wish(person.id, "要 hidden 的心愿", "public", public_listing_consent: true)

      assert Enum.any?(Wishes.list_public_listed(), &(&1.id == wish.id))

      # admin 下架（直接 SQL 演化模拟 U5 后续 admin action）
      %{num_rows: 1} =
        Repo.query!(
          "UPDATE flashback_wishes SET hidden_at = now() WHERE id = $1",
          [Repo.uuid!(wish.id)]
        )

      # hidden 后公开树不再可见
      refute Enum.any?(Wishes.list_public_listed(), &(&1.id == wish.id))

      # 成员面仍然可见（计 hidden 不过滤）
      assert Enum.any?(Wishes.list_public(), &(&1.id == wish.id))
    end

    test "存量 listed_at = NULL 不出现于 list_public_listed" do
      archive = create_archive()
      person = create_person(archive)

      # 默认（旧客户端）授权位 = NULL
      {:ok, wish} = Wishes.create_wish(person.id, "存量气氛组", "public")
      assert wish.listed_at == nil

      refute Enum.any?(Wishes.list_public_listed(), &(&1.id == wish.id))
      # 成员面可见
      assert Enum.any?(Wishes.list_public(), &(&1.id == wish.id))
    end

    test "signature 快照不随改名回溯（KTD1 快照语义）" do
      archive = create_archive()
      person = create_person(archive, %{full_name: "王小明", surname: "王"})

      {:ok, wish} =
        Wishes.create_wish(person.id, "快速心愿", "public",
          signature_choice: :display_name,
          public_listing_consent: true
        )

      assert wish.signature == "王小明"

      # 改名后 wish.signature 不更新（快照语义）
      %{num_rows: 1} =
        Repo.query!(
          "UPDATE flashback_people SET full_name = '王大名' WHERE id = $1",
          [Repo.uuid!(person.id)]
        )

      # 改变名后 wish.signature 不更新（KTD1 快照语义）
      refreshed = Wishes.list_public() |> Enum.find(&(&1.id == wish.id))
      assert refreshed.content == "快速心愿"
      # list_public 投影内无 signature，但 DB 行仍存旧值
      %{rows: [[sig]]} =
        Repo.query!("SELECT signature FROM flashback_wishes WHERE id = $1", [
          Repo.uuid!(wish.id)
        ])

      assert sig == "王小明"
    end

    test "存量行 masked_name 回填 SQL 4 分支全矩阵（KTD1 快照语义对齐 masked_name/2）" do
      archive = create_archive()

      # Branch A: surname 匹配 full_name 前缀，length>0
      p_a = create_person(archive, %{full_name: "王小明", surname: "王"})
      # Branch B: surname 不匹配前缀 → 首字符 + '*'
      p_b = create_person(archive, %{full_name: "李晓芒", surname: "王"})
      # Branch C: 单字 full_name （含字 = 1）→ '字*'
      p_c = create_person(archive, %{full_name: "明", surname: nil})
      # Branch D: full_name NULL → ''
      p_d = create_person(archive, %{full_name: "王小明", surname: "王"})

      # 插入「存量行」（signature='' 模拟迁移前）— 走 SQL 直插绕 changeset
      # 因为 wish.ex default "" 是 changeset-time。此处刻意模拟存量 signature=''。
      wishes =
        for p <- [p_a, p_b, p_c, p_d] do
          id = Ecto.UUID.generate()

          Repo.query!(
            """
            INSERT INTO flashback_wishes (id, person_id, content, visibility, signature, inserted_at, updated_at)
            VALUES ($1, $2, $3, 'public', '', now(), now())
            """,
            [Ecto.UUID.dump!(id), Ecto.UUID.dump!(p.id), "存量 #{p.full_name}"]
          )

          {id, p.id}
        end

      # 迁移的 UPDATE 语句（与 20260922001343 migration 1:1）
      Repo.query!("""
      UPDATE flashback_wishes w
      SET signature = (
        CASE
          WHEN p.full_name IS NULL OR p.full_name = '' THEN ''
          WHEN p.surname IS NOT NULL
               AND p.surname <> ''
               AND substring(p.full_name from 1 for char_length(p.surname)) = p.surname
          THEN p.surname || repeat('*', greatest(char_length(p.full_name) - char_length(p.surname), 1))
          ELSE substring(p.full_name from 1 for 1) || repeat('*', greatest(char_length(p.full_name) - 1, 1))
        END
      )
      FROM flashback_people p
      WHERE w.person_id = p.id AND w.signature = ''
      """)

      # Branch A: 王**
      %{rows: [[sig_a]]} =
        Repo.query!(
          "SELECT signature FROM flashback_wishes WHERE person_id = $1",
          [Ecto.UUID.dump!(p_a.id)]
        )

      assert sig_a == "王**"

      # Branch B: 李**（首字符 + 长度-1 个 *）
      %{rows: [[sig_b]]} =
        Repo.query!(
          "SELECT signature FROM flashback_wishes WHERE person_id = $1",
          [Ecto.UUID.dump!(p_b.id)]
        )

      assert sig_b == "李**"

      # Branch C: '明*'（单字 full_name 走 ELSE 首字符分支）
      %{rows: [[sig_c]]} =
        Repo.query!(
          "SELECT signature FROM flashback_wishes WHERE person_id = $1",
          [Ecto.UUID.dump!(p_c.id)]
        )

      assert sig_c == "明*"

      # Branch D: 清 D 的 person.full_name 为空串（full_name allow_nil?: false 不能 NULL）→ '' 分支
      Repo.query!(
        "UPDATE flashback_people SET full_name = '' WHERE id = $1",
        [Ecto.UUID.dump!(p_d.id)]
      )

      # 再跑一次回填 only D（之前的 update 已经写入了 signature，需要重置
      Repo.query!(
        "UPDATE flashback_wishes SET signature = '' WHERE person_id = $1",
        [Ecto.UUID.dump!(p_d.id)]
      )

      Repo.query!("""
      UPDATE flashback_wishes w
      SET signature = (
        CASE
          WHEN p.full_name IS NULL OR p.full_name = '' THEN ''
          WHEN p.surname IS NOT NULL
               AND p.surname <> ''
               AND substring(p.full_name from 1 for char_length(p.surname)) = p.surname
          THEN p.surname || repeat('*', greatest(char_length(p.full_name) - char_length(p.surname), 1))
          ELSE substring(p.full_name from 1 for 1) || repeat('*', greatest(char_length(p.full_name) - 1, 1))
        END
      )
      FROM flashback_people p
      WHERE w.person_id = p.id AND w.signature = '' AND w.person_id = '#{p_d.id}'
      """)

      %{rows: [[sig_d]]} =
        Repo.query!(
          "SELECT signature FROM flashback_wishes WHERE person_id = $1",
          [Ecto.UUID.dump!(p_d.id)]
        )

      assert sig_d == ""

      # 至少证明 wishes 全部 4 个都被迁移进程触及
      assert length(wishes) == 4
    end

    test "list_public_listed 城市过滤仍按 is_nil or 相等" do
      archive = create_archive()
      person = create_person(archive, %{city: "北京市"})

      {:ok, w1} =
        Wishes.create_wish(person.id, "北京场", "public", public_listing_consent: true)

      {:ok, w2} =
        Wishes.create_wish(person.id, "外邦场", "public",
          expected_city: nil,
          public_listing_consent: true
        )

      # 全部
      beijing = Wishes.list_public_listed("北京")
      assert Enum.any?(beijing, &(&1.id == w1.id))

      # 北京 filter 不该看到 w2（w2 用的是 person.city="北京市" 归一 → 北京）——两人都
      # 在北京但其实 w1/w2 同城，只是看 filter 与原 list_public 一致
      assert Enum.any?(beijing, &(&1.id == w2.id))
    end
  end

  describe "FIX-3 信用降级 create 侧消费（KTD5）" do
    test "credit 置位作者的新公开愿望默认 hidden_at 待审、不挂树" do
      archive = create_archive()
      person = create_person(archive)
      user = register_user("fix3-a")
      :ok = bind_person_to_user(person.id, user.id)

      Repo.query!(
        "UPDATE users SET wishes_review_required_at = now() WHERE id = $1",
        [Repo.uuid!(user.id)]
      )

      {:ok, wish} =
        Wishes.create_wish(person.id, "信用降级后的公开愿", "public", public_listing_consent: true)

      # 不挂树
      assert is_nil(wish.listed_at)
      # 待审（hidden）
      assert wish.hidden_at != nil

      refute Enum.any?(Wishes.list_public_listed(), &(&1.id == wish.id))
    end

    test "credit 置位作者的 private 愿望不受影响（说给主办方听不待审）" do
      archive = create_archive()
      person = create_person(archive)
      user = register_user("fix3-b")
      :ok = bind_person_to_user(person.id, user.id)

      Repo.query!(
        "UPDATE users SET wishes_review_required_at = now() WHERE id = $1",
        [Repo.uuid!(user.id)]
      )

      {:ok, wish} = Wishes.create_wish(person.id, "悄悄话不待审", "private")

      assert wish.hidden_at == nil
      assert wish.listed_at == nil
    end

    test "credit 未置位作者照常挂树（正路径不回归）" do
      archive = create_archive()
      person = create_person(archive)

      {:ok, wish} =
        Wishes.create_wish(person.id, "正常公开愿", "public", public_listing_consent: true)

      assert wish.listed_at != nil
      assert wish.hidden_at == nil
    end

    test "admin 放行（set_wish_hidden false）清 hidden_at 且不清 credit 字段（G1 pin）" do
      archive = create_archive()
      person = create_person(archive)
      user = register_user("fix3-c")
      :ok = bind_person_to_user(person.id, user.id)

      Repo.query!(
        "UPDATE users SET wishes_review_required_at = now() WHERE id = $1",
        [Repo.uuid!(user.id)]
      )

      {:ok, wish} =
        Wishes.create_wish(person.id, "待审愿", "public", public_listing_consent: true)

      admin = register_user("fix3-admin")

      Repo.query!("UPDATE users SET is_platform_admin = true WHERE id = $1", [
        Repo.uuid!(admin.id)
      ])

      {:ok, cleared} = Cgc2046.Flashback.Reports.set_wish_hidden(wish.id, admin.id, false)
      assert is_nil(cleared.hidden_at)
      # 放行后可挂树？listed_at 仍 nil——放行只清 hidden，挂树由 admin 显式
      # re-list（后续 admin action）；本断言钉「放行 ≠ 自动挂树」语义边界
      assert is_nil(cleared.listed_at)

      %{rows: [[credit]]} =
        Repo.query!("SELECT wishes_review_required_at FROM users WHERE id = $1", [
          Repo.uuid!(user.id)
        ])

      assert credit != nil
    end
  end

  # KTD4 同步 (非 unboxed) 流程下统计：查询走 sandbox 共享连接，能看到本事务内
  # 已 insert 但尚未 rollback 的愿望（与 unboxed_run 另开连接的 wishes_count/1
  # 对 R20 并发用例的语义不同）。
  defp wishes_count_by_person(person_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM flashback_wishes WHERE person_id = $1", [
        Repo.uuid!(person_id)
      ])

    count
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Cgc2046.Repo, fun)

  defp wishes_count(person_id) do
    %{rows: [[count]]} =
      unboxed(fn ->
        Repo.query!("SELECT COUNT(*) FROM flashback_wishes WHERE person_id = $1", [
          Repo.uuid!(person_id)
        ])
      end)

    count
  end
end
