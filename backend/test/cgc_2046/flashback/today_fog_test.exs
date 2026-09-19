defmodule Cgc2046.Flashback.TodayFogTest do
  @moduledoc """
  U10 第二刀：今天的你句级雾面 + 金句宿主扩展。

  - adjust_today_fog：合法 spans 落 fog_spans[field]；越界/重叠拒；非法 field 拒；
    无 Today 记录时自动建（ensure_today 幂等）。
  - 金句宿主：today.now/want/need/say 合法（回落 Today 字段文本校验）；
    today.* 越界拒；未知 today 字段按宿主不存在拒；当年答案宿主不受影响。
  - 投影：today 金句取文本（answer_raw_text fallback）与当年同规则 mask。
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{EventArchive, Person, Today}
  alias Cgc2046.Flashback.Tokens

  defp create_person do
    archive =
      EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "2014-01-11-bj",
        name: "Rails Girls Beijing",
        city: "北京",
        occurred_on: ~D[2014-01-11],
        applied_count: 344,
        attended_count: 102
      })
      |> Ash.create!(authorize?: false)

    Person
    |> Ash.Changeset.for_create(:create, %{
      archive_event_id: archive.id,
      full_name: "王小明",
      surname: "王",
      city: "北京",
      occupation_then: "测试工程师",
      role: :learner,
      participation: :attended,
      phone: "13900000001",
      email: "person@example.com"
    })
    |> Ash.create!(authorize?: false)
  end

  defp submit_today(person, fields) do
    Tokens.submit_today_as_person(person.id, fields)
  end

  describe "adjust_today_fog（今天的你句级雾面）" do
    test "合法 spans 落 fog_spans[field]；未启用字段不受影响" do
      person = create_person()
      {:ok, _} = submit_today(person, %{now_status: "还在写代码，下班带娃。", say: "十周年快乐！"})

      # 「还在写代码，」= 7 graphemes（含逗号），合法区间
      spans = [%{"start" => 0, "len" => 7}]

      assert {:ok, %{field: "now", fog_spans: fog}} =
               Tokens.adjust_today_fog_as_person(person.id, "now", spans)

      assert %{"now" => [%{"start" => 0, "len" => 7}]} = fog

      # 再雾另一字段：既有键保留
      assert {:ok, %{fog_spans: fog2}} =
               Tokens.adjust_today_fog_as_person(person.id, "say", [%{"start" => 0, "len" => 3}])

      assert Map.keys(fog2) |> Enum.sort() == ["now", "say"]
    end

    test "越界拒（fail-closed，不落库）" do
      person = create_person()
      {:ok, _} = submit_today(person, %{say: "十周年快乐！"})

      assert {:error, %{reason: :quote_span_out_of_bounds}} =
               Tokens.adjust_today_fog_as_person(person.id, "say", [%{"start" => 0, "len" => 99}])
    end

    test "非法 field 拒" do
      person = create_person()
      {:ok, _} = submit_today(person, %{say: "十周年快乐！"})

      assert {:error, %{reason: :invalid_today_field}} =
               Tokens.adjust_today_fog_as_person(person.id, "mood", [%{"start" => 0, "len" => 2}])
    end

    test "无 Today 记录时自动建（空文本越界拒——不凭空造可雾文本）" do
      person = create_person()

      assert {:error, %{reason: :quote_span_out_of_bounds}} =
               Tokens.adjust_today_fog_as_person(person.id, "want", [%{"start" => 0, "len" => 1}])
    end
  end

  describe "金句宿主扩展（today.now/want/need/say）" do
    test "today 宿主合法：校验过、落 spans" do
      person = create_person()
      {:ok, _} = submit_today(person, %{say: "十周年快乐！愿更多人写下第一行代码。"})

      # 「十周年快乐！」= 6 graphemes
      spans = [%{question_key: "today.say", start: 0, len: 6}]

      assert {:ok, _license} =
               Tokens.set_quote_license_as_person(person.id, %{
                 level: "anonymous",
                 chosen_quote_spans: spans
               })
    end

    test "today 宿主越界拒" do
      person = create_person()
      {:ok, _} = submit_today(person, %{say: "十周年快乐！"})

      assert {:error, %{reason: :quote_span_out_of_bounds}} =
               Tokens.set_quote_license_as_person(person.id, %{
                 level: "anonymous",
                 chosen_quote_spans: [%{question_key: "today.say", start: 0, len: 99}]
               })
    end

    test "未知 today 字段按宿主不存在拒" do
      person = create_person()

      assert {:error, %{reason: :answer_not_found}} =
               Tokens.set_quote_license_as_person(person.id, %{
                 level: "anonymous",
                 chosen_quote_spans: [%{question_key: "today.mood", start: 0, len: 1}]
               })
    end

    test "未提交 today 文本：无 Today 记录按宿主不存在拒（fail-closed）" do
      person = create_person()

      assert {:error, %{reason: :answer_not_found}} =
               Tokens.set_quote_license_as_person(person.id, %{
                 level: "anonymous",
                 chosen_quote_spans: [%{question_key: "today.say", start: 0, len: 2}]
               })
    end

    test "当年答案宿主不受影响（回归）" do
      person = create_person()

      Flashback.Answer
      |> Ash.Changeset.for_create(:create, %{
        person_id: person.id,
        question_key: "self_intro",
        raw_text: "我想亲眼看看是不是。"
      })
      |> Ash.create!(authorize?: false)

      assert {:ok, _} =
               Tokens.set_quote_license_as_person(person.id, %{
                 level: "anonymous",
                 chosen_quote_spans: [%{question_key: "self_intro", start: 0, len: 6}]
               })

      assert {:error, %{reason: :answer_not_found}} =
               Tokens.set_quote_license_as_person(person.id, %{
                 level: "anonymous",
                 chosen_quote_spans: [%{question_key: "nonexistent", start: 0, len: 1}]
               })
    end
  end

  describe "投影（金句墙取文本）" do
    test "today 金句文本回落 Today 字段并按句 mask" do
      person = create_person()
      {:ok, _} = submit_today(person, %{say: "十周年快乐！愿更多人写下第一行代码。"})

      assert {:ok, _} =
               Tokens.set_quote_license_as_person(person.id, %{
                 level: "anonymous",
                 chosen_quote_spans: [%{question_key: "today.say", start: 0, len: 6}]
               })

      # capsule 投影的 me.quote 经 answer_raw_text fallback 取 today.say 文本
      # （mask 无 fog spans → 原样首句「十周年快乐！」）
      {:ok, capsule} = Cgc2046.Flashback.AlumniProjection.capsule(%{person: person}, nil)
      assert capsule.me.quote =~ "十周年快乐"
    end
  end

  defp submit_today_as_person(person_id, fields) do
    # DataCase 直写,绕开 token 面:Today upsert 与 submit_today 同规则
    Today
    |> Ash.Changeset.for_create(:create, Map.put(fields, :person_id, person_id))
    |> Ash.create(authorize?: false)
  end
end
