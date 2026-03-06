# Merge Conflict Resolution Strategy

## The Problem

The deploy tool merges multiple feature PRs into the deploy branch sequentially. Each merge changes the deploy branch, which means later PRs can conflict with changes introduced by earlier merges. Currently, when the `merge_prs` step detects a conflict via GitHub's `mergeable` field, it halts the entire deployment with `{:error, {:merge_conflict, pr_number}}`.

This is disruptive: a single conflicting PR blocks all other PRs from being deployed. The operator must manually resolve the conflict outside the tool and restart the deployment from scratch.

### Current Conflict Detection

In `lib/reactors/steps/merge_prs.ex`, PRs are merged sequentially via `Enum.reduce_while`. Before each merge:

1. `update_branch/4` — syncs the PR branch with the deploy branch (GitHub's async `PUT /pulls/{number}/update-branch`)
2. `poll_until_mergeable/5` — polls until GitHub finishes computing merge status
3. `check_mergeable/5` — reads the `mergeable` field from `GET /pulls/{number}`

If `mergeable` is `false`, the step returns `{:error, {:merge_conflict, pr_number}}`. This triggers Reactor's compensation chain: PR bases are reverted to `staging`, but any already-merged PRs cannot be undone (merges are a point of no return).

---

## Proposed Approach: LLM-Assisted Resolution with Human Approval

Use Claude's API to propose conflict resolutions, then present them to the operator for approval before applying. The operator always has the final say — no code is force-pushed without human confirmation.

### Why LLM-Based

Git's built-in merge strategies (`ort`, `recursive`) already handle trivially resolvable conflicts. Any conflict that reaches our code is one that git couldn't resolve — it requires understanding the *intent* of both changes. Deterministic code can't do this (outside of narrow cases like lockfile regeneration). An LLM can read the context, understand what both sides were trying to do, and propose a sensible resolution.

However, LLM resolutions are non-deterministic and can be subtly wrong. That's why every proposed resolution requires human approval before applying.

---

## Architecture

### Wrapper Reactor with Compensation-Based Retry

The architecture leverages Reactor's `:retry` return from `compensate/4`. When a step fails and its compensation returns `:retry`, Reactor re-runs the step's `run/3`, respecting `max_retries`.

```
FullDeploy
  ├── compose :setup, Deploy.Reactors.Setup
  ├── compose :merge_phase, Deploy.Reactors.MergeWithResolution    ← replaces compose :merge_prs
  │     └── step :attempt_merge, Deploy.Reactors.Steps.AttemptMerge
  │           run/3:  Calls Reactor.run(MergePRs, filtered_inputs)
  │           compensate/4:
  │             On {:merge_conflict, pr_number}:
  │               1. Call Deploy.ConflictResolver.resolve(...)
  │               2. If resolved + approved → return :retry
  │               3. If user chose "skip PR" → filter PR, return :retry
  │               4. If unresolvable/rejected → return :ok (error propagates)
  │             On other errors: return :ok (error propagates)
  │           max_retries: 5
  └── compose :deploy_pr, Deploy.Reactors.DeployPR
```

**Why a wrapper reactor instead of modifying the merge_prs step directly:**

- `compose` steps in Reactor do not support custom `compensate/4` callbacks — only `undo` via `support_undo?`. So we can't add compensation at the `FullDeploy` level for the composed `MergePRs` reactor.
- Instead, we create `Deploy.Reactors.MergeWithResolution` containing a regular step (`AttemptMerge`) that wraps `Reactor.run(MergePRs, ...)`. This step *can* have custom compensation.
- The `MergePRs` sub-reactor stays untouched — it detects conflicts and errors exactly as today.
- Conflict resolution logic lives in a separate `Deploy.ConflictResolver` module, keeping each component focused.

### Reactor Compensation/Retry Semantics

Key facts from the Reactor library source (`deps/reactor/`):

| Callback | Called When | Can Return |
|----------|------------|------------|
| `compensate/4` | The step itself fails | `:ok`, `{:continue, value}`, `:retry`, `{:retry, reason}`, `{:error, reason}` |
| `undo/4` | A *later* step fails, this step needs rollback | `:ok`, `{:error, reason}` |

- `:retry` from `compensate/4` re-runs the step's `run/3`, respecting `max_retries`
- `{:continue, value}` provides an alternative result (step treated as successful)
- Reactor's executor timeout defaults to `:infinity` (`deps/reactor/lib/reactor/executor/state.ex:17`)

### Idempotency on Retry

When `AttemptMerge` retries, the `MergePRs` sub-reactor runs again from scratch. But some PRs are already merged (now closed on GitHub). The wrapper step handles this:

- On first run: passes all selected PR numbers to `MergePRs`
- Before each retry: queries GitHub to filter out PRs that are already merged
- Tracks accumulated merge results across retry attempts to return the full list at the end

---

## Conflict Resolution Flow

### Deploy.ConflictResolver

A new module responsible for the git operations and LLM interaction. The workspace (local clone) already exists from the setup phase.

```
resolve(workspace, deploy_branch, pr_number, pr_head_ref, pr_context)
  │
  ├── 1. git fetch origin pull/{number}/head:pr-{number}
  ├── 2. git checkout pr-{number}
  ├── 3. git rebase {deploy_branch}
  │     │
  │     ├── Success (no conflicts) → return :ok
  │     │
  │     └── Conflict at commit N:
  │           ├── 4a. List conflicted files: git diff --name-only --diff-filter=U
  │           ├── 4b. Check bailout conditions (see below)
  │           ├── 4c. For each conflicted file:
  │           │     ├── Read conflicted content (with <<<<<<< markers)
  │           │     ├── Read ours: git show :2:{file}
  │           │     └── Read theirs: git show :3:{file}
  │           ├── 4d. Send to Claude API with full context
  │           ├── 4e. Broadcast proposal to UI for human approval
  │           ├── 4f. Block on receive (wait for human decision)
  │           │     │
  │           │     ├── "Approve" → write resolved files, git add, git rebase --continue
  │           │     ├── "I resolved it manually" → git rebase --abort, poll mergeable
  │           │     └── "Skip this PR" → git rebase --abort, return {:skip, pr_number}
  │           │
  │           └── (repeat for each conflicting commit in the rebase)
  │
  ├── 5. git push origin pr-{number}:{head_ref} --force-with-lease
  └── 6. Return :ok
```

### Bailout Conditions

The ConflictResolver should skip the LLM and go straight to human notification when:

- **More than N files conflicting** (configurable threshold, e.g., 5) — too much surface area for reliable LLM resolution
- **Binary files** — LLMs can't resolve binary conflicts
- **Generated/lockfiles** — these should be regenerated by running the package manager, not LLM-resolved (future enhancement: detect and auto-regenerate)

When bailing out, the UI still presents the conflict details but without a proposed resolution. The operator can choose "I resolved it manually" or "Skip this PR."

---

## Human-in-the-Loop Approval

Every LLM-proposed resolution requires human approval before applying. No code is force-pushed without explicit confirmation.

### PubSub Flow

```
ConflictResolver process                    LiveView process
         │                                        │
         ├─ Subscribe to                          ├─ Already subscribed to
         │  "deployment:{id}:conflicts"           │  "deployment:{id}" (main topic)
         │                                        │
         ├─ Broadcast to "deployment:{id}":       │
         │  {:conflict_proposed, conflict_id,     │
         │   %{pr_number, files, ours, theirs,    │
         │     proposed_resolution}}              │
         │                                        ├─ Receives event, renders approval UI
         │                                        │
         │  ┌─ receive (blocks, :infinity) ──────►│  User reviews diff, clicks action
         │  │                                     │
         │  │                                     ├─ Broadcast to "deployment:{id}:conflicts":
         │  │                                     │  {:conflict_decision, conflict_id, :approve}
         │  │                                     │  or {:conflict_decision, conflict_id, :manual}
         │  │◄────────────────────────────────────│  or {:conflict_decision, conflict_id, :skip}
         │  └─ Receives decision                  │
         │                                        │
         ├─ Acts on decision                      │
         │                                        │
```

### UI Approval View

The LiveView renders:

- **PR context**: PR number, title, author
- **Per-file diff**: the ours (deploy branch) version, theirs (PR branch) version, and the LLM's proposed resolution
- **Three action buttons**:
  - **"Approve resolution"** — apply the LLM's proposal, force-push the rebased branch, retry the merge
  - **"I resolved it manually"** — the operator fixed the conflict themselves (on GitHub or locally). The system aborts the local rebase, polls GitHub's `mergeable` field to verify the PR is now clean, then retries the merge
  - **"Skip this PR"** — exclude this PR from the current deployment, continue merging the remaining PRs

### No Timeout Concerns

- **Reactor executor**: timeout defaults to `:infinity`. Our reactors don't set a custom timeout.
- **BEAM process**: `receive` with `:infinity` is zero-cost. The process sleeps until a message arrives.
- **Sync step execution**: the step blocks the executor loop, which is intentional — the deployment is paused at a natural intervention point.

### LiveView Session Durability

The operator may take hours to respond. To survive browser refreshes and reconnects:

- Store pending conflict resolution state durably (deployment GenServer or ETS) so it persists across LiveView reconnects
- On LiveView mount/reconnect, check for pending conflict approvals and re-render the approval UI
- Provide a "Cancel deployment" action that sends a cancellation message to unblock the `receive` and abort the deployment

---

## LLM Prompt Design

The prompt sent to Claude's API should include:

```
You are resolving a git merge conflict during a deployment.

## Context
PR #{number}: #{title}
PR Description: #{description}

This PR's branch is being rebased onto the deploy branch. The following
file has a conflict.

## File: #{file_path}

### Deploy branch version (ours):
#{ours_content}

### PR branch version (theirs):
#{theirs_content}

### Conflicted file with markers:
#{conflicted_content}

## Instructions

Resolve this conflict by producing the correct merged file content.
Preserve the intent of both changes where possible. If the changes are
genuinely incompatible and you cannot determine the correct resolution,
respond with exactly: UNRESOLVABLE

Return only the resolved file content, with no explanation or markdown
formatting.
```

### Considerations

- **One file at a time**: send each conflicted file individually to keep context focused
- **Language detection**: infer from file extension to help the LLM understand syntax
- **Token limits**: for very large files, consider sending only the conflicted region with surrounding context
- **Validation**: after receiving the resolution, check that it contains no conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)

---

## Trade-Offs and Risks

### Benefits

- **Handles semantic conflicts**: the LLM can understand what both sides intended, which deterministic approaches cannot
- **Reduces manual work**: the operator reviews a proposed resolution instead of resolving from scratch
- **Preserves deployment flow**: conflicts don't block the entire deployment — they're handled in-line
- **Human-gated safety**: no code is applied without explicit approval

### Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| LLM proposes subtly incorrect resolution | Human reviews every proposal. Diff view shows ours/theirs/proposed side by side. |
| Non-determinism — same conflict resolved differently each time | Acceptable since human approves. Operator can reject and re-request if unhappy. |
| API cost and latency | Conflicts are infrequent. Cost per resolution is minimal (single API call per file). Latency is acceptable since human review takes longer than the API call. |
| Force-pushing PR branches | Use `--force-with-lease` to avoid overwriting concurrent changes. The PR author should be aware their branch will be rebased. |
| LLM API unavailable | Fall back to "bailout" mode — present the conflict without a proposal. Operator can still resolve manually or skip. |
| Large conflicted files exceed token limits | Send only the conflicted region with surrounding context, or bail out for very large files. |
| Multiple conflicting commits in a single PR | Handle each commit's conflicts sequentially during the rebase. If any commit is unresolvable, abort the entire rebase for that PR. |

### Testing Challenges

- **ConflictResolver** can be tested with Mox (git operations) and Req.Test plugs (Claude API calls)
- **Human approval flow** needs integration testing with PubSub — send a decision message and verify the ConflictResolver proceeds correctly
- **End-to-end** tests are harder — would need real merge conflicts in a test repo, or carefully crafted git state in the workspace

---

## Open Questions

1. **Claude API client library**: Use an existing Elixir library (e.g., `anthropic_sdk`), or call the API directly via `Req` (consistent with our GitHub API pattern)?

2. **Diff rendering in LiveView**: What component/library to use for displaying side-by-side or unified diffs? Options include a simple `<pre>` with syntax highlighting, or a JS diff viewer like Monaco's diff editor.

3. **Multiple conflicts per rebase**: When a rebase hits conflicts across multiple commits, should we present all of them at once or one commit at a time? One at a time is simpler and matches git's rebase flow, but may require multiple rounds of approval.

4. **PR author notification**: Should we notify the PR author (via GitHub comment or Slack) when their branch is being force-pushed with a resolved conflict?

5. **Lockfile handling**: Should we detect lockfile conflicts and auto-regenerate them (run `mix deps.get`, `npm install`, etc.) instead of sending to the LLM? This would be a future deterministic enhancement.

6. **Conflict frequency**: How often do conflicts actually occur in practice? If rare, the investment in LLM resolution may not pay off immediately — but having the human-in-the-loop escape hatches (manual resolve, skip) is valuable regardless.

---

## Summary

The recommended approach uses a **wrapper reactor** (`MergeWithResolution`) that leverages Reactor's `compensate/4` → `:retry` semantics. When a merge conflict is detected, the `ConflictResolver` module handles the local git operations and Claude API interaction, then presents the proposed resolution to the operator via the LiveView UI. The operator approves, resolves manually, or skips the PR. No code is applied without human confirmation.

This design:
- Keeps the existing `MergePRs` sub-reactor untouched
- Leverages Reactor's built-in compensation and retry mechanisms
- Isolates conflict resolution logic in a dedicated module
- Gates all code changes behind human approval
- Handles edge cases (bailout conditions, session durability, idempotency on retry)
