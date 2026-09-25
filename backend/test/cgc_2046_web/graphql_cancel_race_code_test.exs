defmodule Cgc2046Web.GraphqlCancelRaceCodeTest do
  @moduledoc """
  R2 阻断 2：cancel 链竞态未收敛时走 `Ash.DataLayer.rollback`，对外保持
  `{:error, …}`——GraphQL 面的 `errors.code` 必须是 `order_already_processed`，
  不能是 raise 形状被 AshGraphql 降级出的 `something_went_wrong`。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Repo

  @tier_id "99999999-9999-9999-9999-999999999999"
  @tier %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}

  test "cancel 竞态未收敛：errors.code == order_already_processed（非 something_went_wrong）" do
    {workspace, enrollment, order} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        admin = Fixtures.platform_admin("cancel-race-graphql-admin-" <> uniq())
        workspace = Fixtures.create_workspace(admin)

        event =
          EventFixtures.create_event(workspace, admin, %{
            pricing_enabled: true,
            price_tiers: [@tier],
            starts_at: DateTime.add(DateTime.utc_now(), 9, :day)
          })

        learner = Fixtures.register_user("cancel-race-graphql-learner-" <> uniq())

        {:ok, enrollment} =
          Enrollment
          |> Ash.Changeset.for_create(:create_enrollment, %{
            event_id: event.id,
            user_id: learner.id,
            tier_id: @tier_id
          })
          |> Ash.create(tenant: workspace.id, actor: learner)

        {:ok, order} =
          Order
          |> Ash.Changeset.for_create(:create, %{
            enrollment_id: enrollment.id,
            provider: :wechat_native,
            out_trade_no: "oto-" <> Ecto.UUID.generate(),
            amount_cents: 19_900,
            tier_snapshot: @tier,
            expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
          })
          |> Ash.create(tenant: workspace.id, authorize?: false)

        {:ok, _} =
          order
          |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-race-graphql"})
          |> Ash.update(tenant: workspace.id, authorize?: false)

        {:ok, _} =
          enrollment
          |> Ash.Changeset.for_update(:settle_paid, %{})
          |> Ash.update(tenant: workspace.id, authorize?: false)

        {workspace, enrollment, order}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM oban_jobs WHERE args->>'order_id' = $1", [order.id])

        Repo.query!("DELETE FROM payments_orders WHERE enrollment_id = $1", [
          Repo.uuid!(order.enrollment_id)
        ])

        Repo.query!("DELETE FROM enrollments WHERE id = $1", [Repo.uuid!(order.enrollment_id)])
      end)
    end)

    # 只吞 claim、不推进（重读仍 paid = 未收敛）
    Repo.query!(
      ~s{CREATE OR REPLACE FUNCTION cgc_gql_race_stuck_fn() RETURNS trigger AS } <>
        ~s{$$ BEGIN IF pg_trigger_depth() = 1 THEN RETURN NULL; ELSE RETURN NEW; END IF; END; $$ LANGUAGE plpgsql;}
    )

    Repo.query!(
      ~s{CREATE TRIGGER gql_race_stuck BEFORE UPDATE ON payments_orders FOR EACH ROW } <>
        ~s{WHEN (OLD.id = '#{order.id}' AND OLD.status = 'paid' AND NEW.status = 'refunding') } <>
        ~s{EXECUTE FUNCTION cgc_gql_race_stuck_fn();}
    )

    token = sign_in_token(Enrollment |> Ash.get!(enrollment.id, authorize?: false) |> user!)

    response =
      graphql(
        """
        mutation {
          cancelEnrollment(id: "#{enrollment.id}") {
            result { id status }
            errors { code message }
          }
        }
        """,
        token
      )

    assert %{"data" => %{"cancelEnrollment" => %{"result" => nil, "errors" => errors}}} =
             response

    codes = Enum.map(errors, & &1["code"])
    assert "order_already_processed" in codes
    refute "something_went_wrong" in codes

    # 取消被回滚：报名保持 confirmed、订单留 paid
    assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
    assert Ash.get!(Order, order.id, tenant: workspace.id, authorize?: false).status == :paid
  end

  defp user!(enrollment) do
    Ash.get!(Cgc2046.Accounts.User, enrollment.user_id, authorize?: false)
  end

  defp sign_in_token(user) do
    mutation = """
    mutation {
      signIn(login: "#{user.email}", password: "#{Fixtures.password()}") { id }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql(query, token) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/graphql", %{"query" => query})

    json_response(conn, 200)
  end

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)
end
