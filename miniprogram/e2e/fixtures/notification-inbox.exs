# Synthetic acceptance fixtures only. Refuse the shared/default database.
database = Application.fetch_env!(:cgc_2046, Cgc2046.Repo)[:database]
unless database == "cgc_2046_dev_feat_232_notification_inbox", do: raise("Requires the #232 isolated worktree database")
Logger.configure(level: :warning)
Application.put_env(:cgc_2046, Oban, Application.fetch_env!(:cgc_2046, Oban) |> Keyword.put(:testing, :manual))
Application.put_env(:cgc_2046, Cgc2046Web.Endpoint, Application.fetch_env!(:cgc_2046, Cgc2046Web.Endpoint) |> Keyword.put(:server, true))
{:ok, _} = Application.ensure_all_started(:cgc_2046)
Code.require_file("test/support/accounts_fixtures.ex")
Code.require_file("test/support/events_fixtures.ex")
require Ash.Query
alias Cgc2046.AccountsFixtures, as: Fixtures
alias Cgc2046.Notifications.{Delivery, Fanout, Inbox, Notification}
alias Cgc2046.Repo

# Reuse fixture accounts/graph; workflow ownership has non-cascading FKs.
account = fn email ->
  Cgc2046.Accounts.User |> Ash.Query.filter(email == ^email) |> Ash.read_one!(authorize?: false)
end
a = account.("inbox-232-a@example.test") || Fixtures.register_user_with_email("inbox-232-a@example.test")
b = account.("inbox-232-b@example.test") || Fixtures.register_user_with_email("inbox-232-b@example.test")
admin = case Repo.query!("SELECT id FROM users WHERE email LIKE 'inbox-232-review-%@example.com' ORDER BY inserted_at LIMIT 1").rows do
  [[id]] -> Ash.get!(Cgc2046.Accounts.User, Ecto.UUID.load!(id), authorize?: false)
  [] -> Fixtures.platform_admin("inbox-232-review")
end
workspace = case Repo.query!("SELECT workspace_id FROM workspace_memberships WHERE user_id=$1 LIMIT 1", [Repo.uuid!(admin.id)]).rows do
  [[id]] -> Ash.get!(Cgc2046.Accounts.Workspace, Ecto.UUID.load!(id), authorize?: false)
  [] -> Fixtures.create_workspace(admin, %{name: "通知验收工作台"})
end
event = Cgc2046.Events.Event |> Ash.Query.filter(title == "通知验收活动") |> Ash.read_one!(tenant: workspace.id, authorize?: false)
event = event || Cgc2046.EventsFixtures.create_event(workspace, admin, %{title: "通知验收活动", min_participants: 2})
Repo.query!("UPDATE events SET qualification_status='pending',registration_deadline=now()+interval '7 days' WHERE id=$1", [Repo.uuid!(event.id)])
enrollment = Cgc2046.Admission.Enrollment |> Ash.Query.filter(user_id == ^a.id and event_id == ^event.id) |> Ash.read_one!(tenant: workspace.id, authorize?: false)
enrollment = enrollment || (Cgc2046.Admission.Enrollment |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: a.id}) |> Ash.create!(tenant: workspace.id, actor: a))
ids = Enum.map([a.id,b.id,admin.id], &Repo.uuid!/1)
Repo.transaction(fn ->
  Repo.query!("DELETE FROM oban_jobs WHERE args->>'delivery_id' IN (SELECT id::text FROM notification_deliveries WHERE user_id=ANY($1)) OR args->>'user_id' IN (SELECT id::text FROM users WHERE id=ANY($1))", [ids])
  Repo.query!("DELETE FROM notification_deliveries WHERE user_id=ANY($1)", [ids])
  Repo.query!("DELETE FROM notifications WHERE user_id=ANY($1)", [ids])
end)
Cgc2046.Notifications.Subscriber.handle("enrollment.completed", %{"enrollment_id" => enrollment.id, "user_id" => a.id, "event_id" => event.id, "workspace_id" => workspace.id, "idempotency_key" => "live-completed"})
:ok = Cgc2046.Notifications.Workers.ScheduleChangedFanoutWorker.perform(%Oban.Job{id: 232, args: %{"event_id" => event.id}})
Repo.query!("UPDATE events SET registration_deadline = now() - interval '1 hour' WHERE id=$1", [Repo.uuid!(event.id)])
{:ok, :underfilled, _, 1} = Cgc2046.Events.Qualification.qualify(event)
for i <- 1..23 do
  Fanout.deliver({a.id, [%{provider: :wechat_web, uid: "local-web-only"}]}, "event_reminder", %{"title" => "通知验收活动 #{i}", "starts_at" => "2026-10-05T01:00:00Z"}, %{"event_id" => "live-reminder-#{i}"})
end
Delivery.enqueue({b.id, []}, "enrollment_completed", %{"title" => "账号 B 的活动"}, %{"idempotency_key" => "live-b"})
Notification |> Ash.Changeset.for_create(:record, %{}, authorize?: false)
|> Ash.Changeset.force_change_attributes(%{id: "expired-live", user_id: a.id, type: "event_reminder", payload: %{"title" => "过期记录", "body" => "不能显示"}, inserted_at: DateTime.add(DateTime.utc_now(), -31, :day)}) |> Ash.create!()
endpoint = "http://127.0.0.1:4232/api/graphql"
query = fn document, session ->
  headers = if session, do: [{"authorization", "Bearer " <> session}], else: []
  response = Req.post!(endpoint, json: %{query: document}, headers: headers)
  if response.status != 200, do: raise("Unexpected HTTP status")
  response.body
end
login = fn user ->
  response = Req.post!(endpoint, json: %{query: "mutation { signIn(login: \"#{user.email}\", password: \"#{Fixtures.password()}\") { id } }"})
  if response.status != 200 or response.body["errors"], do: raise("Local fixture login failed")
  cookie = Req.Response.get_header(response, "set-cookie") |> Enum.find(&String.starts_with?(&1, "cgc_token="))
  [_, value] = Regex.run(~r/^cgc_token=([^;]+)/, cookie)
  URI.decode(value)
end
sa = login.(a)
sa2 = login.(a)
sb = login.(b)
sadmin = login.(admin)
feed = "{ notificationFeed(first: 20) { results { id type title body readAt insertedAt deepLink } endKeyset } }"
first = query.(feed, sa)["data"]["notificationFeed"]
true = length(first["results"]) == 20
second = query.("{ notificationFeed(first: 20, after: \"#{first["endKeyset"]}\") { results { id } } }", sa)["data"]["notificationFeed"]["results"]
true = length(second) == 7
true = MapSet.disjoint?(MapSet.new(first["results"], & &1["id"]), MapSet.new(second, & &1["id"]))
row = hd(first["results"])
mark = "mutation { markNotificationRead(id: \"#{row["id"]}\") { result { id readAt } errors { code } } }"
results = [sa,sa2] |> Task.async_stream(fn session -> query.(mark, session)["data"]["markNotificationRead"]["result"] end, max_concurrency: 2) |> Enum.map(fn {:ok, value} -> value end)
[r1, r2] = results
true = is_binary(r1["readAt"]) and r1 == r2
for session <- [sb, sadmin] do
  true = query.(mark, session)["data"]["markNotificationRead"]["result"] == nil
  own = query.(feed, session)["data"]["notificationFeed"]["results"]
  false = Enum.any?(own, &(&1["id"] == row["id"]))
end
true = is_list(query.(feed, nil)["errors"])
true = is_list(query.("{ notificationFeed(filter: {or: []}) { results { id } } }", sa)["errors"])
true = is_list(query.("{ notificationFeed(after: \"malformed\") { results { id } } }", sa)["errors"])
{:ok, 0} = Cgc2046.Notifications.Consent.remaining(a.id, :wechat, "event_reminder")
:ok = Inbox.purge()
:ok = Inbox.purge()
true = Repo.query!("SELECT count(*) FROM notifications WHERE id = 'expired-live'").rows == [[0]]
IO.puts("LIVE_HTTP_PASS: 27 accepted records, 20+7 keyset pages, concurrent readAt identical, actor/admin isolation, anonymous/filter/cursor rejection, quota independent, purge idempotent")
IO.puts("INBOX_232_READY: local endpoint 4232; manual Oban, synthetic fixtures only")
