# Agent approval check

Require distinct, write-capable human approvals before an agent-authored pull
request can merge. Human-only pull requests receive a successful status without
changing the repository's normal review policy.

The action has no third-party runtime dependencies. It uses Python's standard
library and the GitHub API. Consumers must pin `factory` to a reviewed full
commit SHA.

## Workflow

Both triggers execute the workflow from the trusted base branch. Do not check
out or execute pull-request code in this workflow.

```yaml
name: agent-approval-check

on:
  pull_request_target:
    types: [opened, synchronize, reopened, ready_for_review]
  issue_comment:
    types: [created]

concurrency:
  group: agent-approval-${{ github.event.pull_request.number || github.event.issue.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write
  statuses: write

jobs:
  check:
    if: github.event_name != 'issue_comment' || github.event.issue.pull_request
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - uses: ethereum-optimism/factory/actions/agent-approval-check@<full-commit-sha>
        with:
          required_approvals: 2
          agent_emails: noreply@anthropic.com
          agent_logins: claude[bot],claude-code[bot]
          excluded_approvers: OptimismBot
          protected_bases: main
```

Make the exact `agent-approval-check` commit status required on every protected
base branch. Land and exercise the workflow before making the status required,
otherwise existing pull requests may be blocked without a status.

## Approval behavior

An agent-authored pull request is detected when any of these conditions holds:

- The pull-request author matches `agent_logins`.
- A commit author or committer email matches `agent_emails`.
- An agent identity submits an approving review.
- The pull request has more than 100 commits and cannot be fully inspected.

An approval counts only when the user currently has write, maintain, or admin
access and is neither a GitHub Bot nor listed in `agent_logins` or
`excluded_approvers`. A human can approve with a native approving review or a
comment whose first line is exactly `/approve <current-head-sha>`. SHA prefixes
must contain at least 12 hexadecimal characters.

Native reviews do not trigger this workflow because `pull_request_review` does
not provide the same trusted base-workflow semantics. After a native approval,
post `/approve <current-head-sha>` or another pull-request comment to reevaluate
immediately. Duplicate approval mechanisms from one login still count once.

Every evaluation first posts a pending status on the current head SHA. Errors
thereafter leave that required status non-successful. A new head SHA invalidates
all earlier `/approve` comments. Native approving reviews only count when the
review's `commit_id` equals the current head SHA; an approval left on an older
commit is treated as stale and does not count. Configuring branch protection to
dismiss stale reviews on push is still recommended as defense in depth.

The action refuses to publish success when another open pull request to a
protected base shares the same head SHA. GitHub commit statuses are SHA-scoped,
so this prevents approval evidence from one pull request unblocking another.

## Known limitations

- The required status is published with the workflow's `github.token`. GitHub
  commit statuses are keyed only by context string, not by the identity that set
  them, so any other workflow in the same repository holding `statuses: write`
  could publish a `agent-approval-check` success. This is not reachable from a
  pull request (`pull_request_target` runs the base branch's workflow, and adding
  a new workflow must itself pass this gate and review), so it requires an
  already-trusted pusher. Closing it at the platform level needs a dedicated
  GitHub App publishing check runs via the Checks API plus an app-scoped required
  check; that is a deliberate follow-up, not implemented here.
- An agent approving review submitted after a human-only pull request already
  received a `No agent activity` success does not re-evaluate, because the
  `pull_request_review` event is intentionally not used (it lacks the trusted
  base-workflow semantics). Push a commit or comment to force re-evaluation.
- Only `issue_comment.created` re-runs the gate. Editing or deleting a counted
  `/approve` comment does not re-run it; the next push or comment re-evaluates
  and `/approve` comments are already invalidated by any new head SHA.

## Required repository controls

- Protect the workflow with CODEOWNERS and required review.
- Dismiss stale reviews after pushes.
- Require approval of the latest reviewable push where available.
- Do not give agent identities ruleset or branch-protection bypass rights.
- Keep the workflow token limited to the permissions shown above.
- Keep the per-pull-request concurrency group and `cancel-in-progress` enabled.
