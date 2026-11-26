package main

import (
	"fmt"
	"reflect"
	"slices"
	"sort"

	"github.com/palantir/policy-bot/policy"
	"github.com/palantir/policy-bot/policy/approval"
	"github.com/palantir/policy-bot/policy/common"
	"github.com/palantir/policy-bot/policy/predicate"
	"github.com/pkg/errors"
	"gopkg.in/yaml.v2"
)

type Violations []string

func (v Violations) Error() string {
	msg := fmt.Sprintf("%d policy violation(s):", len(v))
	for _, s := range v {
		msg += "\n  - " + s
	}
	return msg
}

func Check(data []byte) error {
	var top map[string]any
	if err := yaml.Unmarshal(data, &top); err != nil {
		return errors.Wrap(err, "failed to parse yaml")
	}
	if _, ok := top["remote"]; ok {
		return errors.New("remote policy references are not allowed")
	}

	var cfg policy.Config
	if err := yaml.UnmarshalStrict(data, &cfg); err != nil {
		return errors.Wrap(err, "failed to parse policy from yaml")
	}
	if _, err := policy.ParsePolicy(&cfg, nil); err != nil {
		return errors.Wrap(err, "failed to parse policy")
	}

	var v Violations
	add := func(format string, args ...any) { v = append(v, fmt.Sprintf(format, args...)) }

	referenced, err := topLevelOr(cfg.Policy.Approval)
	if err != nil {
		add("%v", err)
	}
	defined := make([]string, 0, len(cfg.ApprovalRules))
	for _, r := range cfg.ApprovalRules {
		defined = append(defined, r.Name)
	}
	sort.Strings(defined)
	if referenced != nil && !slices.Equal(sortedCopy(referenced), defined) {
		add("policy.approval must reference every approval rule exactly once: referenced %v, defined %v", referenced, defined)
	}

	unconditional := 0
	for _, r := range cfg.ApprovalRules {
		checkOptions(r, add)
		checkRequires(r, add)
		if reflect.ValueOf(r.Predicates).IsZero() {
			unconditional++
			if r.Requires.Count < 2 {
				add("rule %q has no conditions and must require at least 2 approvals", r.Name)
			}
			continue
		}
		if r.Requires.Count < 2 && !isHumanRule(r) && !isAutomationLane(r) {
			add("rule %q requires fewer than 2 approvals but is neither the human author rule nor a scoped automation lane", r.Name)
		}
	}
	if unconditional == 0 {
		add("policy must contain an unconditional rule so that it can never be skipped")
	}

	if len(v) > 0 {
		return v
	}
	return nil
}

func topLevelOr(p approval.Policy) ([]string, error) {
	if len(p) != 1 {
		return nil, errors.Errorf("policy.approval must contain exactly one 'or' entry, found %d entries", len(p))
	}
	m, ok := p[0].(map[any]any)
	if !ok || len(m) != 1 {
		return nil, errors.New("policy.approval entry must be a single 'or' of rule names")
	}
	list, ok := m["or"].([]any)
	if !ok {
		return nil, errors.New("policy.approval entry must be a single 'or' of rule names")
	}
	names := make([]string, 0, len(list))
	for _, item := range list {
		s, ok := item.(string)
		if !ok {
			return nil, errors.New("policy.approval 'or' must list rule names only, without nesting")
		}
		names = append(names, s)
	}
	return names, nil
}

func checkOptions(r *approval.Rule, add func(string, ...any)) {
	o := r.Options
	if o.IsAllowAuthor() {
		add("rule %q: allow_author must be false", r.Name)
	}
	if o.IsAllowContributor() {
		add("rule %q: allow_contributor must be false", r.Name)
	}
	if o.IsAllowNonAuthorContributor() {
		add("rule %q: allow_non_author_contributor must be false", r.Name)
	}
	if !o.IsInvalidateOnPush() {
		add("rule %q: invalidate_on_push must be true", r.Name)
	}
	if o.IsIgnoreUpdateMerges() {
		add("rule %q: ignore_update_merges must be false", r.Name)
	}
	if ignored := o.GetIgnoreCommitsBy(); !ignored.IsZero() {
		add("rule %q: ignore_commits_by must be empty", r.Name)
	}
	m := o.GetMethods()
	if len(m.GetComments()) > 0 || len(m.GetCommentPatterns()) > 0 || len(m.GetBodyPatterns()) > 0 || len(m.GetGithubReviewCommentPatterns()) > 0 {
		add("rule %q: only GitHub review approvals may count, comment, body and review comment patterns must be empty", r.Name)
	}
	if !m.IsGithubReview() {
		add("rule %q: github_review must be true", r.Name)
	}
}

func checkRequires(r *approval.Rule, add func(string, ...any)) {
	req := r.Requires
	if req.Count < 1 {
		add("rule %q: requires.count must be at least 1", r.Name)
	}
	if !onlyTeam(req.Actors) {
		add("rule %q: requires must list only the team %s", r.Name, ApproverTeam)
	}
	if !reflect.ValueOf(req.Conditions).IsZero() {
		add("rule %q: requires.conditions must be empty", r.Name)
	}
}

func onlyTeam(a common.Actors) bool {
	return slices.Equal(a.Teams, []string{ApproverTeam}) &&
		len(a.Users) == 0 && len(a.Organizations) == 0 && len(a.Permissions) == 0 &&
		!a.Admins && !a.WriteCollaborators
}

func onlyUser(a common.Actors) (string, bool) {
	if len(a.Users) != 1 || len(a.Teams) != 0 || len(a.Organizations) != 0 || len(a.Permissions) != 0 || a.Admins || a.WriteCollaborators {
		return "", false
	}
	return a.Users[0], true
}

func isHumanRule(r *approval.Rule) bool {
	if r.Predicates.HasAuthorIn == nil || !onlyTeam(r.Predicates.HasAuthorIn.Actors) {
		return false
	}
	rest := r.Predicates
	rest.HasAuthorIn = nil
	return reflect.ValueOf(rest).IsZero()
}

func isAutomationLane(r *approval.Rule) bool {
	p := r.Predicates
	if p.HasAuthorIn == nil || p.OnlyHasContributorsIn == nil || p.OnlyChangedFiles == nil {
		return false
	}
	author, ok := onlyUser(p.HasAuthorIn.Actors)
	if !ok || !appLogin.MatchString(author) {
		return false
	}
	contributor, ok := onlyUser(p.OnlyHasContributorsIn.Actors)
	if !ok || contributor != author {
		return false
	}
	if p.HasValidSignaturesBy == nil {
		return false
	}
	if _, ok := onlyUser(p.HasValidSignaturesBy.Actors); !ok {
		return false
	}
	if p.FromBranch == nil || p.FromBranch.Pattern.IsZero() {
		return false
	}
	if branchProblem(p.FromBranch.Pattern.String()) != "" {
		return false
	}
	return hasNarrowPaths(p.OnlyChangedFiles)
}

func hasNarrowPaths(f *predicate.OnlyChangedFiles) bool {
	if len(f.Paths) == 0 || len(f.Globs) != 0 {
		return false
	}
	for _, p := range f.Paths {
		if pathProblem(p.String()) != "" {
			return false
		}
	}
	return true
}

func sortedCopy(s []string) []string {
	c := slices.Clone(s)
	sort.Strings(c)
	return c
}
