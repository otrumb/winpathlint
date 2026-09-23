package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("winpathlint", flag.ContinueOnError)
	flags.SetOutput(stderr)
	repo := flags.String("repo", ".", "Git worktree directory (entire index is scanned)")
	format := flags.String("format", "text", "output format: text or json")
	maxPath := flags.Int("max-path", 240, "maximum repository-relative UTF-16 path length (positive)")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if flags.NArg() != 0 || *repo == "" || *maxPath <= 0 {
		fmt.Fprintln(stderr, "winpathlint: require flags only, nonempty --repo and positive --max-path")
		return 2
	}
	switch *format {
	case "text", "json":
	default:
		fmt.Fprintln(stderr, "winpathlint: --format must be text or json")
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	paths, err := trackedPaths(ctx, *repo)
	if err != nil {
		fmt.Fprintf(stderr, "winpathlint: %v\n", err)
		return 2
	}
	findings := scan(paths, *maxPath)
	switch *format {
	case "json":
		err = json.NewEncoder(stdout).Encode(findings)
	case "text":
		for _, item := range findings {
			if _, err = fmt.Fprintf(stdout, "%s\t%q\t%q\t%q\n", item.Rule, item.Path, item.Component, item.Related); err != nil {
				break
			}
		}
	}
	if err != nil {
		fmt.Fprintf(stderr, "winpathlint: write output: %v\n", err)
		return 2
	}
	if len(findings) > 0 {
		return 1
	}
	return 0
}
