package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/palantir/policy-bot/policy"
	"github.com/palantir/policy-bot/policy/common"
	"github.com/palantir/policy-bot/pull"
	"github.com/palantir/policy-bot/pull/pulltest"
	"gopkg.in/yaml.v2"
)

var scenarioValues = flag.String("scenario-values", "testdata/renovate-lane/values.yml", "values file whose rendering the scenarios run against")

var t0 = time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)

func at(minutes int) time.Time { return t0.Add(time.Duration(minutes) * time.Minute) }

const (
	alice    = "alice"
	bob      = "bob"
	carol    = "carol"
	outsider = "outsider"
	agent    = "agent[bot]"
)

type prSpec struct {
	author   string
	branch   string
	files    []string
	commits  []*pull.Commit
	pushedAt map[string]time.Time
	reviews  []*pull.Review
	comments []*pull.Comment
}

func commit(sha, parent, author, committer string, sig *pull.Signature) *pull.Commit {
	c := &pull.Commit{SHA: sha, Author: author, Committer: committer, Signature: sig}
	if parent != "" {
		c.Parents = []string{parent}
	}
	return c
}

func approve(user string, minute int) *pull.Review {
	return &pull.Review{ID: fmt.Sprintf("%s-%d", user, minute), Author: user, State: pull.ReviewApproved, CreatedAt: at(minute)}
}

var webFlow = &pull.Signature{Type: pull.SignatureGpg, IsValid: true, Signer: "web-flow", State: "VALID"}

func (s prSpec) context() *pulltest.Context {
	team := []string{ApproverTeam}
	var files []*pull.File
	for _, f := range s.files {
		files = append(files, &pull.File{Filename: f, Status: pull.FileModified})
	}
	head := ""
	if len(s.commits) > 0 {
		head = s.commits[len(s.commits)-1].SHA
	}
	return &pulltest.Context{
		OwnerValue:        "ethereum-optimism",
		RepoValue:         "example",
		AuthorValue:       s.author,
		BranchBaseName:    "main",
		BranchHeadName:    s.branch,
		HeadSHAValue:      head,
		ChangedFilesValue: files,
		CommitsValue:      s.commits,
		PushedAtValue:     s.pushedAt,
		ReviewsValue:      s.reviews,
		CommentsValue:     s.comments,
		TeamMemberships: map[string][]string{
			alice: team,
			bob:   team,
			carol: team,
		},
	}
}

func loadScenarioPolicy(t *testing.T) (common.Evaluator, string) {
	t.Helper()
	data, err := os.ReadFile(*scenarioValues)
	if err != nil {
		t.Fatal(err)
	}
	v, err := ParseValues(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(v.Automation) == 0 {
		t.Fatalf("%s has no automation lane", *scenarioValues)
	}
	rendered, err := Render(v)
	if err != nil {
		t.Fatal(err)
	}
	var cfg policy.Config
	if err := yaml.UnmarshalStrict(rendered, &cfg); err != nil {
		t.Fatal(err)
	}
	eval, err := policy.ParsePolicy(&cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	return eval, v.Automation[0].App
}

func deciding(res common.Result) string {
	var names []string
	var walk func(r *common.Result)
	walk = func(r *common.Result) {
		if len(r.Children) == 0 && r.Name != "" {
			names = append(names, fmt.Sprintf("%s=%s", r.Name, r.Status))
			return
		}
		for _, c := range r.Children {
			walk(c)
		}
	}
	walk(&res)
	return strings.Join(names, ", ")
}

func TestScenarios(t *testing.T) {
	eval, app := loadScenarioPolicy(t)

	lane := func(extraCommits []*pull.Commit, files []string, reviews ...*pull.Review) prSpec {
		commits := append([]*pull.Commit{commit("r1", "", app, "", webFlow)}, extraCommits...)
		pushed := map[string]time.Time{"r1": at(0)}
		for i, c := range extraCommits {
			pushed[c.SHA] = at(1 + i)
		}
		return prSpec{author: app, branch: "renovate/dep", files: files, commits: commits, pushedAt: pushed, reviews: reviews}
	}
	human := func(reviews ...*pull.Review) prSpec {
		return prSpec{
			author: alice, branch: "alice/feature", files: []string{"service/main.go"},
			commits:  []*pull.Commit{commit("h1", "", alice, alice, nil)},
			pushedAt: map[string]time.Time{"h1": at(0)},
			reviews:  reviews,
		}
	}
	agentPR := func(author string, reviews ...*pull.Review) prSpec {
		return prSpec{
			author: author, branch: "agent/change", files: []string{"service/main.go"},
			commits:  []*pull.Commit{commit("a1", "", author, author, nil)},
			pushedAt: map[string]time.Time{"a1": at(0)},
			reviews:  reviews,
		}
	}

	cases := []struct {
		name string
		pr   prSpec
		want common.EvaluationStatus
	}{
		{"human author, one engineering approval", human(approve(bob, 10)), common.StatusApproved},
		{"human author, self approval only", human(approve(alice, 10)), common.StatusPending},
		{"human author, thumbs up comment only", func() prSpec {
			p := human()
			p.comments = []*pull.Comment{{Author: bob, Body: ":+1:", CreatedAt: at(10)}}
			return p
		}(), common.StatusPending},
		{"human author, approval from non engineering account", human(approve(outsider, 10)), common.StatusPending},
		{"human author, approver has a commit on the pull request", func() prSpec {
			p := human(approve(bob, 10))
			p.commits = append(p.commits, commit("h2", "h1", bob, bob, nil))
			p.pushedAt["h2"] = at(5)
			return p
		}(), common.StatusPending},
		{"human author, approver clicked update branch", func() prSpec {
			p := human(approve(bob, 10))
			merge := commit("h2", "h1", bob, "", webFlow)
			merge.Parents = []string{"h1", "base"}
			merge.CommittedViaWeb = true
			p.commits = append(p.commits, merge)
			p.pushedAt["h2"] = at(5)
			return p
		}(), common.StatusPending},
		{"human author, push after approval", func() prSpec {
			p := human(approve(bob, 10))
			p.commits = append(p.commits, commit("h2", "h1", alice, alice, nil))
			p.pushedAt["h2"] = at(20)
			return p
		}(), common.StatusPending},
		{"human author, push after approval then re-approval", func() prSpec {
			p := human(approve(bob, 10), approve(bob, 30))
			p.commits = append(p.commits, commit("h2", "h1", alice, alice, nil))
			p.pushedAt["h2"] = at(20)
			return p
		}(), common.StatusApproved},
		{"agent opened, one approval", agentPR(agent, approve(alice, 10)), common.StatusPending},
		{"agent opened, two approvals", agentPR(agent, approve(alice, 10), approve(bob, 11)), common.StatusApproved},
		{"agent opened, agent approval does not count", agentPR(agent, approve(alice, 10), approve(agent, 11)), common.StatusPending},
		{"automation lane, own files, one approval", lane(nil, []string{"svc/go.mod", "svc/go.sum"}, approve(bob, 10)), common.StatusApproved},
		{"automation lane, other files, one approval", lane(nil, []string{"svc/go.mod", ".github/workflows/ci.yaml"}, approve(bob, 10)), common.StatusPending},
		{"automation lane, other files, two approvals", lane(nil, []string{"svc/go.mod", ".github/workflows/ci.yaml"}, approve(bob, 10), approve(carol, 11)), common.StatusApproved},
		{"automation lane, human commit pushed onto branch, one approval", lane([]*pull.Commit{commit("r2", "r1", alice, alice, nil)}, []string{"svc/go.mod"}, approve(bob, 10)), common.StatusPending},
		{"automation lane, unsigned commit, one approval", func() prSpec {
			p := lane(nil, []string{"svc/go.mod"}, approve(bob, 10))
			p.commits[0].Signature = nil
			return p
		}(), common.StatusPending},
		{"automation lane, wrong branch, one approval", func() prSpec {
			p := lane(nil, []string{"svc/go.mod"}, approve(bob, 10))
			p.branch = "feature/x"
			return p
		}(), common.StatusPending},
		{"fork by outsider, one approval", agentPR(outsider, approve(alice, 10)), common.StatusPending},
		{"fork by outsider, two approvals", agentPR(outsider, approve(alice, 10), approve(bob, 11)), common.StatusApproved},
		{"no approvals at all", agentPR(agent), common.StatusPending},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := eval.Evaluate(context.Background(), tc.pr.context())
			if res.Error != nil {
				t.Fatalf("evaluation error: %v", res.Error)
			}
			t.Logf("status=%s rules: %s", res.Status, deciding(res))
			if res.Status != tc.want {
				t.Fatalf("status %s, want %s", res.Status, tc.want)
			}
		})
	}
}
