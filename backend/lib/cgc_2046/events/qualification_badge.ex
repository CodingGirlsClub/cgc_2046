defmodule Cgc2046.Events.QualificationBadge do
  @moduledoc "Public qualification labels derived from the confirmed enrollment count."
  alias Cgc2046.Repo

  def badge(event, confirmed_count) do
    status = to_string(event.status)
    qualification = to_string(event.qualification_status)

    label =
      cond do
        status == "cancelled" -> "cancelled"
        qualification == "confirmed" -> "confirmed"
        status == "closed" -> "closed"
        is_integer(event.min_participants) -> "short_by"
        true -> "open"
      end

    %{
      archived: status in ["closed", "cancelled"],
      qualification_badge: label,
      short_by: if(label == "short_by", do: max(event.min_participants - confirmed_count, 0))
    }
  end

  def project(records, field) do
    ids = Enum.map(records, &Repo.uuid!(&1.id))

    counts =
      case ids do
        [] ->
          %{}

        _ ->
          %{rows: rows} =
            Repo.query!(
              "SELECT event_id, COUNT(*) FROM enrollments WHERE event_id = ANY($1::uuid[]) AND status = 'confirmed' GROUP BY event_id",
              [ids]
            )

          Map.new(rows, fn [id, count] -> {Ecto.UUID.load!(id), count} end)
      end

    Enum.map(records, &Map.fetch!(badge(&1, Map.get(counts, &1.id, 0)), field))
  end
end
