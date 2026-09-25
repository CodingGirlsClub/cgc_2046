alias Cgc2046.Flashback.{EventArchive, Person, Answer, QuoteLicense, Quotes, Public}
alias Cgc2046.Repo
unless String.contains?(Repo.config()[:database], "codex_mp_voices_batch_1"), do: raise("Requires isolated batch-1 development database")
create = fn resource, attrs -> resource |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!(authorize?: false) end
{:ok, existing} = Public.voice_cities()
existing = MapSet.new(existing, & &1.name)
cities = ~w(北京 长春 长沙 成都 重庆 大连 福州 广州 贵阳 哈尔滨 海口 杭州 合肥 济南 昆明 兰州 南昌 南京 南宁 宁波 青岛 厦门 上海 深圳 沈阳 苏州 太原 天津 武汉 西安)
missing = Enum.reject(cities, &MapSet.member?(existing, &1))
if missing != [] do
  archive = create.(EventArchive, %{key: "voices-30-cities", name: "城市交互合成示例", city: "北京", occurred_on: ~D[2015-01-11], applied_count: length(missing), attended_count: length(missing)})
  Enum.each(missing, fn city ->
    person = create.(Person, %{archive_event_id: archive.id, full_name: "城市示例", surname: "城", city: city, role: :learner, participation: :attended})
    text = "在#{city}，和一群女生一起学会新的东西，把想法变成自己的作品。"
    create.(Answer, %{person_id: person.id, question_key: "self_intro", raw_text: text})
    license = create.(QuoteLicense, %{person_id: person.id, level: :anonymous, chosen_quote_spans: [%{"question_key" => "self_intro", "start" => 0, "len" => String.length(text)}]})
    {:ok, [_ | _]} = Quotes.sync_for_license(license)
  end)
end
{:ok, result} = Public.voice_cities()
IO.puts("PUBLIC_VOICE_CITY_COUNT=#{length(result)}")
