package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestCompatibilityCorpusTextFilesUseLFOnCheckout(t *testing.T) {
	paths, err := filepath.Glob("compatibility/*.txt")
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		path = filepath.ToSlash(path)
		command := exec.Command("git", "check-attr", "eol", "--", path)
		command.Env = append(os.Environ(), "GIT_MASTER=1")
		output, err := command.CombinedOutput()
		want := path + ": eol: lf\n"
		if err != nil || string(output) != want {
			t.Fatalf("checkout policy for %s: %q, %v; want eol=lf", path, output, err)
		}
	}
}

type compatibilityManifest struct {
	SchemaVersion int `json:"schema_version"`
	Repositories  []struct {
		Repository    string   `json:"repository"`
		SHA           string   `json:"sha"`
		ExpectedPaths []string `json:"expected_paths"`
	} `json:"repositories"`
}

type compatibilityResults struct {
	SchemaVersion int `json:"schema_version"`
	Method        struct {
		ScanEvents             int  `json:"scan_events"`
		EligibleRepositories   int  `json:"eligible_repositories"`
		ScannedRepositories    int  `json:"scanned_repositories"`
		RejectedCandidateScans int  `json:"rejected_candidate_scans"`
		Deterministic          bool `json:"deterministic"`
		ReleaseMainEqual       bool `json:"release_main_equal"`
		Unchanged              bool `json:"index_and_path_streams_unchanged"`
	} `json:"method"`
	Adjudication struct {
		TruePositives  int `json:"true_positives"`
		FalsePositives int `json:"false_positives"`
		Misses         int `json:"misses"`
		Unresolved     int `json:"unresolved"`
	} `json:"adjudication"`
	Repositories []struct {
		Repository string `json:"repository"`
		SHA        string `json:"sha"`
		Over240    int    `json:"over_240"`
		Findings   []struct {
			Path           string `json:"path"`
			Related        string `json:"related"`
			Rule           string `json:"rule"`
			Classification string `json:"classification"`
		} `json:"findings"`
	} `json:"repositories"`
}

func TestCompatibilityCorpusContract(t *testing.T) {
	manifestData, err := os.ReadFile("compatibility/repositories.json")
	if err != nil {
		t.Fatal(err)
	}
	resultsData, err := os.ReadFile("compatibility/results.json")
	if err != nil {
		t.Fatal(err)
	}
	var manifest compatibilityManifest
	var results compatibilityResults
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(resultsData, &results); err != nil {
		t.Fatal(err)
	}
	if manifest.SchemaVersion != 1 || results.SchemaVersion != 1 || len(manifest.Repositories) != 10 || len(results.Repositories) != 10 {
		t.Fatalf("schema/repository count: manifest %d/%d results %d/%d", manifest.SchemaVersion, len(manifest.Repositories), results.SchemaVersion, len(results.Repositories))
	}
	manifestIDs := make([]string, 0, 10)
	resultIDs := make([]string, 0, 10)
	witnessRepositories := 0
	findings := 0
	for _, repository := range manifest.Repositories {
		manifestIDs = append(manifestIDs, repository.Repository+"@"+repository.SHA)
		if len(repository.ExpectedPaths) > 0 {
			witnessRepositories++
			if repository.Repository != "NousResearch/hermes-agent" || len(repository.ExpectedPaths) != 2 {
				t.Fatalf("unexpected witness contract: %#v", repository)
			}
		}
	}
	for _, repository := range results.Repositories {
		resultIDs = append(resultIDs, repository.Repository+"@"+repository.SHA)
		if repository.Over240 != 0 {
			t.Errorf("%s has over-240 paths", repository.Repository)
		}
		for _, finding := range repository.Findings {
			findings++
			if repository.Repository != "NousResearch/hermes-agent" || finding.Rule != "case_collision" || finding.Classification != "true_positive" ||
				finding.Path != "contributors/emails/agent@agents-Mac-mini.local" || finding.Related != "contributors/emails/agent@Agents-Mac-mini.local" {
				t.Fatalf("unexpected finding: %#v", finding)
			}
		}
	}
	sort.Strings(manifestIDs)
	sort.Strings(resultIDs)
	method := results.Method
	adjudication := results.Adjudication
	if !reflect.DeepEqual(manifestIDs, resultIDs) || witnessRepositories != 1 || findings != 1 || method.ScanEvents != 60 || method.EligibleRepositories != 10 ||
		method.ScannedRepositories != 10 || method.RejectedCandidateScans != 0 || !method.Deterministic || !method.ReleaseMainEqual || !method.Unchanged ||
		adjudication.TruePositives != 1 || adjudication.FalsePositives != 0 || adjudication.Misses != 0 || adjudication.Unresolved != 0 {
		t.Fatalf("corpus contract mismatch: method %#v adjudication %#v", method, adjudication)
	}
	if strings.Contains(string(resultsData), `C:\`) || strings.Contains(string(resultsData), `/repos/`) {
		t.Fatal("published results contain local paths")
	}
	schema, err := os.ReadFile("compatibility/schema-version.txt")
	if err != nil || string(schema) != "1\n" {
		t.Fatalf("schema marker: %q, %v", schema, err)
	}
}
