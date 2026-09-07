# Course content / WorkflowRun privacy — cutover packet (2026-09-07)

Status: release-blocking evidence pack for the subject-scope migration
(`20260906000003_add_workflow_run_subject_scope`) and the narrowed raw-run read
policy. Supersedes the one-off manual probe notes in
`docs/release/course-content-workflow-privacy-cutover.md` (the static contract
test cited there has been replaced by the durable real-execution probe in §6).

## 1. Release order

One release carries BOTH the migration and the raw-run policy switch. There is no
compatibility window that reopens member-wide raw reads.

1. Migration runs first (boot-time `mix ecto.migrate`). Its UUID preflight and
   backfill guards are **abort-only**: any unresolved learning run raises and the
   whole migration transaction rolls back, leaving old data untouched
   (probe-verified, §6). A failed preflight = release blocked; per the privacy
   plan it "does not justify temporarily reopening member-wide raw reads".
2. Policy switch activates in the same release, after the deploy step confirms
   `schema_migrations` contains `20260906000003` and the post-migration
   verification SQL (§2) reports zero unresolved learning runs.
3. Web / MCP / extension readers move to subject-scoped and CourseRevision
   routes in the same release.

## 2. Inventory (read-only)

Captured 2026-09-07 against dev (`cgc_2046_dev`, fully migrated). Production MUST
re-run the same queries before cutover and archive the output.

| Metric | dev count |
|---|---|
| workflow_runs total | 36 |
| learning runs (`workflow_definitions.type = 'learning'`) | 16 |
| learning runs with `subject_user_id IS NULL` | 0 |
| learning runs with `subject_enrollment_id IS NULL` | 0 |
| learning runs whose `input_snapshot.user_id` fails UUID shape | 0 |
| curriculum_outputs rows (`kind = 'issues'`, current draft per key) | 7 |
| materials in current drafts (story + objectives) | 53 |
| — typed `text` / `markdown` / `web` / `image` | 0 / 0 / 0 / 0 |
| — typed `video`, known provider (`bilibili`) | 0 |
| — `video`, unknown provider | 0 |
| — legacy `{title, ref}` | 53 |
| — other / unknown shape | 0 |

Reading: dev learning runs backfilled cleanly (0 unresolved). Draft materials are
100% legacy `{title, ref}` (UAT seed data across 6 draft keys) — content owners
MUST re-save as typed Material before republish; the save path rejects legacy
shapes with `legacy_material_ref` (no compatibility parser by design).

### 2.1 Production SQL — run inventory (pre-migration form)

`subject_*` columns do not exist before the migration; this form counts what the
migration will face, including rows that would abort it:

```sql
SELECT
  count(*) AS total_runs,
  count(*) FILTER (WHERE d.type = 'learning') AS learning_runs,
  count(*) FILTER (WHERE d.type = 'learning' AND r.input_snapshot ? 'user_id'
                     AND (r.input_snapshot->>'user_id') !~* '^[0-9a-f-]{36}$') AS learning_bad_user_id_shape,
  count(*) FILTER (WHERE d.type = 'learning' AND (
                     NOT (r.input_snapshot ? 'user_id')
                     OR (r.input_snapshot->>'user_id') !~* '^[0-9a-f-]{36}$'
                     OR NOT (r.input_snapshot ? 'enrollment_id')
                     OR (r.input_snapshot->>'enrollment_id') !~* '^[0-9a-f-]{36}$'
                   )) AS learning_would_abort
FROM workflow_runs r
LEFT JOIN workflow_definitions d ON d.id = r.definition_id;
```

`learning_would_abort` MUST be 0 before the release proceeds; otherwise follow §3.

### 2.2 Production SQL — post-migration verification

```sql
SELECT
  count(*) FILTER (WHERE d.type = 'learning' AND r.subject_user_id IS NULL) AS learning_subject_user_null,
  count(*) FILTER (WHERE d.type = 'learning' AND r.subject_enrollment_id IS NULL) AS learning_subject_enrollment_null
FROM workflow_runs r
LEFT JOIN workflow_definitions d ON d.id = r.definition_id;

-- Dangling subject enrollment anchors: the backfill guard is non-null-only and
-- subject_enrollment_id carries no FK, so dangling ids pass through verbatim.
-- Register findings via platform audit; this scan is informational, NOT a blocker.
SELECT r.id, r.workspace_id, r.subject_enrollment_id
FROM workflow_runs r
LEFT JOIN enrollments e ON e.id = r.subject_enrollment_id
WHERE r.subject_enrollment_id IS NOT NULL AND e.id IS NULL;
```

### 2.3 Production SQL — draft materials classification

```sql
WITH issue_rows AS (
  SELECT issue
  FROM curriculum_outputs co,
       LATERAL jsonb_array_elements(
         CASE WHEN jsonb_typeof(co.data -> 'issues') = 'array'
              THEN co.data -> 'issues' ELSE '[]'::jsonb END) AS issue
  WHERE co.kind = 'issues'
),
mats AS (
  SELECT m AS material
  FROM issue_rows,
       LATERAL jsonb_array_elements(
         CASE WHEN jsonb_typeof(issue #> '{story,materials}') = 'array'
              THEN issue #> '{story,materials}' ELSE '[]'::jsonb END) AS m
  UNION ALL
  SELECT m AS material
  FROM issue_rows,
       LATERAL jsonb_array_elements(
         CASE WHEN jsonb_typeof(issue -> 'objectives') = 'array'
              THEN issue -> 'objectives' ELSE '[]'::jsonb END) AS obj,
       LATERAL jsonb_array_elements(
         CASE WHEN jsonb_typeof(obj -> 'materials') = 'array'
              THEN obj -> 'materials' ELSE '[]'::jsonb END) AS m
)
SELECT
  count(*) AS total_materials,
  count(*) FILTER (WHERE jsonb_typeof(material) = 'object' AND material->>'kind' = 'text') AS typed_text,
  count(*) FILTER (WHERE jsonb_typeof(material) = 'object' AND material->>'kind' = 'markdown') AS typed_markdown,
  count(*) FILTER (WHERE jsonb_typeof(material) = 'object' AND material->>'kind' = 'web') AS typed_web,
  count(*) FILTER (WHERE jsonb_typeof(material) = 'object' AND material->>'kind' = 'image') AS typed_image,
  count(*) FILTER (WHERE jsonb_typeof(material) = 'object' AND material->>'kind' = 'video'
                     AND material->>'provider' = 'bilibili') AS typed_video_known_provider,
  count(*) FILTER (WHERE jsonb_typeof(material) = 'object' AND material->>'kind' = 'video'
                     AND coalesce(material->>'provider', '') <> 'bilibili') AS video_unknown_provider,
  count(*) FILTER (WHERE jsonb_typeof(material) = 'object' AND material ? 'ref') AS legacy_title_ref,
  count(*) FILTER (WHERE jsonb_typeof(material) <> 'object'
                     OR (NOT material ? 'ref'
                         AND coalesce(material->>'kind', '') NOT IN ('text','markdown','web','image','video'))) AS other
FROM mats;
```

## 3. Runbook — manual reconciliation of unresolved learning runs (abort-only)

This is the operative ruling of the privacy plan's "unresolved rows stay outside
business reads until manually reconciled" clause: **no business-read fallback
exists**. The only path is block → locate → repair or delete → re-run.

1. **Block.** The migration aborts with one of:
   - `learning workflow run subject preflight found invalid UUID` — a snapshot
     field holds a non-UUID-shape value (raised before any write);
   - `learning workflow run subject backfill incomplete` — a learning run has no
     resolvable subject anchors (missing `user_id` key, or no `enrollment_id`).
   The transaction rolls back completely (columns, indexes, schema_migrations row
   all absent — probe-verified, §6). Old data is untouched.
2. **Locate.** DBA runs the diagnostic query (same predicates as the guards):

   ```sql
   SELECT r.id, r.workspace_id, r.inserted_at,
          r.input_snapshot->>'user_id' AS user_id,
          r.input_snapshot->>'enrollment_id' AS enrollment_id,
          r.input_snapshot->>'course_id' AS course_id,
          r.input_snapshot->>'course_revision_id' AS course_revision_id
   FROM workflow_runs r
   JOIN workflow_definitions d ON d.id = r.definition_id
   WHERE d.type = 'learning'
     AND (
       (r.input_snapshot ? 'user_id' AND (r.input_snapshot->>'user_id') !~* '^[0-9a-f-]{36}$') OR
       (r.input_snapshot ? 'enrollment_id' AND (r.input_snapshot->>'enrollment_id') !~* '^[0-9a-f-]{36}$') OR
       (r.input_snapshot ? 'course_id' AND (r.input_snapshot->>'course_id') !~* '^[0-9a-f-]{36}$') OR
       (r.input_snapshot ? 'course_revision_id' AND (r.input_snapshot->>'course_revision_id') !~* '^[0-9a-f-]{36}$') OR
       NOT (r.input_snapshot ? 'user_id') OR
       NOT (r.input_snapshot ? 'enrollment_id')
     )
   ORDER BY r.inserted_at;
   ```
3. **Decide per row** with the workspace owner, using platform audit evidence:
   repair `input_snapshot` (write the correct `user_id` / `enrollment_id` from
   enrollment records) or delete the run (orphaned test/UAT garbage). No silent
   reinterpretation; every touch is recorded in the release log.
4. **Re-run** `mix ecto.migrate`. The aborted migration has no schema_migrations
   row, so it re-executes; `add_if_not_exists` / `create_if_not_exists` and the
   NULL-scoped UPDATE make replay safe (probe-verified, §6).
5. **Verify** with §2.2 (zero unresolved; register dangling anchors).

## 4. AE2 error summary

The platform-admin audit read path exposes `error_summary` as a constant:
`CASE WHEN status = 'failed' THEN 'workflow_failed' ELSE NULL END`
(`Cgc2046.Workflows.PlatformAudit`). Exception text, facts and input snapshots
never leave this path — the constant is the intended AE2 surface, not a
placeholder.

## 5. Rollback

`down` drops the 3 subject indexes and the 4 `subject_*` columns
(`drop_if_exists` / `remove_if_exists` — itself idempotent). Notes:

- Backfilled values are derived data: their sources (`input_snapshot`,
  `enrollments`) are untouched, so re-running `up` re-derives them.
- The narrowed read policy queries `subject_*` columns; rolling back the
  migration REQUIRES rolling back the policy code in the same deploy — a
  bare `down` breaks learning-run reads by contract.

## 6. Failure-atomicity evidence (durable probe)

`backend/test/cgc_2046/workflows/workflow_run_subject_scope_migration_test.exs`
executes the real migration on throwaway databases
(`CREATE DATABASE` → migrate to `20260906000002` → poison rows → run target
migration → assert rollback residue via `information_schema` / `pg_indexes` /
`schema_migrations`):

- 36-char dashless hex `user_id` passes the preflight regex but fails the
  `::uuid` cast mid-transaction → abort, zero residue;
- missing `user_id` key aborts even when a valid enrollment anchor exists
  (no implicit derivation — abort-only);
- dangling `enrollment_id` with no other resolvable anchor aborts;
- happy path backfills (`subject_course_id` via enrollment join), leaves
  non-learning poison rows untouched, records the guard boundary (valid
  `user_id` + dangling `enrollment_id` passes — informational scan in §2.2),
  and replays idempotently after deleting the `schema_migrations` row.
