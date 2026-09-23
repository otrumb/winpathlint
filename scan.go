package main

import (
	"cmp"
	"slices"
	"strings"
	"unicode/utf16"
)

type finding struct {
	Path      string `json:"path"`
	Rule      string `json:"rule"`
	Component string `json:"component,omitempty"`
	Related   string `json:"related,omitempty"`
}

func scan(paths []string, maxPath int) []finding {
	findings := make([]finding, 0)
	ordered := slices.Clone(paths)
	slices.Sort(ordered)
	seen := make(map[string]struct{ prefix, path string })
	for _, path := range slices.Compact(ordered) {
		if len(utf16.Encode([]rune(path))) > maxPath {
			findings = append(findings, finding{Path: path, Rule: "path_too_long"})
		}
		prefix := ""
		for _, component := range strings.Split(path, "/") {
			prefix += component
			key := strings.ToUpper(prefix)
			if first, exists := seen[key]; exists && first.prefix != prefix {
				findings = append(findings, finding{Path: path, Rule: "case_collision", Component: prefix, Related: first.path})
			} else if !exists {
				seen[key] = struct{ prefix, path string }{prefix, path}
			}
			prefix += "/"
			if strings.IndexFunc(component, func(character rune) bool { return character < 32 }) >= 0 {
				findings = append(findings, finding{Path: path, Rule: "control_character", Component: component})
			}
			if strings.HasSuffix(component, ".") || strings.HasSuffix(component, " ") {
				findings = append(findings, finding{Path: path, Rule: "trailing_dot_or_space", Component: component})
			}
			if strings.ContainsAny(component, `<>:\"|?*`) {
				findings = append(findings, finding{Path: path, Rule: "illegal_character", Component: component})
			}
			base, _, _ := strings.Cut(component, ".")
			base = strings.ToUpper(strings.TrimRight(base, " "))
			reserved := base == "CON" || base == "PRN" || base == "AUX" || base == "NUL"
			if strings.HasPrefix(base, "COM") || strings.HasPrefix(base, "LPT") {
				reserved = strings.Contains("|1|2|3|4|5|6|7|8|9|\u00b9|\u00b2|\u00b3|", "|"+base[3:]+"|")
			}
			if reserved {
				findings = append(findings, finding{Path: path, Rule: "reserved_device_name", Component: component})
			}
		}
	}
	slices.SortFunc(findings, func(left, right finding) int {
		return cmp.Or(cmp.Compare(left.Path, right.Path), cmp.Compare(left.Rule, right.Rule), cmp.Compare(left.Component, right.Component), cmp.Compare(left.Related, right.Related))
	})
	return slices.Compact(findings)
}
