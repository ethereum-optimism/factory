package main

import (
	"os"
	"strings"
	"testing"
)

func golden(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile("testdata/renovate-lane/policy.yml")
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestCheckRejectsWeakenedPolicies(t *testing.T) {
	base := golden(t)
	if err := Check([]byte(base)); err != nil {
		t.Fatalf("golden rejected: %v", err)
	}

	replace := func(old, new string) string {
		if !strings.Contains(base, old) {
			t.Fatalf("fixture does not contain %q", old)
		}
		return strings.Replace(base, old, new, 1)
	}
	ruleOption := func(rule, option string) string {
		return replace("  - name: '"+rule+"'\n", "  - name: '"+rule+"'\n    options:\n      "+option+"\n")
	}

	cases := map[string]string{
		"allow author":                 replace("allow_author: false", "allow_author: true"),
		"allow contributor":            replace("allow_contributor: false", "allow_contributor: true"),
		"allow non author contributor": replace("allow_non_author_contributor: false", "allow_non_author_contributor: true"),
		"no invalidate on push":        replace("invalidate_on_push: true", "invalidate_on_push: false"),
		"ignore update merges":         replace("ignore_update_merges: false", "ignore_update_merges: true"),
		"comment approvals":            replace("comments: []", "comments: ['lgtm']"),
		"comment pattern approvals":    replace("comment_patterns: []", "comment_patterns: ['^/approve']"),
		"body pattern approvals":       replace("body_patterns: []", "body_patterns: ['approved']"),
		"review comment patterns":      replace("github_review_comment_patterns: []", "github_review_comment_patterns: ['.*']"),
		"no github review":             replace("github_review: true", "github_review: false"),
		"default methods restored":     replace("      comments: []\n", ""),
		"ignore commits by":            replace("    request_review:", "    ignore_commits_by:\n      users: ['someone']\n    request_review:"),
		"rule allows author":           ruleOption("human change", "allow_author: true"),
		"rule restores comments":       ruleOption("no accountable human author", "methods:\n        comments: [':+1:']"),
		"default count one":            replace("      count: 2\n", "      count: 1\n"),
		"default count zero":           replace("      count: 2\n", "      count: 0\n"),
		"approver user":                replace("      count: 2\n      teams: ['ethereum-optimism/engineering']", "      count: 2\n      users: ['someone']"),
		"approver extra user":          replace("      count: 2\n      teams: ['ethereum-optimism/engineering']", "      count: 2\n      teams: ['ethereum-optimism/engineering']\n      users: ['someone']"),
		"approver org":                 replace("      count: 2\n      teams: ['ethereum-optimism/engineering']", "      count: 2\n      organizations: ['ethereum-optimism']"),
		"approver write permission":    replace("      count: 2\n      teams: ['ethereum-optimism/engineering']", "      count: 2\n      permissions: ['write']"),
		"approver other team":          replace("      count: 2\n      teams: ['ethereum-optimism/engineering']", "      count: 2\n      teams: ['ethereum-optimism/other']"),
		"human rule for org":           replace("      has_author_in:\n        teams: ['ethereum-optimism/engineering']", "      has_author_in:\n        organizations: ['ethereum-optimism']"),
		"lane without paths":           replace("      only_changed_files:\n        paths:\n          - '(^|/)go\\.(mod|sum)$'\n          - '(^|/)uv\\.lock$'\n          - '(^|/)Pipfile(\\.lock)?$'\n          - '(^|/)requirements\\.txt$'\n          - '(^|/)yarn\\.lock$'\n", ""),
		"lane other contributors":      replace("      only_has_contributors_in:\n        users: ['renovate[bot]']", "      only_has_contributors_in:\n        users: ['renovate[bot]', 'someone']"),
		"lane human author":            replace("      has_author_in:\n        users: ['renovate[bot]']", "      has_author_in:\n        users: ['someone']"),
		"default rule unreferenced":    replace("        - 'no accountable human author'\n", ""),
		"and instead of or":            replace("    - or:\n", "    - and:\n"),
		"default rule conditional":     replace("  - name: 'no accountable human author'\n", "  - name: 'no accountable human author'\n    if:\n      targets_branch:\n        pattern: '^main$'\n"),
		"unknown key":                  replace("approval_rules:", "unknown: true\napproval_rules:"),
		"remote reference":             "remote: ethereum-optimism/policies\npath: policy.yml\n",
		"empty":                        "",
		"invalid yaml":                 "policy: [",
	}
	for name, policy := range cases {
		t.Run(name, func(t *testing.T) {
			err := Check([]byte(policy))
			if err == nil {
				t.Fatalf("weakened policy accepted:\n%s", policy)
			}
			t.Logf("rejected: %v", err)
		})
	}
}

func TestCheckAcceptsStricterPolicies(t *testing.T) {
	base := golden(t)
	stricter := strings.Replace(base, "      count: 1\n", "      count: 2\n", 1)
	if err := Check([]byte(stricter)); err != nil {
		t.Fatalf("stricter policy rejected: %v", err)
	}
}
