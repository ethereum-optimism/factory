package main

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite golden files")

func TestRenderGolden(t *testing.T) {
	dirs, err := filepath.Glob("testdata/*/values.yml")
	if err != nil || len(dirs) == 0 {
		t.Fatalf("no golden cases found: %v", err)
	}
	for _, valuesPath := range dirs {
		dir := filepath.Dir(valuesPath)
		t.Run(filepath.Base(dir), func(t *testing.T) {
			rendered, err := renderFile(valuesPath)
			if err != nil {
				t.Fatalf("render: %v", err)
			}
			goldenPath := filepath.Join(dir, "policy.yml")
			if *update {
				if err := os.WriteFile(goldenPath, rendered, 0o644); err != nil {
					t.Fatal(err)
				}
			}
			golden, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatal(err)
			}
			if string(golden) != string(rendered) {
				t.Fatalf("rendering of %s differs from %s; rerun with -update and review the diff", valuesPath, goldenPath)
			}
			if err := Check(rendered); err != nil {
				t.Fatalf("golden policy fails the check: %v", err)
			}
		})
	}
}

func TestValuesRejected(t *testing.T) {
	lane := func(extra string) string {
		base := map[string]string{
			"name":          "bot lane",
			"description":   "d",
			"app":           "bot[bot]",
			"signer":        "web-flow",
			"branch_prefix": "bot",
			"files":         "['lock.json']",
		}
		for _, kv := range strings.Split(extra, ";") {
			if kv == "" {
				continue
			}
			k, v, _ := strings.Cut(kv, "=")
			if v == "" {
				delete(base, k)
				continue
			}
			base[k] = v
		}
		var b strings.Builder
		b.WriteString("automation:\n  - ")
		first := true
		for _, k := range []string{"name", "description", "app", "signer", "branch_prefix", "files", "branch", "paths", "count"} {
			v, ok := base[k]
			if !ok {
				continue
			}
			if !first {
				b.WriteString("    ")
			}
			first = false
			b.WriteString(k + ": " + v + "\n")
		}
		return b.String()
	}

	if _, err := ParseValues([]byte(lane(""))); err != nil {
		t.Fatalf("baseline lane rejected: %v", err)
	}

	cases := map[string]string{
		"reserved human name":    lane("name='human change'"),
		"reserved default name":  lane("name='no accountable human author'"),
		"missing name":           lane("name="),
		"missing description":    lane("description="),
		"user not app":           lane("app=someone"),
		"team as app":            lane("app='org/team'"),
		"missing files":          lane("files="),
		"empty files":            lane("files=[]"),
		"missing signer":         lane("signer="),
		"missing branch prefix":  lane("branch_prefix="),
		"regex branch":           lane("branch_prefix='^.*'"),
		"branch with slash":      lane("branch_prefix='renovate/x'"),
		"branch alternation":     lane("branch_prefix='renovate/|^[a-z]+/[a-z]+/.*'"),
		"branch group":           lane("branch_prefix='(renovate/|[a-z]+/[a-z]+/)'"),
		"branch dots only":       lane("branch_prefix='..'"),
		"file dot star":          lane("files=['.*']"),
		"file regex":             lane("files=['^.*$']"),
		"file empty alternative": lane("files=['^|.*$']"),
		"file any":               lane("files=['(^|/).*$']"),
		"file extensions":        lane("files=['^.*\\.(rs|py|js|ts|sol|sh)$']"),
		"file extension group":   lane("files=['^(.*\\.(rs|py|sol|ts|js|sh|c|cpp|java))$']"),
		"file any makefile":      lane("files=['^.*/Makefile$']"),
		"file class":             lane("files=['^[a-z]+/.*\\.(rs|py|sol)$']"),
		"file with directory":    lane("files=['docs/a.md']"),
		"file policy":            lane("files=['.policy.yml']"),
		"file values":            lane("files=['policy-bot-values.yml']"),
		"file dockerfile":        lane("files=['Dockerfile']"),
		"file canary a":          lane("files=['a']"),
		"file dots only":         lane("files=['..']"),
		"old regex keys":         lane("files=;branch_prefix=;branch='^bot/';paths=['(^|/)go\\.mod$']"),
		"unknown key":            lane("count=0"),
	}
	for name, values := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := ParseValues([]byte(values))
			if err == nil {
				t.Fatalf("values accepted:\n%s", values)
			}
			t.Logf("rejected: %v", err)
		})
	}

	dup := lane("") + strings.TrimPrefix(lane(""), "automation:\n")
	if _, err := ParseValues([]byte(dup)); err == nil {
		t.Fatal("duplicate lane names accepted")
	}
}
