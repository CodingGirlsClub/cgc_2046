# Course content / WorkflowRun privacy cutover packet

状态：实现验证包（2026-09-07）

## 变更边界

本次变更把 Workspace raw WorkflowRun feed 替换为本人学习读取、Tutor/Owner/Admin 聚合投影和 Platform Admin 脱敏审计；课程内容以不可变 CourseRevision 提供 Web/MCP/扩展读取；新材料使用 typed Material；公开扩展不再分发 `issue-video` 方法论，视频执行物料位于 `agents/cgc-tutor/video/`。

## 已运行验证

| 门禁 | 结果 | 证据 |
|---|---|---|
| Backend targeted + `mix precommit` | PASS | 1877 tests passed |
| Backend license gate | PASS | 93 dependencies |
| Web i18n/typecheck/test | PASS | 1697 message keys; 112 files / 895 tests |
| OpenClacky Ruby suite | PASS | 323 runs / 2357 assertions |
| Panel behavior harness | PASS | learner boot; typed material round-trip; empty-row deletion |
| `openclacky ext verify` | PASS | CGC local extension entries valid |
| Clean test DB migration | PASS | `ecto.drop/create/migrate` completed |
| Agent browser | PASS | Learner, Tutor, Owner, Admin, Platform Admin paths exercised on dev |

happy-dom external iframe abort and ExUnit signal-bus shutdown logs are test-environment noise; they do not change the assertion result.

## Actor matrix

- Anonymous: public `courseMap` remains goal-only; `courseContent` and Platform Audit are unauthorized.
- Learner: confirmed course reader exposes bound content and mastery projection; Workspace governance route is inaccessible.
- Tutor: assigned UAT course curriculum route renders course governance and content preview.
- Owner/Admin: UAT course list exposes governance link and curriculum route.
- Platform Admin: `/admin/audit` renders redacted audit rows and Workspace/status/time controls; facts and input snapshots are absent from the GraphQL shape.
- Cross Workspace / cross actor: backend policy and GraphQL negative tests remain the authority; browser smoke does not replace those tests.

## Migration and inventory

Clean database migration completed successfully. Current development inventory at the time of capture:

- curriculum outputs: 7
- workflow runs: 2
- learning runs missing `subject_user_id` or `subject_enrollment_id`: 0

The migration contains a UUID preflight and unresolved-subject sentinel. A static migration contract test verifies those guards. Poisoned-row rollback probe was executed on the isolated test database: an invalid UUID learning run caused migration failure with `learning workflow run subject preflight found invalid UUID`; afterward `subject_*` columns=0, subject indexes=0, poisoned rows=1. The test database was then rebuilt from zero. Durable inventory of legacy material identifiers remains required before release.

## Cutover steps

1. Run the material/run inventory against the deployment database and archive counts plus unresolved identifiers.
2. Stop the release if any learning run has invalid UUIDs, missing subject/enrollment binding, or unresolved course anchors.
3. Run the subject-scope migration before enabling the narrowed raw-run policy.
4. Verify the migration version and subject indexes; verify no unresolved learning runs remain.
5. Deploy backend and Web together with the generated GraphQL schema artifacts.
6. Verify Platform Audit redaction, Learner reader, staff governance route, and external video fallback.
7. Require content owners to re-save legacy `{title, ref}` drafts as typed Material before republishing. Do not rewrite immutable revisions in place.
8. Verify private Tutor playbook deployment/hash detection before enabling the video workflow.

## Release blockers still open

- Durable inventory of legacy material identifiers and production database confirmation.
- Deploy change detection for external private Tutor playbook changes (tracked by Issue #432).
- Connected OpenClacky runtime/package install evidence and private playbook round-trip evidence.
- Final independent code review and Mainline seal/PR/CI.
