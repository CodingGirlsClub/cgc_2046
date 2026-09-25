alias Cgc2046.Flashback.{EventArchive, Person, Answer, QuoteLicense, Quotes}
alias Cgc2046.Repo
unless String.contains?(Repo.config()[:database], "codex_mp_voices_batch_1"), do: raise("Requires isolated batch-1 development database")
create = fn resource, attrs -> resource |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!(authorize?: false) end
samples = ["我想学会编程，不只是为了完成一个作品，也是为了更勇敢地表达自己。", "我想学会编程，把脑海里那些小小的想法变成真正能用的作品，也想认识一群可以互相鼓励、一起慢慢进步的女生。", "我以前总觉得编程离自己很远，好像只有特别聪明的人才能学会。后来发现，愿意问一个问题、认真试一次、遇到困难再坚持一下，就是开始。我希望有一天，也能把这样的勇气传递给别人。", "我想学会编程，把脑海里那些小小的想法变成真正能用的作品，也想认识一群可以互相鼓励、一起慢慢进步的女生。即使现在还有很多不懂的地方，我也愿意从一个问题、一行代码开始，允许自己走得慢一点。等未来回头看时，希望我记得的不是当时有多害怕，而是自己曾经认真迈出了第一步。"]
archive = create.(EventArchive, %{key: "voices-layout", name: "金句排版长度示例", city: "广州", occurred_on: ~D[2014-01-11], applied_count: 4, attended_count: 4})
Enum.with_index(samples, fn text, index ->
  person = create.(Person, %{archive_event_id: archive.id, full_name: "排版示例", surname: "示", city: "广州", role: :learner, participation: :attended, email: "voices-layout-#{index}@example.invalid"})
  create.(Answer, %{person_id: person.id, question_key: "self_intro", raw_text: text})
  license = create.(QuoteLicense, %{person_id: person.id, level: :anonymous, chosen_quote_spans: [%{"question_key" => "self_intro", "start" => 0, "len" => String.length(text)}]})
  {:ok, [_ | _]} = Quotes.sync_for_license(license)
  IO.puts("LAYOUT_SAMPLE_CHARS=#{String.length(text)}")
end)
