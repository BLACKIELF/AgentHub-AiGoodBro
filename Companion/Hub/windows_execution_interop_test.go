//go:build windows_execution_integration

package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"reflect"
	"testing"
	"time"
)

const exactUnicodeOverrideBinding = "0e586fde194b059ded8b16f0bb183cc2d9871ffb5b7cfe219ffe238af7f437e1"

type windowsExecutionInteropCase struct {
	Name         string                     `json:"name"`
	Request      windowsExecutionRequest    `json:"request"`
	Authority    windowsExecutionAuthority  `json:"authority"`
	NowMS        int64                      `json:"nowMs"`
	Expected     *windowsEffectiveExecution `json:"expected"`
	ExpectedArgs []string                   `json:"expectedArgs"`
	Reject       bool                       `json:"reject"`
}

func TestWindowsExecutionRustPayload(t *testing.T) {
	path := os.Getenv("AIGB_WINDOWS_EXECUTION_FIXTURE")
	if path == "" {
		t.Fatal("AIGB_WINDOWS_EXECUTION_FIXTURE must point to Rust-generated JSON")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var document struct {
		Cases []windowsExecutionInteropCase `json:"cases"`
	}
	if err := decoder.Decode(&document); err != nil {
		t.Fatalf("invalid Rust-generated fixture: %v", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		t.Fatalf("fixture has trailing data: %v", err)
	}
	if len(document.Cases) != 4 {
		t.Fatalf("got %d Rust cases, want 4", len(document.Cases))
	}
	for _, tc := range document.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			if tc.Name == "exact_unicode_override_vector" {
				if tc.Request.BindingSHA256 != exactUnicodeOverrideBinding || tc.Expected == nil || tc.Expected.BindingSHA256 != exactUnicodeOverrideBinding {
					t.Fatalf("Rust exact-vector binding %q, want %q", tc.Request.BindingSHA256, exactUnicodeOverrideBinding)
				}
				if tc.Authority.ProfileID != 11 || tc.Authority.OfficialPlan != "plus" ||
					tc.Authority.Preference.DispatchCode == nil || *tc.Authority.Preference.DispatchCode != "C" ||
					!reflect.DeepEqual(tc.Authority.ExcludedPlanTypes, []string{"PRO", "企业"}) ||
					tc.Request.Overrides.Model == nil || *tc.Request.Overrides.Model != "gpt-5.5" ||
					tc.Request.Overrides.Effort == nil || *tc.Request.Overrides.Effort != "xhigh" ||
					tc.Request.Overrides.ServiceTier == nil || *tc.Request.Overrides.ServiceTier != "fast" {
					t.Fatalf("Rust exact-vector inputs changed: %#v", tc)
				}
			}
			got, err := resolveWindowsExecution(tc.Request, tc.Authority, time.UnixMilli(tc.NowMS))
			if tc.Reject {
				if err == nil {
					t.Fatal("stale Rust binding accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if tc.Expected == nil || !reflect.DeepEqual(got, *tc.Expected) {
				t.Fatalf("effective execution %#v, want %#v", got, tc.Expected)
			}
			if args := got.codexArguments(); !reflect.DeepEqual(args, tc.ExpectedArgs) {
				t.Fatalf("final arguments %q, want %q", args, tc.ExpectedArgs)
			}
		})
	}
}
