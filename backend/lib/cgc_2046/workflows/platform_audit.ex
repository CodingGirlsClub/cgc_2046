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
          id: r.id,
          workspace_id: r.workspace_id,
          definition_type: d.type,
          status: r.status,
          started_at: r.started_at,
          finished_at: r.finished_at,
          inserted_at: r.inserted_at
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
