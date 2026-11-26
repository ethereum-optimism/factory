package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"

	"github.com/pkg/errors"
)

const usage = `usage:
  policy-bot-policy render -values <values.yml> [-out <file>]
  policy-bot-policy check -policy <.policy.yml> [-values <values.yml>]
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "render":
		err = runRender(os.Args[2:])
	case "check":
		err = runCheck(os.Args[2:])
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func renderFile(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.Wrap(err, "failed to read values")
	}
	v, err := ParseValues(data)
	if err != nil {
		return nil, err
	}
	return Render(v)
}

func runRender(args []string) error {
	fs := flag.NewFlagSet("render", flag.ExitOnError)
	values := fs.String("values", "", "path to the values file")
	out := fs.String("out", "", "output path, stdout if empty")
	_ = fs.Parse(args)
	if *values == "" {
		return errors.New("-values is required")
	}
	rendered, err := renderFile(*values)
	if err != nil {
		return err
	}
	if err := Check(rendered); err != nil {
		return errors.Wrap(err, "rendered policy failed the check")
	}
	if *out == "" {
		_, err = os.Stdout.Write(rendered)
		return err
	}
	return os.WriteFile(*out, rendered, 0o644)
}

func runCheck(args []string) error {
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	policyPath := fs.String("policy", ".policy.yml", "path to the policy file")
	values := fs.String("values", "", "optional values file; the policy must equal its rendering")
	_ = fs.Parse(args)

	data, err := os.ReadFile(*policyPath)
	if err != nil {
		return errors.Wrap(err, "failed to read policy")
	}
	if err := Check(data); err != nil {
		return err
	}
	if *values != "" {
		rendered, err := renderFile(*values)
		if err != nil {
			return err
		}
		if !bytes.Equal(rendered, data) {
			return errors.Errorf("%s differs from the rendering of %s; run: policy-bot-policy render -values %s -out %s", *policyPath, *values, *values, *policyPath)
		}
	}
	fmt.Printf("%s: ok\n", *policyPath)
	return nil
}
