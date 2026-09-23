package main

import (
	"reflect"
	"testing"
)

func TestScan_whenClean(t *testing.T) {
	paths := []string{"src/main.go", "company.txt", "COM0", "LPT10", "a/b", "a/c"}
	got := scan(paths, 240)
	if len(got) != 0 {
		t.Fatalf("findings = %#v", got)
	}
}

func TestScan_whenReservedComponent(t *testing.T) {
	for _, component := range []string{"CON", "con.txt", "PRN.tar.gz", "AUX", "NUL", "COM1", "com9.log", "LPT1", "lpt9.txt", "COM\u00b9", "LPT\u00b2", "COM\u00b3", "CON .txt"} {
		t.Run(component, func(t *testing.T) {
			path := "ok/" + component + "/file"
			got := scan([]string{path}, 240)
			want := []finding{{Path: path, Rule: "reserved_device_name", Component: component}}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("got %#v; want %#v", got, want)
			}
		})
	}
}

func TestScan_whenIllegalCharacter(t *testing.T) {
	for _, character := range `<>:\"|?*` {
		component := "a" + string(character) + "b"
		path := "src/" + component + "/file"
		got := scan([]string{path}, 240)
		want := []finding{{Path: path, Rule: "illegal_character", Component: component}}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("got %#v; want %#v", got, want)
		}
	}
}

func TestScan_whenTrailingDotOrSpace(t *testing.T) {
	for _, component := range []string{"dir.", "dir ", "file. "} {
		path := component + "/file"
		got := scan([]string{path}, 240)
		want := []finding{{Path: path, Rule: "trailing_dot_or_space", Component: component}}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("got %#v; want %#v", got, want)
		}
	}
}

func TestScan_whenControlCharacter(t *testing.T) {
	for character := rune(1); character < 32; character++ {
		component := "a" + string(character) + "b"
		path := component + "/file"
		got := scan([]string{path}, 240)
		want := []finding{{Path: path, Rule: "control_character", Component: component}}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("got %#v; want %#v", got, want)
		}
	}
}

func TestScan_whenPathLengthExceedsUTF16Budget(t *testing.T) {
	for _, path := range []string{"abcde", "a/abc", "a\U0001f600bc"} {
		got := scan([]string{path}, 4)
		want := []finding{{Path: path, Rule: "path_too_long"}}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("got %#v; want %#v", got, want)
		}
	}
}

func TestScan_whenPathLengthEqualsBudget(t *testing.T) {
	got := scan([]string{"abcd", "a\U0001f600b"}, 4)
	if len(got) != 0 {
		t.Fatalf("findings = %#v", got)
	}
}

func TestScan_whenCaseCollides(t *testing.T) {
	for _, paths := range [][]string{{"foo", "Foo"}, {"foo/b", "Foo/a"}, {"foo/b", "Foo"}} {
		got := scan(paths, 240)
		want := []finding{{Path: paths[0], Rule: "case_collision", Component: "foo", Related: paths[1]}}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("got %#v; want %#v", got, want)
		}
	}
}

func TestScan_whenInputUnsortedAndDuplicated(t *testing.T) {
	paths := []string{"z?", "NUL.", "z?"}
	got := scan(paths, 240)
	want := []finding{
		{Path: "NUL.", Rule: "reserved_device_name", Component: "NUL."},
		{Path: "NUL.", Rule: "trailing_dot_or_space", Component: "NUL."},
		{Path: "z?", Rule: "illegal_character", Component: "z?"},
	}
	if !reflect.DeepEqual(got, want) || paths[0] != "z?" {
		t.Fatalf("got %#v; want %#v; input %#v", got, want, paths)
	}
}
