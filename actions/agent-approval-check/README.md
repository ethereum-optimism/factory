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
all earlier `/approve` comments. Native review staleness remains controlled by
the repository's branch protection, so consumers must dismiss stale approvals
when new commits are pushed.

The action refuses to publish success when another open pull request to a
protected base shares the same head SHA. GitHub commit statuses are SHA-scoped,
so this prevents approval evidence from one pull request unblocking another.

## Required repository controls

- Protect the workflow with CODEOWNERS and required review.
- Dismiss stale reviews after pushes.
- Require approval of the latest reviewable push where available.
- Do not give agent identities ruleset or branch-protection bypass rights.
- Keep the workflow token limited to the permissions shown above.
- Keep the per-pull-request concurrency group and `cancel-in-progress` enabled.
