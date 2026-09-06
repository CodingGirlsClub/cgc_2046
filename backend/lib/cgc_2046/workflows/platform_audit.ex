defmodule Cgc2046.Workflows.PlatformAudit do
  @moduledoc """
  Redacted WorkflowRun metadata for Platform Admin audit only.
  """

  import Ecto.Query, only: [from: 2]
  alias Cgc2046.Repo

  def list(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    status = Keyword.get(opts, :status)

    from(r in "workflow_runs",
      join: d in "workflow_definitions",
      on: d.id == r.definition_id,
      where: is_nil(^workspace_id) or r.workspace_id == ^workspace_id,
      where: is_nil(^status) or r.status == ^status,
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
    |> Repo.all()
  end
end
