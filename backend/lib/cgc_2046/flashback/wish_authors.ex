defmodule Cgc2046.Flashback.WishAuthors do
  @moduledoc "Wish ownership and annual quota across account and historical archive identities."
  require Ash.Query
  alias Cgc2046.Flashback.{Wish, Wishes}
  alias Cgc2046.Repo

  def user_id(%{user_id: user_id}) when is_binary(user_id), do: user_id
  def user_id(%{person: %Cgc2046.Flashback.Person{user_id: id}}), do: id
  def user_id(%{person_id: nil}), do: nil
  def user_id(%{person_id: person_id}), do: resolve({:person, person_id}).user_id

  def resolve({:user, id}) do
    %{rows: rows} =
      Repo.query!("SELECT id FROM flashback_people WHERE user_id=$1 ORDER BY id LIMIT 1", [
        Repo.uuid!(id)
      ])

    %{
      user_id: id,
      person_id:
        case rows do
          [[p]] -> Ecto.UUID.load!(p)
          [] -> nil
        end
    }
  end

  def resolve({:person, id}) do
    %{rows: rows} =
      Repo.query!("SELECT user_id FROM flashback_people WHERE id=$1", [Repo.uuid!(id)])

    %{
      person_id: id,
      user_id:
        case rows do
          [[u]] when not is_nil(u) -> Ecto.UUID.load!(u)
          _ -> nil
        end
    }
  end

  # Lock archive first, then account, on both entry paths. Binding also updates the
  # archive row; resolve again after the lock so a stale unclaimed identity cannot
  # escape the account quota. No external moderation call runs under these locks.
  def lock({:person, id}) do
    case Repo.query!("SELECT id FROM flashback_people WHERE id=$1 FOR UPDATE", [Repo.uuid!(id)]).num_rows do
      0 -> Repo.rollback(%{code: "flashback_person_not_found", message: "没有找到这份档案。"})
      _ -> lock_user(resolve({:person, id}))
    end
  end

  def lock({:user, id}) do
    Repo.query!("SELECT id FROM flashback_people WHERE user_id=$1 ORDER BY id FOR UPDATE", [
      Repo.uuid!(id)
    ])

    lock_user(resolve({:user, id}))
  end

  defp lock_user(%{user_id: nil} = author), do: author

  defp lock_user(author) do
    case Repo.query!("SELECT id FROM users WHERE id=$1 FOR UPDATE", [Repo.uuid!(author.user_id)]).num_rows do
      0 -> Repo.rollback(%{code: "flashback_auth_required", message: "请先登录，再查看或保存愿望。"})
      _ -> author
    end
  end

  def owned_query(%{user_id: id}) when is_binary(id) do
    # Include historical person-only rows, but never override an explicit owner.
    Wish |> Ash.Query.filter(user_id == ^id or (is_nil(user_id) and person.user_id == ^id))
  end

  def owned_query(%{person_id: id}), do: Wish |> Ash.Query.filter(person_id == ^id)

  def owns?(wish, {:user, id}), do: user_id(wish) == id

  def owns?(wish, {:person, id}) when is_binary(id) do
    author = resolve({:person, id})
    wish.person_id == id or (not is_nil(author.user_id) and user_id(wish) == author.user_id)
  end

  def owns?(_, _), do: false

  def quota_remaining(identity) do
    author = if is_tuple(identity), do: resolve(identity), else: identity
    now = DateTime.add(DateTime.utc_now(), 8 * 3600, :second)

    start =
      DateTime.new!(Date.new!(now.year, 1, 1), ~T[00:00:00], "Etc/UTC")
      |> DateTime.add(-8 * 3600, :second)

    count =
      author
      |> owned_query()
      |> Ash.Query.filter(inserted_at >= ^start)
      |> Ash.count!(authorize?: false)

    max(0, 3 - count)
  end

  def mine(user_id) do
    author = resolve({:user, user_id})

    wishes =
      author
      |> owned_query()
      |> Ash.Query.filter(is_nil(deleted_at))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.read!(authorize?: false, page: false)

    {:ok,
     %{
       quota_remaining: quota_remaining(author),
       wishes:
         Enum.map(wishes, fn w ->
           %{
             id: w.id,
             content: w.content,
             city: w.city,
             visibility: w.visibility,
             signature: w.signature,
             inserted_at: w.inserted_at,
             status: Wishes.listing_status(w.visibility, w)
           }
         end)
     }}
  end
end
