defmodule Cgc2046.Flashback.StructuredPiiQuoteTest do
  @moduledoc """
  结构化 PII 答案的金句/雾面白名单回归（R16a）。

  导入时为四个结构化 PII 答案键（full_name/phone/email/wechat）写**整段雾**
  （`Import.pii_answer/2` + `full_span/1`），这是平台「这类键默认不可见」的
  承诺。同域其它对外面都硬编码了排除这四键的白名单（`me_answers` 胶囊面、
  名册墙、分享卡），**只有金句授权面没有**——而该面唯一的写入门禁
  `ensure_quote_not_fogged` 检查的是「当前雾状态」，同一个凭据能先
  `adjust_fog(spans: [])` 把雾清掉再授权。两步即可把手机号/邮箱/微信号/姓名
  发到**匿名**金句墙（署名含姓+城市+年份、带可分享深链），受害人自己的胶囊面
  看不到 PII 雾状态，因此察觉不到。

  本文件钉住：这两个面都不得触达结构化 PII 键。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.Flashback.{Answer, EventArchive, Person, Tokens}

  @pii_keys ["full_name", "phone", "email", "wechat"]

  defp create_person(attrs \\ %{}) do
    archive =
      EventArchive
      |> Ash.Changeset.for_create(:create, %{key: "2014-01-11-bj", name: "RG", city: "北京"})
      |> Ash.create!(authorize?: false)

    Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          archive_event_id: archive.id,
          full_name: "王小明",
          surname: "王",
          city: "北京",
          role: :learner,
          participation: :attended,
          phone: "13900000001",
          email: "person@example.com"
        },
        attrs
      )
    )
    |> Ash.create!(authorize?: false)
  end

  # 导入形态：结构化 PII 答案带整段雾
  defp create_pii_answer(person, key, value) do
    Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: key,
      raw_text: value,
      fog_spans: [%{"start" => 0, "len" => String.length(value)}]
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_free_text_answer(person, key, value, fog \\ []) do
    Answer
    |> Ash.Changeset.for_create(:create, %{
      person_id: person.id,
      question_key: key,
      raw_text: value,
      fog_spans: fog
    })
    |> Ash.create!(authorize?: false)
  end

  defp reload_answer(id) do
    Answer |> Ash.Query.filter(id == ^id) |> Ash.read_one!(authorize?: false)
  end

  defp quote_count(answer_id) do
    Cgc2046.Flashback.Quote
    |> Ash.Query.filter(answer_id == ^answer_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  describe "雾面调整：结构化 PII 键不可去雾" do
    test "四个 PII 键一一被拒，且雾区间原样保留" do
      person = create_person()

      for key <- @pii_keys do
        answer = create_pii_answer(person, key, "13900000001")

        assert {:error, %{code: "flashback_invalid_input"}} =
                 Tokens.adjust_fog_as_person(person.id, answer.id, [])

        # 雾未被清空（关键：不是「报错但已改」）
        assert [%{"len" => _}] = reload_answer(answer.id).fog_spans
      end
    end

    test "自由文本答案仍可正常去雾（防过度收窄）" do
      person = create_person()

      answer =
        create_free_text_answer(person, "self_intro", "我爱写代码", [%{"start" => 0, "len" => 5}])

      assert {:ok, _} = Tokens.adjust_fog_as_person(person.id, answer.id, [])
      assert reload_answer(answer.id).fog_spans == []
    end
  end

  describe "金句授权：结构化 PII 键不可上墙" do
    test "对 PII 键授权被拒（即使雾已被清空时也一样）" do
      person = create_person()
      answer = create_pii_answer(person, "phone", "13900000001")

      # 先按原缺陷链清雾（若清雾被允许，本步会成功——但授权必须仍被拒）
      _ = Tokens.adjust_fog_as_person(person.id, answer.id, [])

      assert {:error, %{code: "flashback_invalid_input"}} =
               Tokens.set_quote_license_as_person(person.id, %{
                 level: "anonymous",
                 chosen_quote_spans: [
                   %{"question_key" => "phone", "start" => 0, "len" => 11}
                 ]
               })

      # 授权被拒即无 Quote 行落库（公开墙的唯一数据源）
      assert quote_count(answer.id) == 0
    end

    test "自由文本答案授权照旧成功（防过度收窄）" do
      person = create_person()
      _ = create_free_text_answer(person, "self_intro", "我爱写代码，也爱做饭")

      assert {:ok, _} =
               Tokens.set_quote_license_as_person(person.id, %{
                 level: "anonymous",
                 chosen_quote_spans: [
                   %{"question_key" => "self_intro", "start" => 0, "len" => 5}
                 ]
               })
    end
  end
end
