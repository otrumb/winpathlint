package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"unicode/utf8"
)

var errIndexData = errors.New("Git returned malformed or non-UTF-8 index paths")
var errWorktree = errors.New("repository must be inside a Git worktree")

func trackedPaths(ctx context.Context, repo string) ([]string, error) {
	check := exec.CommandContext(ctx, "git", "-C", repo, "rev-parse", "--is-inside-work-tree")
	output, err := check.Output()
	if err != nil {
		return nil, fmt.Errorf("check worktree: %w", err)
	}
	if strings.TrimSpace(string(output)) != "true" {
		return nil, errWorktree
	}
	command := exec.CommandContext(ctx, "git", "-C", repo, "ls-files", "--full-name", "-z", "--", ":/")
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err = command.Output()
	if err != nil {
		return nil, fmt.Errorf("read Git index: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	if len(output) == 0 {
		return []string{}, nil
	}
	if output[len(output)-1] != 0 || !utf8.Valid(output) {
		return nil, errIndexData
	}
	return strings.Split(string(output[:len(output)-1]), "\x00"), nil
}
