package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestRun_whenInvalidArguments(t *testing.T) {
	for _, args := range [][]string{{"--unknown"}, {"--format", "xml"}, {"--max-path", "0"}, {"--max-path", "-1"}, {"--max-path", "x"}, {"extra"}, {"--repo"}, {"--repo", ""}} {
		var stdout, stderr bytes.Buffer
		code := run(args, &stdout, &stderr)
		if code != 2 || stdout.Len() != 0 || stderr.Len() == 0 {
			t.Fatalf("%v: code %d stdout %q stderr %q", args, code, stdout.String(), stderr.String())
		}
	}
}

func TestRun_whenHelpRequested(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"--help"}, &stdout, &stderr)
	if code != 0 || !strings.Contains(stderr.String(), "-max-path") {
		t.Fatalf("code %d help %q", code, stderr.String())
	}
}

func TestRun_whenCleanJSON(t *testing.T) {
	repo := gitFixture(t, []string{"src/main.go"})
	var stdout, stderr bytes.Buffer
	code := run([]string{"--repo", repo, "--format", "json"}, &stdout, &stderr)
	if code != 0 || stdout.String() != "[]\n" || stderr.Len() != 0 {
		t.Fatalf("code %d stdout %q stderr %q", code, stdout.String(), stderr.String())
	}
}

func TestRun_whenFindingsJSON(t *testing.T) {
	repo := gitFixture(t, []string{"foo", "Foo", "NUL.txt", "line\nbreak"})
	var stdout, stderr bytes.Buffer
	code := run([]string{"--repo", repo, "--format", "json"}, &stdout, &stderr)
	var got []finding
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	want := []finding{
		{Path: "NUL.txt", Rule: "reserved_device_name", Component: "NUL.txt"},
		{Path: "foo", Rule: "case_collision", Component: "foo", Related: "Foo"},
		{Path: "line\nbreak", Rule: "control_character", Component: "line\nbreak"},
	}
	if code != 1 || !reflect.DeepEqual(got, want) || stderr.Len() != 0 {
		t.Fatalf("code %d got %#v stderr %q", code, got, stderr.String())
	}
}

func TestRun_whenTextFindingsAndCustomBudget(t *testing.T) {
	repo := gitFixture(t, []string{"abcde", "line\nbreak"})
	var stdout, stderr bytes.Buffer
	code := run([]string{"--repo", repo, "--max-path", "4"}, &stdout, &stderr)
	want := "path_too_long\t\"abcde\"\t\"\"\t\"\"\ncontrol_character\t\"line\\nbreak\"\t\"line\\nbreak\"\t\"\"\npath_too_long\t\"line\\nbreak\"\t\"\"\t\"\"\n"
	if code != 1 || stdout.String() != want {
		t.Fatalf("code %d output %q; want %q", code, stdout.String(), want)
	}
}

func TestRun_whenNotWorktree(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"--repo", t.TempDir()}, &stdout, &stderr)
	if code != 2 || stdout.Len() != 0 || stderr.Len() == 0 {
		t.Fatalf("code %d stdout %q stderr %q", code, stdout.String(), stderr.String())
	}
}

func TestCLI_whenExecuted(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "winpathlint.exe")
	build := exec.Command("go", "build", "-o", binary, ".")
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v: %s", err, output)
	}
	repo := gitFixture(t, []string{"Foo", "foo"})
	for _, scenario := range []struct {
		name string
		args []string
		code int
	}{
		{"help", []string{"--help"}, 0},
		{"findings", []string{"--repo", repo, "--format", "json"}, 1},
		{"invalid", []string{"--format", "invalid"}, 2},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			command := exec.Command(binary, scenario.args...)
			output, err := command.CombinedOutput()
			code := 0
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				code = exit.ExitCode()
			} else if err != nil {
				t.Fatal(err)
			}
			if code != scenario.code || len(output) == 0 {
				t.Fatalf("code %d output %q", code, output)
			}
		})
	}
}
