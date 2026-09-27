package main

import (
	"os"
	"strings"
	"testing"
)

func TestREADME_containsQuickstartAndCIExampleContracts(t *testing.T) {
	readme, err := os.ReadFile("README.md")
	if err != nil {
		t.Fatal(err)
	}
	readmeContent := string(readme)
	for _, required := range []string{
		"$env:CGO_ENABLED = '0'",
		"go install github.com/otrumb/winpathlint@v0.2.0",
		"winpathlint --repo (Get-Location).Path --format json",
		"NUL.txt",
		"nul-report.txt",
		".github/workflows/ci.yml",
	} {
		if !strings.Contains(readmeContent, required) {
			t.Errorf("README missing exact contract %q", required)
		}
	}

	workflow, err := os.ReadFile(".github/workflows/ci.yml")
	if err != nil {
		t.Fatal(err)
	}
	workflowContent := string(workflow)
	for _, required := range []string{
		"run: go test -shuffle=on -count=1 -cover ./...",
		"run: go vet ./...",
		"run: go build -trimpath -o winpathlint.exe .",
		"run: .\\winpathlint.exe --repo . --format json",
	} {
		if !strings.Contains(workflowContent, required) {
			t.Errorf("CI workflow missing exact contract %q", required)
		}
	}
}
