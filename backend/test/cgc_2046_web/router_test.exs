defmodule Cgc2046Web.RouterTest do
  @moduledoc """
  /ops/admin（AshAdmin 挂载）门控测试（Phase 6 / R12）：

  - platform_admin GET /ops/admin -> 200（放行，AshAdmin dashboard 渲染）
  - 非 platform_admin GET /ops/admin -> 403（PlatformAdminPlug 拦截）
  - 未认证 GET /ops/admin -> 403

  门控由 :admin_browser pipeline 末尾的 PlatformAdminPlug 承担
  （不依赖 ash_admin 的 actor impersonation 机制）。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Notifications.{Notification, NotificationConsent, NotificationDelivery}
  alias Cgc2046Web.Live.PlatformAdminLiveAuth

  # 走真实 signIn GraphQL mutation 拿 cgc_token（与 graphql_profile_test 同源范式），
  # 保证 :admin_browser 的 AuthCookiePlug/load_from_bearer 全链路与生产一致。
  defp sign_in_token(email) do
    query = """
    mutation {
      signIn(login: "#{email}", password: "#{Fixtures.password()}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  describe "GET /ops/admin (AshAdmin)" do
    test "platform_admin 可访问（200，dashboard 渲染）" do
      admin = Fixtures.platform_admin("router-admin")
      token = sign_in_token(admin.email)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/ops/admin")

      assert conn.status == 200
    end

    test "非 platform_admin 被 403" do
      user = Fixtures.register_user("router-regular")
      token = sign_in_token(user.email)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/ops/admin")

      assert conn.status == 403
    end

    test "未认证被 403" do
      conn = build_conn() |> get("/ops/admin")

      assert conn.status == 403
    end

    test "非 admin 访问子路径也被 403" do
      user = Fixtures.register_user("router-regular2")
      token = sign_in_token(user.email)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/ops/admin/users")

      assert conn.status == 403
    end
  end

  test "generated admin menu excludes private inbox while legacy notification resources still render" do
    admin = Fixtures.platform_admin("inbox-admin-menu")
    victim = Fixtures.register_user("inbox-admin-victim")
    private = private_notification(victim)
    consent_id = Ecto.UUID.generate()

    Cgc2046.Repo.query!(
      """
      INSERT INTO notification_consents (id,user_id,platform,template_key,remaining_uses,inserted_at,updated_at)
      VALUES ($1,$2,'wechat','admin-consent-fixture',2,now(),now())
      """,
      [Cgc2046.Repo.uuid!(consent_id), Cgc2046.Repo.uuid!(victim.id)]
    )

    delivery =
      NotificationDelivery
      |> Ash.Changeset.for_create(
        :create,
        %{
          idempotency_key: "admin-delivery-fixture",
          user_id: victim.id,
          template_key: "admin-delivery-fixture",
          data: %{},
          job_meta: %{}
        },
        authorize?: false
      )
      |> Ash.create!()

    token = sign_in_token(admin.email)
    html = admin_html(token, nil)
    choices = admin_resource_links(html)
    assert AshAdmin.Resource.name(NotificationConsent) in choices
    assert AshAdmin.Resource.name(NotificationDelivery) in choices
    refute AshAdmin.Resource.name(Notification) in choices
    refute String.contains?(html, private.id)

    consent = Ash.get!(NotificationConsent, consent_id, authorize?: false)
    consent_key = AshAdmin.Helpers.encode_primary_key(consent)
    delivery_key = AshAdmin.Helpers.encode_primary_key(delivery)
    consent_html = admin_html(token, NotificationConsent, %{"primary_key" => consent_key})
    delivery_html = admin_html(token, NotificationDelivery, %{"primary_key" => delivery_key})
    consent_rendered = String.contains?(consent_html, "admin-consent-fixture")
    delivery_rendered = String.contains?(delivery_html, "admin-delivery-fixture")
    assert consent_rendered
    assert delivery_rendered

    assert {:ok, %{id: ^consent_id, remaining_uses: 2}} =
             selected_resource(admin, NotificationConsent, %{"primary_key" => consent_key}).assigns.record

    assert {:ok, %{template_key: "admin-delivery-fixture"}} =
             selected_resource(admin, NotificationDelivery, %{"primary_key" => delivery_key}).assigns.record
  end

  test "real admin direct resource selection cannot reach private inbox read or purge actions" do
    admin = Fixtures.platform_admin("inbox-admin-direct")
    victim = Fixtures.register_user("inbox-admin-direct-victim")
    private = private_notification(victim)
    selected = selected_resource(admin, Notification)
    assert selected.assigns.resource == NotificationConsent
    assert selected.assigns.action.name == :read
    html = admin_html(sign_in_token(admin.email), Notification)
    refute String.contains?(html, private.id)
    refute AshAdmin.Resource.name(Notification) in admin_resource_links(html)

    assert_raise AshAdmin.Errors.NotFound, fn ->
      selected_resource(admin, Notification, %{"action_type" => "read", "action" => "retention"})
    end

    unavailable =
      selected_resource(admin, Notification, %{"action_type" => "destroy", "action" => "purge"})

    assert unavailable.assigns.resource == NotificationConsent
    assert unavailable.assigns.action == nil

    assert Ash.get!(Notification, private.id, action: :retention, authorize?: false).payload[
             "title"
           ] == "合成私有通知"
  end

  defp private_notification(user) do
    Notification
    |> Ash.Changeset.for_create(:record, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attributes(%{
      id: "private-admin-fixture-" <> user.id,
      user_id: user.id,
      type: "enrollment_completed",
      payload: %{"title" => "合成私有通知", "body" => "仅供所属合成账号读取。"}
    })
    |> Ash.create!()
  end

  defp admin_html(token, resource, extra \\ %{}) do
    params = %{"domain" => AshAdmin.Domain.name(Cgc2046.Notifications)}

    params =
      if resource, do: Map.put(params, "resource", AshAdmin.Resource.name(resource)), else: params

    params = Map.merge(params, extra)

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/ops/admin?" <> URI.encode_query(params))
    |> html_response(200)
  end

  defp admin_resource_links(html) do
    Regex.scan(~r/href="([^"]+)"/, html, capture: :all_but_first)
    |> Enum.map(fn [href] -> URI.parse(String.replace(href, "&amp;", "&")).query end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&URI.decode_query/1)
    |> Enum.filter(&(&1["domain"] == AshAdmin.Domain.name(Cgc2046.Notifications)))
    |> Enum.map(& &1["resource"])
  end

  defp selected_resource(admin, resource, extra \\ %{}) do
    session = %{
      PlatformAdminLiveAuth.session_key() => admin.id,
      "prefix" => "/ops/admin",
      "request_path" => "/ops/admin"
    }

    socket = %Phoenix.LiveView.Socket{
      endpoint: Cgc2046Web.Endpoint,
      id: "admin-private-boundary",
      private: %{connect_params: %{}}
    }

    {:cont, socket} = PlatformAdminLiveAuth.on_mount(:default, %{}, session, socket)
    {:ok, socket} = AshAdmin.PageLive.mount(%{}, session, socket)

    params =
      Map.merge(
        %{
          "domain" => AshAdmin.Domain.name(Cgc2046.Notifications),
          "resource" => AshAdmin.Resource.name(resource)
        },
        extra
      )

    {:noreply, socket} =
      AshAdmin.PageLive.handle_params(
        params,
        "http://localhost/ops/admin?" <> URI.encode_query(params),
        socket
      )

    socket
  end
end
