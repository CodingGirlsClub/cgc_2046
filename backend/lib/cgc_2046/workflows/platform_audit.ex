defmodule Cgc2046.Workflows.PlatformAudit do
  @moduledoc """
  Redacted WorkflowRun metadata for Platform Admin audit only.
  """

  import Ecto.Query, only: [from: 2, where: 3]
  alias Cgc2046.Repo

  def list(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    status = Keyword.get(opts, :status)
    started_after = Keyword.get(opts, :started_after)
    started_before = Keyword.get(opts, :started_before)

    query =
      from(r in "workflow_runs",
        join: d in "workflow_definitions",
        on: d.id == r.definition_id,
        order_by: [desc: r.inserted_at],
        limit: 100,
        select: %{
          id: type(r.id, Ecto.UUID),
          workspace_id: type(r.workspace_id, Ecto.UUID),
          definition_type: d.type,
          status: r.status,
          started_at: type(r.started_at, :utc_datetime_usec),
          finished_at: type(r.finished_at, :utc_datetime_usec),
          inserted_at: type(r.inserted_at, :utc_datetime_usec),
          error_summary:
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE NULL END",
              r.status,
              "failed",
              "workflow_failed"
            )
        }
      )

    query =
      if workspace_id, do: where(query, [r, _d], r.workspace_id == ^workspace_id), else: query

    query = if status, do: where(query, [r, _d], r.status == ^status), else: query

    query =
      if started_after, do: where(query, [r, _d], r.started_at >= ^started_after), else: query

    query =
      if started_before, do: where(query, [r, _d], r.started_at <= ^started_before), else: query

    Repo.all(query)
  end
end
