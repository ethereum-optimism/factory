package main

import (
	"bytes"
	_ "embed"
	"fmt"
	"regexp"
	"strings"
	"text/template"

	"github.com/pkg/errors"
	"gopkg.in/yaml.v2"
)

const (
	ApproverTeam = "ethereum-optimism/engineering"
	HumanRule    = "human change"
	DefaultRule  = "no accountable human author"
)

//go:embed policy.yml.tmpl
var policyTemplate string

const ValuesPath = ".github/policy-bot-values.yml"

var (
	appLogin  = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*\[bot\]$`)
	userLogin = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$`)

	canaryPaths = []string{
		"",
		"a",
		"src/main.go",
		".github/workflows/x.yml",
		"Dockerfile",
		".policy.yml",
		ValuesPath,
		"x/../y",
	}
	canaryBranches = []string{"", "main", "feature/x"}
)

func pathProblem(pattern string, re *regexp.Regexp) string {
	for _, c := range canaryPaths {
		if re.MatchString(c) {
			return fmt.Sprintf("path %q matches %q, which a lane must never cover", pattern, c)
		}
	}
	return ""
}

func branchProblem(pattern string, re *regexp.Regexp) string {
	if !strings.HasPrefix(pattern, "^") {
		return fmt.Sprintf("branch pattern %q must be anchored with ^", pattern)
	}
	for _, c := range canaryBranches {
		if re.MatchString(c) {
			return fmt.Sprintf("branch pattern %q matches %q, which a lane must never cover", pattern, c)
		}
	}
	return ""
}

type Values struct {
	Automation []Lane `yaml:"automation"`
}

type Lane struct {
	Name         string   `yaml:"name"`
	Description  string   `yaml:"description"`
	App          string   `yaml:"app"`
	Signer       string   `yaml:"signer"`
	Branch       string   `yaml:"branch"`
	Paths        []string `yaml:"paths"`
	ExcludePaths []string `yaml:"exclude_paths"`
}

type templateData struct {
	Team        string
	HumanRule   string
	DefaultRule string
	Automation  []Lane
}

func ParseValues(data []byte) (*Values, error) {
	var v Values
	if err := yaml.UnmarshalStrict(data, &v); err != nil {
		return nil, errors.Wrap(err, "failed to parse values")
	}
	if err := v.validate(); err != nil {
		return nil, err
	}
	return &v, nil
}

func (v *Values) validate() error {
	seen := map[string]bool{HumanRule: true, DefaultRule: true}
	for i, l := range v.Automation {
		where := fmt.Sprintf("automation[%d]", i)
		if strings.TrimSpace(l.Name) == "" {
			return errors.Errorf("%s: name is required", where)
		}
		if seen[l.Name] {
			return errors.Errorf("%s: rule name %q is reserved or duplicated", where, l.Name)
		}
		seen[l.Name] = true
		if strings.TrimSpace(l.Description) == "" {
			return errors.Errorf("%s: description is required", where)
		}
		if strings.ContainsAny(l.Name+l.Description, "\n\r") {
			return errors.Errorf("%s: name and description must be single lines", where)
		}
		if !appLogin.MatchString(l.App) {
			return errors.Errorf("%s: app %q must be a GitHub App login ending in [bot]", where, l.App)
		}
		if !userLogin.MatchString(l.Signer) {
			return errors.Errorf("%s: signer %q is required and must be a GitHub login", where, l.Signer)
		}
		if l.Branch == "" {
			return errors.Errorf("%s: branch is required", where)
		}
		branch, err := regexp.Compile(l.Branch)
		if err != nil {
			return errors.Wrapf(err, "%s: invalid branch pattern", where)
		}
		if problem := branchProblem(l.Branch, branch); problem != "" {
			return errors.Errorf("%s: %s", where, problem)
		}
		if len(l.Paths) == 0 {
			return errors.Errorf("%s: at least one path is required", where)
		}
		for _, p := range l.Paths {
			re, err := regexp.Compile(p)
			if err != nil {
				return errors.Wrapf(err, "%s: invalid path %q", where, p)
			}
			if problem := pathProblem(p, re); problem != "" {
				return errors.Errorf("%s: %s", where, problem)
			}
			if !strings.Contains(p, "^") || !strings.HasSuffix(p, "$") {
				return errors.Errorf("%s: path %q must be anchored with ^ and $", where, p)
			}
		}
		for _, p := range l.ExcludePaths {
			if _, err := regexp.Compile(p); err != nil {
				return errors.Wrapf(err, "%s: invalid exclude path %q", where, p)
			}
		}
	}
	return nil
}

func quote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func Render(v *Values) ([]byte, error) {
	tmpl, err := template.New("policy").Option("missingkey=error").Funcs(template.FuncMap{"q": quote}).Parse(policyTemplate)
	if err != nil {
		return nil, errors.Wrap(err, "failed to parse template")
	}
	var buf bytes.Buffer
	data := templateData{
		Team:        ApproverTeam,
		HumanRule:   HumanRule,
		DefaultRule: DefaultRule,
		Automation:  v.Automation,
	}
	if err := tmpl.Execute(&buf, data); err != nil {
		return nil, errors.Wrap(err, "failed to render template")
	}
	return buf.Bytes(), nil
}
