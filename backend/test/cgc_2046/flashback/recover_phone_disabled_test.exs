defmodule Cgc2046.Flashback.RecoverPhoneDisabledTest do
  @moduledoc """
  手机号找回暂停（2026-09-26）：库里人人有邮箱、未必有手机号，短信按条计费——找回只开放
  邮箱。手机通道代码保留，由 `:flashback_recover_phone_enabled` 关闭（生产默认关）：发起
  同形返回但不发码，验证一律不认——直接调 API 也用不了。test.exs 默认开，让既有用例继续
  覆盖保留的手机通道；本文件钉住关闭态。
  """
  # async: false —— 改全局开关（同 graphql_sign_in_with_platform_rate_limit_test 改 :rate_limits）
  use Cgc2046.DataCase, async: false

  require Ash.Query

  alias Cgc2046.Accounts.{PhoneNumber, PhoneVerificationCode, SignInFlow}
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Person, Recover}

  @ip "10.9.26.1"

  setup do
    previous = Application.get_env(:cgc_2046, :flashback_recover_phone_enabled)
    Application.put_env(:cgc_2046, :flashback_recover_phone_enabled, false)
    on_exit(fn -> Application.put_env(:cgc_2046, :flashback_recover_phone_enabled, previous) end)

    archive =
      Flashback.EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "recover-phone-off",
        name: "Rails Girls Beijing",
        city: "北京"
      })
      |> Ash.create!(authorize?: false)

    person =
      Person
      |> Ash.Changeset.for_create(:create, %{
        archive_event_id: archive.id,
        full_name: "王晓雨",
        surname: "王",
        city: "北京",
        role: :learner,
        participation: :attended,
        phone: "13900000021",
        email: "off@example.com"
      })
      |> Ash.create!(authorize?: false)

    {:ok, phone} = PhoneNumber.normalize("13900000021")
    %{person: person, phone: phone}
  end

  defp codes_for(phone) do
    import Ecto.Query

    Cgc2046.Repo.aggregate(
      from(c in "phone_verification_codes", where: c.phone == ^phone),
      :count
    )
  end

  defp reload(person) do
    Person |> Ash.Query.filter(id == ^person.id) |> Ash.read_one!(authorize?: false)
  end

  test "手机号发起：同形返回（不泄露通道关闭），但不发码", %{phone: phone} do
    assert {:ok, %{dispatched: true}} = Recover.initiate("13900000021", @ip)
    assert codes_for(phone) == 0
  end

  test "手机号验证一律不认：拿到别处签发的有效 :register 码也绑不上档案", %{person: person, phone: phone} do
    {:ok, code, _} = PhoneVerificationCode.issue(phone, :register)
    {:ok, me, _} = SignInFlow.find_or_create_user("+8613800007790")

    assert {:error, %{code: "invalid_or_expired_code"}} = Recover.verify("13900000021", code, %{})

    assert {:error, %{code: "invalid_or_expired_code"}} =
             Recover.verify_for_user("13900000021", code, me)

    assert is_nil(reload(person).user_id)
  end

  test "邮箱通道不受开关影响：照常发恢复邮件" do
    assert {:ok, %{dispatched: true}} = Recover.initiate("off@example.com", @ip)
    assert_received {:email, %{subject: "你的闪念间档案入口", to: [{"", "off@example.com"}]}}
  end
end
