defmodule Cgc2046.Workflows.WorkflowRunSubjectScopeMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../../priv/repo/migrations/20260906000003_add_workflow_run_subject_scope.exs",
               __DIR__
             )

  test "migration preflights malformed UUIDs before casting and aborts unresolved learning runs" do
    source = File.read!(@migration)

    assert source =~ "learning workflow run subject preflight found invalid UUID"
    assert source =~ "learning workflow run subject backfill incomplete"
    assert source =~ "(r.input_snapshot->>'user_id') !~*"
    assert source =~ "AND d.type = 'learning'"
  end
end
