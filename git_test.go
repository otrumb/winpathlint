package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

func gitFixture(t *testing.T, paths []string) string {
	t.Helper()
	repo := t.TempDir()
	runGit := func(input string, args ...string) string {
		t.Helper()
		command := exec.Command("git", append([]string{"-C", repo}, args...)...)
		command.Env = append(os.Environ(), "GIT_MASTER=1")
		command.Stdin = strings.NewReader(input)
		output, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v: %s", args, err, output)
		}
		return string(output)
	}
	runGit("", "init", "--quiet")
	blob := strings.TrimSpace(runGit("fixture", "hash-object", "-w", "--stdin"))
	var index strings.Builder
	for _, path := range paths {
		index.WriteString("100644 " + blob + "\t" + path + "\x00")
	}
	runGit(index.String(), "-c", "core.protectNTFS=false", "-c", "core.ignoreCase=false", "update-index", "-z", "--index-info")
	return repo
}

func TestTrackedPaths_whenIndexContainsUncheckoutableNames(t *testing.T) {
	paths := []string{"Foo", "foo", "NUL.txt", "bad?name", "line\nbreak", "tab\tname", "space name", "trailing.", "sub/file"}
	repo := gitFixture(t, paths)
	if err := os.Mkdir(filepath.Join(repo, "sub"), 0700); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(filepath.Join(repo, ".git", "index"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := trackedPaths(context.Background(), filepath.Join(repo, "sub"))
	slices.Sort(paths)
	if err != nil || !reflect.DeepEqual(got, paths) {
		t.Fatalf("got %#v, %v; want %#v", got, err, paths)
	}
	after, err := os.ReadFile(filepath.Join(repo, ".git", "index"))
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("index changed: %v", err)
	}
}

func TestTrackedPaths_whenEmptyIndex(t *testing.T) {
	repo := gitFixture(t, nil)
	got, err := trackedPaths(context.Background(), repo)
	if err != nil || len(got) != 0 {
		t.Fatalf("got %#v, %v", got, err)
	}
}

func TestTrackedPaths_whenOutsideWorktree(t *testing.T) {
	repo := t.TempDir()
	_, err := trackedPaths(context.Background(), repo)
	if err == nil {
		t.Fatal("expected Git error")
	}
}

func TestTrackedPaths_whenGitMissing(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	_, err := trackedPaths(context.Background(), ".")
	if err == nil {
		t.Fatal("expected missing Git error")
	}
}
