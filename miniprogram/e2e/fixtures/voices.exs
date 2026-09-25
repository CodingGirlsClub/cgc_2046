alias Cgc2046.Flashback.{EventArchive, Person, Answer, QuoteLicense, Quotes}
alias Cgc2046.Repo
unless String.contains?(Repo.config()[:database], "codex_mp_voices_batch_1"), do: raise("Requires isolated batch-1 development database")
create = fn resource, attrs -> resource |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!(authorize?: false) end
samples = [
  {"北京", "王", "我想成为一个，敢说「我不会，但我可以学」的人。"},
  {"成都", "陈", "如果能和一群女生，一起做出自己的作品，那应该很酷。"},
  {"杭州", "周", "希望下一次介绍自己，不只说我喜欢什么，也能说我做出了什么。"},
  {"上海", "许", "原来我不是一个人，在这条路上慢慢摸索。"},
  {"广州", "林", "我想把脑海里的小点子，变成别人也能用的东西。"}
]
Enum.with_index(samples, fn {city, surname, text}, index ->
  archive = create.(EventArchive, %{key: "voices-acceptance-#{index}", name: "金句墙本地验收示例", city: city, occurred_on: ~D[2014-01-11], applied_count: 1, attended_count: 1})
  person = create.(Person, %{archive_event_id: archive.id, full_name: "#{surname}示例", surname: surname, city: city, role: :learner, participation: :attended, email: "voices-demo-#{index}@example.invalid"})
  create.(Answer, %{person_id: person.id, question_key: "self_intro", raw_text: text})
  license = create.(QuoteLicense, %{person_id: person.id, level: :anonymous, chosen_quote_spans: [%{"question_key" => "self_intro", "start" => 0, "len" => String.length(text)}]})
  {:ok, [_ | _]} = Quotes.sync_for_license(license)
end)
IO.puts("SYNTHETIC_FIXTURES_CREATED=5")
