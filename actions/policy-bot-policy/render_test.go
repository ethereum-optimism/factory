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
			"name":        "bot lane",
			"description": "d",
			"app":         "bot[bot]",
			"signer":      "web-flow",
			"branch":      "'^bot/'",
			"paths":       "['^deps/lock\\.json$']",
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
		for _, k := range []string{"name", "description", "app", "signer", "branch", "paths", "exclude_paths", "count"} {
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
		"reserved human name":   lane("name='human change'"),
		"reserved default name": lane("name='no accountable human author'"),
		"missing name":          lane("name="),
		"missing description":   lane("description="),
		"user not app":          lane("app=someone"),
		"team as app":           lane("app='org/team'"),
		"missing paths":         lane("paths="),
		"empty paths":           lane("paths=[]"),
		"missing signer":        lane("signer="),
		"missing branch":        lane("branch="),
		"broad branch":          lane("branch='^.*'"),
		"branch matching main":  lane("branch='^ma'"),
		"dot star path":         lane("paths=['.*']"),
		"anchored dot star":     lane("paths=['^.*$']"),
		"empty alternative":     lane("paths=['^|.*$']"),
		"any file in any dir":   lane("paths=['(^|/).*$']"),
		"policy file path":      lane("paths=['^\\.policy\\.yml$']"),
		"values file path":      lane("paths=['^\\.github/policy-bot-values\\.yml$']"),
		"workflow paths":        lane("paths=['^\\.github/workflows/[^/]+$']"),
		"dot dot path":          lane("paths=['(^|/)y$']"),
		"unanchored path":       lane("paths=['go.mod']"),
		"unterminated path":     lane("paths=['^docs/']"),
		"bad regexp":            lane("paths=['^(a$']"),
		"unanchored branch":     lane("branch='renovate/'"),
		"bad signer":            lane("signer='a b'"),
		"unknown key":           lane("count=0"),
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
