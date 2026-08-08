defmodule Cgc2046.Accounts.MiniprogramStrategyTest do
  @moduledoc """
  `:miniprogram` 自定义 AshAuthentication 策略单元测试（Phase 1 身份基座）。

  覆盖：三平台 code2session fixture（Req.Test）、手机号解密、phone 锚定
  find-or-create、UserIdentity 挂载/upsert、JWT platform claim + 7 天 TTL、
  重登吊销旧 jti、session_key 不出后端。
  """
  use Cgc2046.DataCase, async: true

  alias AshAuthentication.{Errors.AuthenticationFailed, Info, Jwt, Strategy}
  alias Cgc2046.Accounts.{User, UserIdentity}
  alias Cgc2046.MiniprogramFixtures, as: Fixtures

  @internal_context [context: %{private: %{ash_authentication?: true}}]

  defp strategy, do: Info.strategy!(User, :miniprogram)

  defp sign_in(platform, code, encrypted_data, iv) do
    Strategy.action(strategy(), :sign_in, %{
      platform: platform,
      code: code,
      encrypted_data: encrypted_data,
      iv: iv
    })
  end

  # 构造一次成功登录的全部材料：{响应体, encrypted_data, iv}
  defp login_fixture(platform, openid, payload, unionid \\ nil) do
    session_key = Fixtures.new_session_key()

    body =
      Fixtures.code2session_body(platform, %{
        openid: openid,
        session_key: session_key,
        unionid: unionid
      })

    {encrypted_data, iv} = Fixtures.encrypt_phone(session_key, payload)
    {body, encrypted_data, iv}
  end

  defp all_users, do: Ash.read!(User, @internal_context)
  defp all_identities, do: Ash.read!(UserIdentity, @internal_context)

  # 目标化断言辅助：测试库可能存在其它用例提交的残留行（test_helper 为 manual 模式），
  # 全局空表断言不可靠——一律按本用例 fixture 的 phone/openid 精确判定。
  defp users_with_phone(phone), do: all_users() |> Enum.filter(&(&1.phone == phone))
  defp identities_with_uid(uid), do: all_identities() |> Enum.filter(&(&1.uid == uid))
  defp user_count, do: length(all_users())
  defp identity_count, do: length(all_identities())

  defp token_purposes(user) do
    subject = AshAuthentication.user_to_subject(user)

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "SELECT jti, purpose FROM tokens WHERE subject = $1",
        [subject]
      )

    Map.new(rows, fn [jti, purpose] -> {jti, purpose} end)
  end

  describe "首登建号（三平台 fixture）" do
    test "wechat：建 User（phone 锚定）+ 挂 Identity + 签发带 platform claim 的 JWT" do
      payload = Fixtures.phone_payload("13800000001")

      {body, encrypted_data, iv} =
        login_fixture(:wechat, "w-openid-1", payload, "w-unionid-1")

      Fixtures.stub_code2session(%{wechat: body})

      assert {:ok, user} = sign_in("wechat", "login-code-1", encrypted_data, iv)

      # User：手机号归一化为 +区号+号码；email/hashed_password 可空
      assert user.phone == "+8613800000001"
      assert is_nil(user.email)
      assert is_nil(user.hashed_password)

      # Identity：provider/uid/unionid/user_id 四元组落库
      assert [identity] = all_identities()
      assert identity.provider == :wechat
      assert identity.uid == "w-openid-1"
      assert identity.unionid == "w-unionid-1"
      assert identity.user_id == user.id

      # JWT：platform claim + purpose + 7 天 TTL（risk #5：14d → 7d）
      token = user.__metadata__.token
      assert is_binary(token)
      {:ok, claims} = Jwt.peek(token)
      assert claims["platform"] == "wechat"
      assert claims["purpose"] == "user"
      assert claims["exp"] - claims["iat"] == 7 * 24 * 60 * 60
      assert claims["sub"] =~ user.id
    end

    test "tt：err_no/data 信封解析 + unionid 落库" do
      payload = Fixtures.phone_payload("13800000002")

      {body, encrypted_data, iv} = login_fixture(:tt, "t-openid-1", payload, "t-unionid-1")
      Fixtures.stub_code2session(%{tt: body})

      assert {:ok, user} = sign_in("tt", "login-code-2", encrypted_data, iv)
      assert user.phone == "+8613800000002"

      assert [identity] = all_identities()
      assert identity.provider == :tt
      assert identity.uid == "t-openid-1"
      assert identity.unionid == "t-unionid-1"

      {:ok, claims} = Jwt.peek(user.__metadata__.token)
      assert claims["platform"] == "tt"
    end

    test "xhs：两步流程（token + session），官方文档明确无 unionid → 恒为 nil" do
      payload = Fixtures.phone_payload("13800000003")

      {body, encrypted_data, iv} = login_fixture(:xhs, "x-openid-1", payload)
      Fixtures.stub_code2session(%{xhs: body})

      assert {:ok, user} = sign_in("xhs", "login-code-3", encrypted_data, iv)
      assert user.phone == "+8613800000003"

      assert [identity] = all_identities()
      assert identity.provider == :xhs
      assert identity.uid == "x-openid-1"
      # 官方《登录态管理》：小红书暂不提供 unionid
      assert is_nil(identity.unionid)

      {:ok, claims} = Jwt.peek(user.__metadata__.token)
      assert claims["platform"] == "xhs"
    end
  end

  describe "失败路径（防枚举统一 AuthenticationFailed，不产生任何落库）" do
    test "平台拒绝 code（code2session 错误响应）" do
      Fixtures.stub_code2session(%{wechat: Fixtures.code2session_error_body(:wechat)})

      users_before = user_count()
      identities_before = identity_count()

      assert {:error, %AuthenticationFailed{}} =
               sign_in("wechat", "bad-code", "whatever", "whatever")

      assert user_count() == users_before
      assert identity_count() == identities_before
    end

    test "手机号解密失败（encryptedData 与 session_key 不匹配）" do
      # 用与 stub 返回的 session_key 不同的密钥加密 → 解密必然失败
      {_body, encrypted_data, iv} =
        login_fixture(:wechat, "w-openid-bad", Fixtures.phone_payload("13800000004"))

      Fixtures.stub_code2session(%{
        wechat:
          Fixtures.code2session_body(:wechat, %{
            openid: "w-openid-bad",
            session_key: Fixtures.new_session_key()
          })
      })

      users_before = user_count()

      assert {:error, %AuthenticationFailed{}} =
               sign_in("wechat", "login-code-4", encrypted_data, iv)

      assert user_count() == users_before
      assert identities_with_uid("w-openid-bad") == []
    end

    test "watermark appid 与本应用不符（跨应用数据注入防护）" do
      payload =
        Fixtures.phone_payload("13800000005", watermark_appid: "someone-elses-appid")

      {body, encrypted_data, iv} = login_fixture(:wechat, "w-openid-wm", payload)
      Fixtures.stub_code2session(%{wechat: body})

      users_before = user_count()

      assert {:error, %AuthenticationFailed{}} =
               sign_in("wechat", "login-code-5", encrypted_data, iv)

      assert user_count() == users_before
      assert users_with_phone("+8613800000005") == []
    end

    test "非法 platform 值" do
      users_before = user_count()

      assert {:error, _} = sign_in("bogus", "code", "data", "iv")

      assert user_count() == users_before
    end

    test "countryCode 缺失（本地号）：fail-closed 拒绝登录（防同号双 User 分裂）" do
      # 只有本地号、无 countryCode → 无法确定规范形 → 拒绝（Q2 归一的前提是全平台确定性）
      payload = %{"phoneNumber" => "13800000008", "purePhoneNumber" => "13800000008"}

      {body, encrypted_data, iv} = login_fixture(:wechat, "w-openid-nocc", payload)
      Fixtures.stub_code2session(%{wechat: body})

      users_before = user_count()

      assert {:error, %AuthenticationFailed{}} =
               sign_in("wechat", "login-code-8", encrypted_data, iv)

      assert user_count() == users_before
      assert identities_with_uid("w-openid-nocc") == []
    end

    test "countryCode 缺失（已带区号的 phoneNumber）：同样 fail-closed（不猜测区号）" do
      # phoneNumber 看似已含 86 区号——但无 countryCode 佐证时无法与本地号区分，
      # 若放行则与带 cc 分支（"+8613…"）规范形不一致 → 同号双 User。必须拒绝。
      payload = %{"phoneNumber" => "8613800000009"}

      {body, encrypted_data, iv} = login_fixture(:wechat, "w-openid-nocc2", payload)
      Fixtures.stub_code2session(%{wechat: body})

      users_before = user_count()

      assert {:error, %AuthenticationFailed{}} =
               sign_in("wechat", "login-code-9", encrypted_data, iv)

      assert user_count() == users_before
    end
  end

  describe "session_key 不出后端（红线）" do
    test "token claims / user metadata / identity 均不含 session_key" do
      # 可识别的 16 字节 session_key（Base64）
      session_key = Base.encode64("LEAKCHECKSECRET!")

      body =
        Fixtures.code2session_body(:wechat, %{openid: "w-openid-leak", session_key: session_key})

      {encrypted_data, iv} =
        Fixtures.encrypt_phone(session_key, Fixtures.phone_payload("13800000006"))

      Fixtures.stub_code2session(%{wechat: body})

      assert {:ok, user} = sign_in("wechat", "login-code-6", encrypted_data, iv)

      {:ok, claims} = Jwt.peek(user.__metadata__.token)
      refute inspect(claims) =~ session_key
      refute inspect(user.__metadata__) =~ session_key

      assert [identity] = all_identities()
      refute inspect(identity) =~ session_key
    end

    test "解密失败时错误对象不含 session_key" do
      session_key = Base.encode64("LEAKCHECKSECRET!")

      Fixtures.stub_code2session(%{
        wechat:
          Fixtures.code2session_body(:wechat, %{
            openid: "w-openid-leak2",
            session_key: session_key
          })
      })

      # 用另一个 key 加密 → 服务端解密失败，错误对象不得携带 session_key
      {encrypted_data, iv} =
        Fixtures.encrypt_phone(Fixtures.new_session_key(), Fixtures.phone_payload("13800000007"))

      assert {:error, %AuthenticationFailed{} = error} =
               sign_in("wechat", "login-code-7", encrypted_data, iv)

      refute inspect(error) =~ session_key
      refute Exception.message(error) =~ session_key
    end

    test "失败路径的服务端日志不含 session_key（capture_log）" do
      import ExUnit.CaptureLog

      session_key = Base.encode64("LEAKCHECKSECRET!")
      wrong_key = Fixtures.new_session_key()

      # code2session 成功拿到 session_key 后解密失败（错误日志路径），
      # 日志只能含净化后的 reason（:phone_decrypt_failed），绝不含密钥材料。
      Fixtures.stub_code2session(%{
        wechat:
          Fixtures.code2session_body(:wechat, %{
            openid: "w-openid-leak3",
            session_key: session_key
          })
      })

      {encrypted_data, iv} =
        Fixtures.encrypt_phone(wrong_key, Fixtures.phone_payload("13800000030"))

      log =
        capture_log(fn ->
          assert {:error, %AuthenticationFailed{}} =
                   sign_in("wechat", "login-code-leak3", encrypted_data, iv)
        end)

      assert log =~ "phone_decrypt_failed"
      refute log =~ session_key, "失败日志不得含 session_key"
      refute log =~ wrong_key, "失败日志不得含任何会话密钥材料"
    end

    test "session_key 不落任何 DB 行（原始列值断言）" do
      session_key = Base.encode64("LEAKCHECKSECRET!")

      body =
        Fixtures.code2session_body(:wechat, %{
          openid: "w-openid-leak4",
          session_key: session_key
        })

      {encrypted_data, iv} =
        Fixtures.encrypt_phone(session_key, Fixtures.phone_payload("13800000031"))

      Fixtures.stub_code2session(%{wechat: body})

      assert {:ok, user} = sign_in("wechat", "login-code-leak4", encrypted_data, iv)

      %{rows: user_rows} =
        Ecto.Adapters.SQL.query!(
          Cgc2046.Repo,
          "SELECT id::text, COALESCE(email::text, ''), COALESCE(phone, ''), COALESCE(hashed_password, '') FROM users WHERE id::text = $1",
          [user.id]
        )

      %{rows: identity_rows} =
        Ecto.Adapters.SQL.query!(
          Cgc2046.Repo,
          "SELECT provider, uid, COALESCE(unionid, '') FROM user_identities WHERE uid = 'w-openid-leak4'"
        )

      %{rows: token_rows} =
        Ecto.Adapters.SQL.query!(
          Cgc2046.Repo,
          "SELECT jti, subject, purpose, COALESCE(extra_data::text, '') FROM tokens WHERE subject = $1",
          ["user?id=" <> user.id]
        )

      for rows <- [user_rows, identity_rows, token_rows] do
        assert rows != []
        refute inspect(rows) =~ session_key, "DB 行任何列不得含 session_key"
      end
    end
  end

  describe "同手机号跨平台归一（Q2 phone-keyed 统一）" do
    test "wechat 本地号负载与 tt 带区号负载归一到同一 User" do
      # wechat 负载：phoneNumber 不带区号 + countryCode "86"
      {wechat_body, wechat_ed, wechat_iv} =
        login_fixture(:wechat, "w-openid-uni", Fixtures.phone_payload("13800000010"))

      # tt 负载：仅 phoneNumber（已带 86 区号，无 purePhoneNumber）——覆盖另一条归一化分支
      {tt_body, tt_ed, tt_iv} =
        login_fixture(
          :tt,
          "t-openid-uni",
          %{"phoneNumber" => "8613800000010", "countryCode" => "86"}
        )

      Fixtures.stub_code2session(%{wechat: wechat_body, tt: tt_body})

      assert {:ok, wechat_user} = sign_in("wechat", "code-w", wechat_ed, wechat_iv)
      assert {:ok, tt_user} = sign_in("tt", "code-t", tt_ed, tt_iv)

      assert wechat_user.id == tt_user.id,
             "同一手机号跨平台应归一到同一 User（wechat #{wechat_user.id} vs tt #{tt_user.id}）"

      assert [found_user] = users_with_phone("+8613800000010")
      assert found_user.id == wechat_user.id

      identities = all_identities() |> Enum.sort_by(& &1.provider)
      assert length(identities) == 2
      assert Enum.all?(identities, &(&1.user_id == wechat_user.id))
      assert Enum.map(identities, & &1.provider) == [:tt, :wechat]
    end
  end

  describe "重登与 Identity upsert" do
    test "同平台重登：吊销旧 jti、签发新 token、同一 User、Identity 不重复" do
      payload = Fixtures.phone_payload("13800000011")
      # 同一 stub 服务两次登录 → 两次 encryptedData 用同一 session_key 加密
      session_key = Fixtures.new_session_key()

      body =
        Fixtures.code2session_body(:wechat, %{openid: "w-openid-re", session_key: session_key})

      {ed1, iv1} = Fixtures.encrypt_phone(session_key, payload)
      {ed2, iv2} = Fixtures.encrypt_phone(session_key, payload)
      Fixtures.stub_code2session(%{wechat: body})

      assert {:ok, user1} = sign_in("wechat", "code-re-1", ed1, iv1)
      assert {:ok, user2} = sign_in("wechat", "code-re-2", ed2, iv2)
      assert user1.id == user2.id

      token1 = user1.__metadata__.token
      token2 = user2.__metadata__.token
      assert token1 != token2

      {:ok, claims1} = Jwt.peek(token1)
      {:ok, claims2} = Jwt.peek(token2)

      purposes = token_purposes(user1)

      # 旧 jti 被吊销（白名单 purpose 覆盖为 revocation），新 jti 为有效 user token
      assert purposes[claims1["jti"]] == "revocation"
      assert purposes[claims2["jti"]] == "user"

      assert [identity] = all_identities()
      assert identity.uid == "w-openid-re"
    end

    test "重登补齐 unionid（首次未返回 → upsert 更新）" do
      payload = Fixtures.phone_payload("13800000012")
      {body_no_union, ed1, iv1} = login_fixture(:wechat, "w-openid-up", payload)
      Fixtures.stub_code2session(%{wechat: body_no_union})

      assert {:ok, user} = sign_in("wechat", "code-up-1", ed1, iv1)
      assert [%{unionid: nil}] = all_identities()

      # 第二次登录平台返回 unionid（用户绑定了开放平台）→ Identity 更新
      {body_with_union, ed2, iv2} =
        login_fixture(:wechat, "w-openid-up", payload, "w-unionid-late")

      Fixtures.stub_code2session(%{wechat: body_with_union})

      assert {:ok, user2} = sign_in("wechat", "code-up-2", ed2, iv2)
      assert user2.id == user.id
      assert [%{unionid: "w-unionid-late"}] = all_identities()
    end

    test "平台账号换绑手机号：Identity 随当前验证手机号重指向" do
      # 同一平台账号（openid 不变）先绑定手机号 A，后换绑手机号 B。
      # phone 是 User 锚 → 第二次登录建新 User，Identity 重指向新锚。
      {body_a, ed_a, iv_a} =
        login_fixture(:wechat, "w-openid-mv", Fixtures.phone_payload("13800000013"))

      Fixtures.stub_code2session(%{wechat: body_a})
      assert {:ok, user_a} = sign_in("wechat", "code-mv-a", ed_a, iv_a)

      {body_b, ed_b, iv_b} =
        login_fixture(:wechat, "w-openid-mv", Fixtures.phone_payload("13800000014"))

      Fixtures.stub_code2session(%{wechat: body_b})
      assert {:ok, user_b} = sign_in("wechat", "code-mv-b", ed_b, iv_b)

      assert user_a.id != user_b.id

      assert [identity] = all_identities()
      assert identity.uid == "w-openid-mv"
      assert identity.user_id == user_b.id
    end
  end
end
