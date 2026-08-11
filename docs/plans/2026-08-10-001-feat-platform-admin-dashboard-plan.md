---
title: Platform Admin Dashboard - Plan
type: feat
date: 2026-08-10
topic: platform-admin-dashboard
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
---

## Goal Capsule

- **Objective:** Build a full-scope platform admin dashboard for CGC, two layers — AshAdmin for internal ops/debug, Next.js `/admin` for product-level admin UI covering workspace creation (direct + application approval), user management, workspace oversight, audit monitoring, and OpenClacky enterprise entry.
- **Product authority:** This plan owns the platform admin dashboard across both layers. Surrounding areas (custom roles, platform-level global config/quotas, the OpenClacky enterprise deployment itself) are not active scope.
- **Open blockers:** None — scope confirmed with user.

---

## Product Contract

### Summary

A two-layer platform admin dashboard: AshAdmin mounted at `/ops/admin` for developer/ops data CRUD with zero per-resource code, and a full Next.js `/admin/*` surface for platform admins covering workspace lifecycle (creation + application approval), user management, workspace oversight, audit dashboards, and OpenClacky entry redirect.

### Problem Frame

`is_platform_admin` exists as a boolean on User and is wired through RBAC policies, GraphQL, and resource authorization — but there is no admin UI to exercise it. The backend router has no `/admin` route; the GraphQL schema has no admin-level listing queries (`listWorkspaces`, `listUsers`). No `WorkspaceApplication` resource exists for the application-approval flow that CONTEXT.md D-A3 calls for. Platform admins today cannot create workspaces, designate owners, view audit data, or manage users through any interface — the `create_workspace` Ash action exists but is only callable via raw GraphQL mutation.

### Key Decisions

- KD1. **Two-layer architecture: AshAdmin + Next.js /admin** (session-settled: user-approved — chosen over single-layer Next.js-only: AshAdmin gives zero-code CRUD over all 20+ Ash resources for ops/debug, while Next.js handles product-grade multi-step workflows that table-CRUD can't represent). Governs R1, R2.
- KD2. **OpenClacky enterprise on `oc.codingirlsclub.com` subdomain** (session-settled: user-directed — chosen over `admin.` subdomain: semantic clarity, avoids collision with `/admin` path on main site). Governs R11.
- KD3. **`/admin/*` on main site, not a separate subdomain** (session-settled: user-directed — chosen over `admin.codingirlsclub.com`: shares `ash_authentication` httpOnly cookie + RBAC single-source, no cross-domain token sync overhead). Governs R1.
- KD4. **`/admin/openclacky` is a redirect page, not a reverse proxy** (session-settled: user-approved — chosen over reverse-proxying OpenClacky under `/admin/openclacky`: OpenClacky is an independent server with its own auth; proxying into a subpath risks asset/WebSocket breakage for a product we don't control). Governs R11.
- KD5. **Application-approval flow is a new resource, not a Workspace flag** — workspace creation has two paths: direct create by admin, and user-submitted application approved by admin. The application needs its own lifecycle (pending → approved/rejected), distinct from the workspace it may produce. Governs R6, R7.
- KD6. **Full-scope v1, not phased rollout** (session-settled: user-directed — chosen over A→B渐进: user wants complete admin experience in one delivery cycle, accepts longer timeline). Governs R3-R13.

### Actors

- A1. **Platform Admin** — `is_platform_admin == true` user; creates workspaces, designates owners, approves/rejects applications, manages users, monitors audit data. Primary actor for all admin flows.
- A2. **Designated Owner** — the user designated as the first Owner of a new workspace. May be an existing user (direct selection) or a new user (email invitation). Receives Owner role upon workspace creation or invitation acceptance.
- A3. **Regular User (applicant)** — any registered user who submits a "create workspace" application for admin review.

### Requirements

**Access control & bootstrap**

- R1. The `/admin/*` route on the main site is accessible only to users with `is_platform_admin == true`; non-admins are redirected away from every admin route, enforced by both a frontend route guard and a backend policy.
- R2. A CLI task (e.g., `mix cgc2046.promote_admin <email>`) exists to set `is_platform_admin = true` on an existing user, bootstraping the first admin without requiring an admin UI to already exist.

**Workspace creation — direct**

- R3. A platform admin can create a new workspace through the admin UI, specifying workspace metadata (name, slug, join policy) and designating the first Owner.
- R4. When designating an Owner, the admin can select from already-registered users by search (email or display name).
  - **Edge case (review-noted):** Phone-only miniprogram users (null email, potentially null display_name) are not findable by email/display-name search. Planning should add phone as a search dimension or scope R4/R8 to email-having users with a documented gap.
- R5. When designating an Owner, the admin can alternatively enter an email address for a not-yet-registered user; the system sends an invitation, and the designated user becomes Owner upon registration/login acceptance.
- R3a. The `create_workspace` action (or a new `create_with_owner` action) must accept a designated owner (`owner_user_id` for existing users, or `owner_email` for invitations) and create the Owner membership for that user, not the acting admin. The existing action's `after_action` currently hardcodes the actor as Owner — this must be re-parameterized. (Review-verified: `workspace.ex:75-130` accept list has no owner argument; after_action seeds `user_id: actor.id`.)

**Workspace creation — application approval**

- R6. A registered user (A3) can submit a "create workspace" application from outside the admin surface, specifying a proposed workspace name, slug, purpose, and their intended role as Owner.
- R7a. An applicant (A3) can view the status of their own submitted applications (pending, approved, rejected) and see any rejection reason. This mirrors the existing `JoinRequest` pattern where "申请人仅见自己" (applicants see only their own).
- R7. A platform admin can view pending applications in the admin UI and approve or reject each one; approval creates the workspace with the applicant as Owner; rejection records a reason visible to the applicant.

**User management**
- R8. A platform admin can view a paginated list of all users (global, cross-workspace), search by email or display name, and see each user's `is_platform_admin` status and workspace memberships summary.
- R9. A platform admin can promote or demote a user's `is_platform_admin` flag through the admin UI. Demotion is blocked when the target is the last remaining platform admin (system must maintain ≥1 admin). Self-demotion requires an explicit confirmation step, with CLI recovery (R2) documented as the fallback.

**Workspace oversight**

- R13. A platform admin can view a paginated list of all workspaces (global, cross-workspace), search by name or slug, and see each workspace's status, Owner, member count, and creation date; a per-workspace detail view shows members and pending-owner state.

**Audit & monitoring**

- R10. The admin UI provides audit visibility into platform operations, covering: MCP tool call logs (`ToolCallLog`), pending operations (`PendingOperation`), workflow run states (`WorkflowRun`), and signal logs (`SignalLog`). Admins can filter by workspace, time range, and status.
  - **Workspace filter caveat (review-verified):** `ToolCallLog` and `PendingOperation` are global resources with no `workspace_id` column — workspace only exists inside the redacted `params` JSONB map. Workspace-filtering these resources requires either a new `workspace_id` column (plus backfill) or JSONB expression filtering; `WorkflowRun` and `SignalLog` have real `workspace_id` columns and filter normally.
- R10a. Platform admin actions (workspace creation, application approval/rejection, promote/demote `is_platform_admin`) are recorded in an admin-action audit trail capturing actor, action, target, timestamp, and result. This is distinct from operational audit logs (R10) — it covers the admin's own governance actions.

> Note: `AgentRun` is referenced in CONTEXT.md as a concept but does not exist as an Ash resource in the codebase. The audit dashboard surfaces the four resources that do exist.

**OpenClacky enterprise entry**

- R11. The `/admin/openclacky` page is an `is_platform_admin`-guarded redirect entry point that links to `oc.codingirlsclub.com`, with a brief description of what OpenClacky is and that it runs on an independent server with its own authentication.

**Ops/debug layer (AshAdmin)**

- R12. AshAdmin is mounted at `/ops/admin` (distinct path from product-level `/admin`), gated behind `is_platform_admin` authentication, exposing read and action access to all Ash resources for developer/ops inspection and debugging.

### Key Flows

- F1. **Direct workspace creation with existing-user Owner**
  - **Trigger:** Admin clicks "Create Workspace" in `/admin/workspaces`.
  - **Actors:** A1, A2 (existing user).
  - **Steps:** Admin fills workspace metadata → searches and selects an existing user as Owner → confirms → system creates workspace, creates Owner membership + role, assigns workspace slug. Admin and new Owner see confirmation.
  - **Outcome:** Workspace exists with designated Owner ready to manage.
  - **Covers:** R3, R4.

- F2. **Direct workspace creation with new-user Owner (invitation)**
  - **Trigger:** Admin clicks "Create Workspace" and chooses "invite by email."
  - **Actors:** A1, A2 (unregistered).
  - **Exit path (review-added):** If the invitee never registers or accepts, the pending-owner workspace has an expiry timeout (mirroring existing `Invitation` active → expired lifecycle + `ApprovalExpiryWorker`). The admin can cancel the invitation or reassign Owner to a different user. While ownerless, the workspace is not usable by non-admins.
  - **Outcome:** Workspace exists; Owner gains access upon accepting invitation.
  - **Covers:** R3, R5.

- F3. **Application approval flow**
  - **Trigger:** User submits a workspace creation application.
  - **Actors:** A3, A1.
  - **Steps:** User fills application form (name, slug, purpose) → application lands in admin approval queue (pending) → admin reviews, approves or rejects → on approval, system creates workspace with applicant as Owner → applicant notified.
  - **Outcome:** Workspace created from approved application, or application rejected with reason.
  - **Covers:** R6, R7.

### Acceptance Examples

- AE1. **Non-admin cannot access /admin**
  - **Covers R1.**
  - **Given:** a user with `is_platform_admin == false` is logged in.
  - **When:** they navigate to any `/admin/*` path.
  - **Then:** they are redirected to the main site (home or a "not authorized" page), and no admin content is rendered.

- AE2. **Bootstrap first admin via CLI**
  - **Covers R2.**
  - **Given:** no users have `is_platform_admin == true`.
  - **When:** `mix cgc2046.promote_admin alice@example.com` is run.
  - **Then:** the user with that email has `is_platform_admin` set to `true`, and can now access `/admin/*`.

- AE3. **Invite Owner who doesn't have an account yet**
  - **Covers R5.**
  - **Given:** admin is creating a workspace and enters an email not associated with any registered user.
  - **When:** the admin confirms workspace creation.
  - **Then:** the workspace is created in a pending-owner state, an invitation email is sent, and the Owner role is assigned only after the invitee registers and accepts.

- AE4. **Application rejection is visible to applicant**
  - **Covers R7.**
  - **Given:** an admin rejects a workspace creation application with a reason.
  - **When:** the applicant checks their application status.
  - **Then:** they see the rejection and the reason.

- AE5. **AshAdmin is admin-gated**
  - **Covers R12.**
  - **Given:** a user without `is_platform_admin` tries to access `/ops/admin`.
  - **When:** they navigate to `/ops/admin`.
  - **Then:** they are blocked (redirected or 403), same gate as the product-level `/admin`.

### Scope Boundaries

**Deferred for later:**

- Custom roles and per-workspace role configuration (CONTEXT.md marks this as a future capability triggered by real workspace role-differentiation needs).
- Platform-level global settings (feature toggles, quotas, rate limits) — not yet modeled in the domain.
- Product-level audit aggregation dashboards beyond raw resource browsing (charts, trends, export) — AshAdmin covers raw data access; richer analytics are post-v1.

**Outside this product's identity:**

- The OpenClacky enterprise deployment itself (`oc.codingirlsclub.com`) — independent server, independent auth, not managed by this admin dashboard beyond the redirect entry page.
- Workspace-internal admin features (member management, role assignment, join policy editing within a workspace) — these belong to workspace-level admin (`/w/[slug]/settings/`), not platform-level admin.

### Dependencies / Assumptions
- **Assumption (verified, corrected by review):** Audit resources exist as Ash resources BUT are not all admin-readable. `WorkflowRun` and `SignalLog` have platform-admin read policies. `ToolCallLog` has NO read policy (default-deny; moduledoc defers reads to "切片 F 审计页"). `PendingOperation` read is `user_id == actor.id` only (no platform-admin bypass). `User` read is self-only (`ReadOwnUser`). R8, R10, R12 each require net-new read-policy grants (platform-admin bypass clauses) on these resources.
- **Assumption (verified):** `is_platform_admin` boolean on User resource is fully wired through RBAC, policies, and GraphQL — confirmed at `backend/lib/cgc_2046/accounts/user.ex:59-62`, `backend/lib/cgc_2046/rbac.ex:83-85`, across all resource policies.
- **Assumption (verified):** The GraphQL schema currently has NO admin-level listing queries — confirmed at `backend/lib/cgc_2046_web/graphql_schema.ex:13-123`. New queries/mutations must be added for admin UI data access.
- **Assumption (verified):** No `WorkspaceApplication` resource exists — confirmed via grep. This is a net-new resource for R6/R7.
- **Assumption (verified):** `ash_admin` is NOT in dependencies (`backend/mix.exs:56-70`). Must be added for R12.
- **Assumption (verified):** Audit resources exist: `ToolCallLog`, `PendingOperation`, `WorkflowRun`, `SignalLog` are all Ash resources. `AgentRun` does NOT exist as an Ash resource (only a CONTEXT.md concept).
- **Assumption (verified):** Oban workers exist (`backend/lib/cgc_2046/workers/`): `ApprovalExpiryWorker`, `ApprovalReminderWorker`, `NotificationWorker`. Can be leveraged for application-approval notifications and expiry.
- **Assumption:** `ash_admin` is AGPL-3.0-compatible (license compliance gate required per AGENTS.md before adding the dependency).

### Outstanding Questions

**Resolve Before Planning:**

- None — all open questions are deferred to planning.

**Deferred to Planning:**

- OQ1. Where should the workspace creation application form live for regular users (A3)? Options: a standalone `/apply` page, a section in `/settings`, or within the workspace switcher. This is a product IA decision; the form's placement is a UX detail, and the resource + action contract is what planning needs to define.
- OQ2. AshAdmin version compatibility with the project's Ash 3.31 + Phoenix 1.8 + LiveView setup — verify during planning.
- OQ3. Whether the workspace-application approval should integrate with Oban for expiry/reminders (mirroring `JoinRequest` approval patterns) or stay a simpler synchronous flow.
- OQ4. Invitation email delivery for new-user Owner designation — whether to reuse existing `ash_authentication` confirmation flows, build a dedicated workspace-owner invitation mechanism, or reuse the existing `Invitation` resource (which already handles workspace invitations with active/used/revoked/expired lifecycle).
- OQ5. (From review) Who is the audit dashboard consumer and what outcome does it serve? R10 adds filters over resources R12 (AshAdmin) already exposes — state the differentiated value (e.g., non-technical summary view for operators vs. raw data for developers).
- OQ6. (From review) What is the representation of "pending-owner state"? Options: a Workspace status field, a nullable Owner reference, or a separate invitation record. Must reconcile with KD5 ("not a Workspace flag" applies to the application flow, not necessarily the invitation flow).

### Sources / Research

- CONTEXT.md §2 平台管理员 (Platform Admin) — `is_platform_admin` definition, D-A3 workspace creation two-level design.
- `backend/lib/cgc_2046_web/router.ex` — current routes: `/mcp`, `/api/graphql`, `/dev/*` only; no `/admin`.
- `backend/lib/cgc_2046_web/graphql_schema.ex:13-123` — query block enumeration confirms no admin-level queries.
- `backend/lib/cgc_2046/accounts/workspace.ex:285-287,327-328` — `create_workspace` action gated on `is_platform_admin`.
- `backend/lib/cgc_2046/rbac.ex:83-85,157-158` — `create_workspace` ability and `abilities_for` platform-admin path.
- AshAdmin official docs — security model (no built-in RBAC, must gate routes), actor-plug pattern for policy-aware actions, DSL for resource/domain configuration.
- Community research (2025): AshAdmin positioned as "super-admin / dev tool" by maintainers; Backpex/Torch/Kaffy are Ecto-based, not applicable to Ash stack.
