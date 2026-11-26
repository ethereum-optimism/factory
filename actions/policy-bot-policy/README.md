# policy-bot policy

Renders and checks [policy-bot](https://github.com/palantir/policy-bot)
`.policy.yml` files for the "two accountable humans per change" approval gate.

## The policy

Every rendered file has the same common part. Approvals come only from GitHub
reviews by members of the `ethereum-optimism/engineering` team (child teams
included). The pull request author and every commit author or committer on the
pull request never count, comment approvals are disabled, and a push
invalidates earlier approvals.

| Rule | Applies when | Approvals |
| --- | --- | --- |
| `human change` | the pull request was opened by an engineering member | 1 |
| one rule per automation lane | opened by that App, every commit linked only to that App, optional signer and branch conditions, only the listed paths changed | 1 |
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
    branch: '^renovate/'
    paths:
      - '(^|/)go\.(mod|sum)$'
    exclude_paths: []
```

`app` must be a GitHub App login. `branch` must start with `^`. Each entry of
`paths` must contain `^` and end with `$`. `signer`, `branch` and
`exclude_paths` are optional. `automation: []` renders the common part only.

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
author rule or a lane scoped to one App and a path list. With `-values`, the
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
