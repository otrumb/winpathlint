package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) {
	return 0, os.ErrClosed
}

func TestRun_whenOutputFails(t *testing.T) {
	repo := gitFixture(t, []string{"NUL"})
	for _, format := range []string{"text", "json"} {
		t.Run(format, func(t *testing.T) {
			var stderr bytes.Buffer
			code := run([]string{"--repo", repo, "--format", format}, failingWriter{}, &stderr)
			if code != 2 || stderr.Len() == 0 {
				t.Fatalf("code %d stderr %q", code, stderr.String())
			}
		})
	}
}

func TestRun_whenDefaultsUseCurrentWorktree(t *testing.T) {
	repo := gitFixture(t, []string{"ok.txt"})
	t.Chdir(repo)
	var stdout, stderr bytes.Buffer
	code := run(nil, &stdout, &stderr)
	if code != 0 || stdout.Len() != 0 || stderr.Len() != 0 {
		t.Fatalf("code %d stdout %q stderr %q", code, stdout.String(), stderr.String())
	}
}

func TestTrackedPaths_whenGitMetadataDirectory(t *testing.T) {
	repo := gitFixture(t, nil)
	_, err := trackedPaths(context.Background(), filepath.Join(repo, ".git"))
	if !errors.Is(err, errWorktree) {
		t.Fatalf("error = %v", err)
	}
}

func TestTrackedPaths_whenIndexCorrupt(t *testing.T) {
	repo := gitFixture(t, nil)
	if err := os.WriteFile(filepath.Join(repo, ".git", "index"), []byte("corrupt"), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := trackedPaths(context.Background(), repo)
	if err == nil {
		t.Fatal("expected corrupt-index error")
	}
}

func TestTrackedPaths_whenContextCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := trackedPaths(ctx, ".")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
}

func TestTrackedPaths_whenPathIsNotUTF8(t *testing.T) {
	repo := gitFixture(t, []string{"bad\xff"})
	_, err := trackedPaths(context.Background(), repo)
	if !errors.Is(err, errIndexData) {
		t.Fatalf("error = %v", err)
	}
}
