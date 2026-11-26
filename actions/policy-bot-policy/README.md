# policy-bot policy

Renders and checks [policy-bot](https://github.com/palantir/policy-bot)
`.policy.yml` files for the "two accountable humans per change" approval gate.

## The policy

Every rendered file has the same common part. Approvals come only from GitHub
reviews by members of the `ethereum-optimism/engineering` team (child teams
included), comment approvals are disabled, and a push invalidates earlier
approvals. The pull request author never counts. A reviewer is also excluded
when GitHub links them as the author or committer of a commit on the pull
request. Commits whose author or committer identity is not linked to a GitHub
account are invisible to that exclusion, so gated repositories should require
signed commits.

| Rule | Applies when | Approvals |
| --- | --- | --- |
| `human change` | the pull request was opened by an engineering member | 1 |
| one rule per automation lane | opened by that App from its branch prefix, no commit linked to any other account, every commit validly signed by the lane's signer, only files with the listed names changed | 1 |
| `no accountable human author` | always (agents, bots, machine users, outside contributors, unknown accounts, automation outside its lane) | 2 |

The policy is the `or` of these rules. The last rule has no condition, so the
policy can never be skipped.

## Values file

A repository supplies only its automation lanes:

```yaml
automation:
  - name: renovate dependency update
    description: Opened by renovate from a renovate branch, dependency manifests only. One listed human approves.
    app: renovate[bot]
    signer: web-flow
    branch_prefix: renovate
    files:
      - go.mod
      - go.sum
```

`app` must be a GitHub App login. `signer`, `branch_prefix` and at least one
entry in `files` are required. `branch_prefix` and each entry of `files` are
plain names made of letters, digits, `_`, `-` and `.`; patterns, slashes and
names made only of dots are rejected. The renderer escapes the dots and builds
the patterns: `branch_prefix: renovate` becomes `^renovate/`, and `go.mod`
becomes `(^|/)go\.mod$`, which matches a file with exactly that name in any
directory. As a second layer, no rendered pattern may match any of these probe
paths: the empty string, `a`, `src/main.go`, `.github/workflows/x.yml`,
`Dockerfile`, `.policy.yml`, `.github/policy-bot-values.yml`, `x/../y`; nor
the branches `main`, `feature/x` or the empty string. `automation: []` renders
the common part only.

## Requirements for a gated repository

- Code ownership: `.policy.yml`, `.github/policy-bot-values.yml` and the
  workflow that calls the check are owned by `@ethereum-optimism/cloud-security`
  in CODEOWNERS, and a ruleset on the default branch requires code owner review.
- Lane branches: a ruleset restricts creation and update of each lane's branch
  prefix (for example `renovate/**`) to that lane's App. The lane condition
  only sees commits linked to GitHub accounts, so without this restriction an
  unlinked commit pushed onto a lane branch would ride on the lane's single
  approval.
- Signed commits: a ruleset requires signed commits on the default branch.

## Usage

```sh
go run . render -values values.yml -out .policy.yml
go run . check -policy .policy.yml -values values.yml
```

`check` parses the file with the policy package of policy-bot v1.42.1 (the
same code the server uses), rejects `remote:` references, and fails if any
rule allows author, contributor or comment approvals, disables
`invalidate_on_push`, enables `ignore_update_merges` or `ignore_commits_by`,
accepts approvers other than the engineering team, lacks the unconditional
two-approval rule, or gives one approval to anything other than the human
author rule or a lane with one App, one signer, a branch pattern of exactly
the form `^<prefix>/` and paths of exactly the form `(^|/)<file name>$` (the
shapes the renderer produces), all of which pass the probe checks above. With `-values`, the
file must also be byte-equal to the rendering.

From a workflow, call the reusable workflow
`.github/workflows/policy-bot-policy.yaml` (see the repository README), or use
this action directly after checking out the repository:

```yaml
- uses: ethereum-optimism/factory/actions/policy-bot-policy@<sha>
  with:
    policy: .policy.yml
    values: .github/policy-bot-values.yml
```

## Tests

```sh
go test ./...
go test ./... -run TestRenderGolden -update
```

`testdata/<case>/values.yml` renders to `testdata/<case>/policy.yml`.
`scenario_test.go` evaluates a rendering with policy-bot's evaluator against
simulated pull requests. Pass `-scenario-values <file>` to run the scenarios
against another values file with at least one lane.
