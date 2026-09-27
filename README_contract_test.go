package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestREADME_documentsInstallAndQuickstartContracts(t *testing.T) {
	readme, err := os.ReadFile("README.md")
	if err != nil {
		t.Fatal(err)
	}
	readmeContent := string(readme)
	for _, required := range []string{
		"$env:CGO_ENABLED = '0'",
		"go install github.com/otrumb/winpathlint@v0.2.0",
		"winpathlint --repo (Get-Location).Path --format json",
	} {
		if !strings.Contains(readmeContent, required) {
			t.Errorf("README missing exact contract %q", required)
		}
	}
}

func TestREADME_exampleExecutesScanAndRemediation(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "winpathlint.exe")
	build := exec.Command("go", "build", "-trimpath", "-o", binary, ".")
	build.Env = append(os.Environ(), "CGO_ENABLED=0", "GIT_MASTER=1")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v: %s", err, output)
	}

	repo := gitFixture(t, []string{"NUL.txt"})
	output, code := runBuiltCLI(t, binary, repo)
	var findings []finding
	if err := json.Unmarshal(output, &findings); err != nil {
		t.Fatalf("findings JSON: %v; output %q", err, output)
	}
	want := []finding{{Path: "NUL.txt", Rule: "reserved_device_name", Component: "NUL.txt"}}
	if code != 1 || len(findings) != 1 || findings[0] != want[0] {
		t.Fatalf("code %d findings %#v; want code 1 and %#v", code, findings, want)
	}

	indexEntry := strings.Fields(runGitForTest(t, repo, "", "ls-files", "-s", "--", "NUL.txt"))
	if len(indexEntry) < 2 {
		t.Fatalf("unexpected index entry %q", indexEntry)
	}
	indexInfo := "0 0000000000000000000000000000000000000000\tNUL.txt\n100644 " + indexEntry[1] + "\tnul-report.txt\n"
	runGitForTest(t, repo, indexInfo, "-c", "core.protectNTFS=false", "-c", "core.ignoreCase=false", "update-index", "--index-info")

	output, code = runBuiltCLI(t, binary, repo)
	if code != 0 || string(output) != "[]\n" {
		t.Fatalf("code %d output %q; want code 0 and []", code, output)
	}
}

func TestREADME_CICommandsMatchExecutableContracts(t *testing.T) {
	workflow, err := os.ReadFile(filepath.Join(".github", "workflows", "ci.yml"))
	if err != nil {
		t.Fatal(err)
	}
	for _, command := range []string{
		"run: go test -shuffle=on -count=1 -cover ./...",
		"run: go vet ./...",
		"run: go build -trimpath -o winpathlint.exe .",
		"run: .\\winpathlint.exe --repo . --format json",
	} {
		if !strings.Contains(string(workflow), command) {
			t.Errorf("CI workflow missing exact command contract %q", command)
		}
	}
}

func runBuiltCLI(t *testing.T, binary, repo string) ([]byte, int) {
	t.Helper()
	command := exec.Command(binary, "--repo", repo, "--format", "json")
	command.Env = append(os.Environ(), "GIT_MASTER=1")
	output, err := command.CombinedOutput()
	if err == nil {
		return output, 0
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return output, exit.ExitCode()
	}
	t.Fatal(err)
	return nil, 0
}

func runGitForTest(t *testing.T, repo, input string, args ...string) string {
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
