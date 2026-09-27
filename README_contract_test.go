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
	content := strings.ToLower(string(readme))
	for _, required := range []string{
		"go install github.com/otrumb/winpathlint@v0.2.0",
		"--repo (get-location).path",
		"$LASTEXITCODE",
		"reserved_device_name",
		"exit 1",
		"exit 0",
	} {
		if !strings.Contains(content, strings.ToLower(required)) {
			t.Errorf("README missing contract %q", required)
		}
	}
}
