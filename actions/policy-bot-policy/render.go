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

var (
	literalName    = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
	renderedPath   = regexp.MustCompile(`^\(\^\|/\)(?:[A-Za-z0-9_-]|\\\.)+\$$`)
	renderedBranch = regexp.MustCompile(`^\^(?:[A-Za-z0-9_-]|\\\.)+/$`)
	onlyDots       = regexp.MustCompile(`^\.+$`)
)

func escapeLiteral(s string) string {
	return strings.ReplaceAll(s, ".", `\.`)
}

func PathPattern(file string) string {
	return `(^|/)` + escapeLiteral(file) + `$`
}

func BranchPattern(prefix string) string {
	return `^` + escapeLiteral(prefix) + `/`
}

func pathProblem(pattern string) string {
	if !renderedPath.MatchString(pattern) {
		return fmt.Sprintf("path %q must have the form (^|/)<file name>$ with only letters, digits, _, - and escaped dots", pattern)
	}
	re := regexp.MustCompile(pattern)
	for _, c := range canaryPaths {
		if re.MatchString(c) {
			return fmt.Sprintf("path %q matches %q, which a lane must never cover", pattern, c)
		}
	}
	return ""
}

func branchProblem(pattern string) string {
	if !renderedBranch.MatchString(pattern) {
		return fmt.Sprintf("branch pattern %q must have the form ^<prefix>/ with only letters, digits, _, - and escaped dots", pattern)
	}
	re := regexp.MustCompile(pattern)
	for _, c := range canaryBranches {
		if re.MatchString(c) {
			return fmt.Sprintf("branch pattern %q matches %q, which a lane must never cover", pattern, c)
		}
	}
	return ""
}

func literalProblem(kind, s string) string {
	if !literalName.MatchString(s) || onlyDots.MatchString(s) {
		return fmt.Sprintf("%s %q must be a plain name of letters, digits, _, - and .", kind, s)
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
	BranchPrefix string   `yaml:"branch_prefix"`
	Files        []string `yaml:"files"`
}

type renderedLane struct {
	Name        string
	Description string
	App         string
	Signer      string
	Branch      string
	Paths       []string
}

type templateData struct {
	Team        string
	HumanRule   string
	DefaultRule string
	Automation  []renderedLane
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
		if l.BranchPrefix == "" {
			return errors.Errorf("%s: branch_prefix is required", where)
		}
		if problem := literalProblem("branch_prefix", l.BranchPrefix); problem != "" {
			return errors.Errorf("%s: %s", where, problem)
		}
		if problem := branchProblem(BranchPattern(l.BranchPrefix)); problem != "" {
			return errors.Errorf("%s: %s", where, problem)
		}
		if len(l.Files) == 0 {
			return errors.Errorf("%s: at least one file is required", where)
		}
		for _, f := range l.Files {
			if problem := literalProblem("file", f); problem != "" {
				return errors.Errorf("%s: %s", where, problem)
			}
			if problem := pathProblem(PathPattern(f)); problem != "" {
				return errors.Errorf("%s: %s", where, problem)
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
	}
	for _, l := range v.Automation {
		r := renderedLane{
			Name:        l.Name,
			Description: l.Description,
			App:         l.App,
			Signer:      l.Signer,
			Branch:      BranchPattern(l.BranchPrefix),
		}
		for _, f := range l.Files {
			r.Paths = append(r.Paths, PathPattern(f))
		}
		data.Automation = append(data.Automation, r)
	}
	if err := tmpl.Execute(&buf, data); err != nil {
		return nil, errors.Wrap(err, "failed to render template")
	}
	return buf.Bytes(), nil
}
