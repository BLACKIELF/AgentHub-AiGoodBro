package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestModelSnapshotPayloadBudget(t *testing.T) {
	fraction, reset, span := 0.5, int64(1_893_456_000), int64(18_000)
	makeAccount := func(count, idLength int, maximal bool) accountView {
		c := testCredential("a")
		row := accountView{ID: c.AccountID, Provider: c.Provider, Generation: c.Generation,
			MaskedIdentity: c.MaskedIdentity, Enabled: true, ConcurrencyLimit: 1, State: "ready",
			ModelDetailsUpdatedAt: 1_794_182_400}
		for i := 0; i < count; i++ {
			id := fmt.Sprintf("fixture-model-%04d", i)
			id += strings.Repeat("x", idLength-len(id))
			name := "Fixture Model " + fmt.Sprint(i)
			if maximal {
				name = strings.Repeat("<", 160) // legal labels with JSON's largest escaping expansion
			}
			row.Models = append(row.Models, id)
			row.ModelDetails = append(row.ModelDetails, modelDetail{ID: id, DisplayName: name, RemainingFraction: &fraction, ResetAt: &reset})
		}
		windowCount := 3
		if maximal {
			windowCount = 256
		}
		for i := 0; i < windowCount; i++ {
			label, pool := "5 hours", "Fixture Shared Pool"
			if maximal {
				label, pool = strings.Repeat("<", 160), strings.Repeat("<", 160)
			}
			row.SharedWindows = append(row.SharedWindows, quotaWindow{ID: fmt.Sprintf("summary-%03d", i),
				Pool: pool, Label: label, RemainingFraction: &fraction, ResetAt: &reset,
				WindowSeconds: &span, ModelIDs: row.Models})
		}
		return row
	}
	for _, count := range []int{32, 64, 128, 512} {
		row := makeAccount(count, 32, false)
		rows := make([]accountView, 100)
		for i := range rows {
			rows[i] = row
			rows[i].ID = fmt.Sprintf("ag-%032x", i+1)
		}
		var output bytes.Buffer
		if err := (&events{out: &output}).emit(event{Event: "snapshot", Accounts: rows, Models: row.Models,
			ProviderModels: map[string][]string{"antigravity": row.Models}}); err != nil {
			t.Fatal(err)
		}
		var decoded event
		if json.Unmarshal(output.Bytes(), &decoded) != nil || len(decoded.Accounts) != 100 || len(decoded.Accounts[99].ModelDetails) != count {
			t.Fatal("model snapshot was truncated")
		}
		if output.Len()-1 > maxSnapshotBytes {
			t.Fatal("100-account common catalog exceeded joint snapshot budget")
		}
		t.Logf("100 accounts x %d models, 3 shared windows: %d bytes (snapshot limit %d)", count, output.Len(), maxSnapshotBytes)
	}
	maximal := makeAccount(512, 128, true)
	encoded, err := json.Marshal(maximal)
	if err != nil {
		t.Fatal(err)
	}
	// Measure one record instead of materializing a gigabyte aggregate.
	t.Logf("one maximum-schema account: %d bytes; 100 account bodies alone: %d bytes", len(encoded), 100*len(encoded)+99)
	var rejected bytes.Buffer
	if err := (&events{out: &rejected}).emit(event{Event: "snapshot", Accounts: []accountView{maximal, maximal}}); !errors.Is(err, errSnapshotTooLarge) {
		t.Fatal("oversized aggregate did not fail closed")
	}
	if rejected.String() != "{\"event\":\"error\",\"code\":\"snapshot_too_large\"}\n" {
		t.Fatal("oversized snapshot partially reached the native host")
	}
	rejected.Reset()
	if err := (&events{out: &rejected}).emit(event{Event: "open_browser", URL: strings.Repeat("x", maxIPCBytes)}); err == nil || rejected.Len() != 0 {
		t.Fatal("snapshot allowance widened control/credential frame budget")
	}
}

func TestAntigravityCatalogPreservesQuotaWithoutChangingAdmission(t *testing.T) {
	now := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	data := []byte(`{"models":{
		"available":{"displayName":"Gemini fixture","quotaInfo":{"remainingFraction":0.65,"resetTime":"2030-01-01T00:00:00Z"}},
		"exhausted":{"quotaInfo":{"remainingFraction":0}},
		"expired":{"quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-01-01T00:00:00Z"}},
		"bad-fraction":{"quotaInfo":{"remainingFraction":2}},
		"bad-type":{"quotaInfo":{"remainingFraction":"0.5"}},
		"bad-reset":{"quotaInfo":{"remainingFraction":0.5,"resetTime":"invalid"}},
		"bad-label":{"displayName":"invalid\nname"},
		"disabled":{"disabled":true,"quotaInfo":{"remainingFraction":0.8}},
		"unknown":{},"bad/id":{}},
		"agentModelSorts":[{"groups":[{"modelIds":["unknown","available","unknown"]}]}]}`)
	got, err := antigravityCatalog(data, now)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got.Models, []string{"available", "bad-label", "unknown"}) {
		t.Fatal("quota admission changed", got.Models)
	}
	if len(got.Details) != 9 || got.Details[0].ID != "unknown" || got.Details[1].ID != "available" {
		t.Fatal("lost real models or upstream picker order")
	}
	rows := map[string]modelDetail{}
	for _, row := range got.Details {
		rows[row.ID] = row
	}
	if rows["available"].DisplayName != "Gemini fixture" || rows["available"].RemainingFraction == nil || *rows["available"].RemainingFraction != 0.65 || rows["available"].ResetAt == nil {
		t.Fatal("valid observation lost")
	}
	if rows["exhausted"].RemainingFraction == nil || *rows["exhausted"].RemainingFraction != 0 {
		t.Fatal("known zero became unknown")
	}
	if rows["disabled"].Disabled == nil || !*rows["disabled"].Disabled || *rows["disabled"].RemainingFraction != 0.8 {
		t.Fatal("disabled was confused with exhaustion")
	}
	for _, id := range []string{"expired", "bad-fraction", "bad-type", "bad-reset", "unknown"} {
		if rows[id].RemainingFraction != nil {
			t.Fatalf("%s invented a percentage", id)
		}
	}
	if rows["expired"].ResetAt == nil || rows["bad-label"].DisplayName != "bad-label" {
		t.Fatal("expiry provenance or safe fallback lost")
	}
}

func TestQuotaSummaryKeepsIndependentWindowsAndUnknown(t *testing.T) {
	now := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	rows, err := parseQuotaSummary([]byte(`{"groups":[{"displayName":"Gemini Models","buckets":[
		{"bucketId":"g5","window":"5h","displayName":"5 hours","remainingFraction":0.7,"resetTime":"2030-01-01T00:00:00Z"},
		{"bucketId":"gw","window":"weekly","remainingFraction":0},
		{"bucketId":"missing","window":"weekly"},
		{"bucketId":"invalid","window":"weekly","remainingFraction":2},
		{"bucketId":"wrong-type","window":"weekly","remainingFraction":"0.7"},
		{"bucketId":"disabled","window":"weekly","disabled":true,"remainingFraction":0.8},
		{"bucketId":"expired","window":"weekly","remainingFraction":0.8,"resetTime":"2020-01-01T00:00:00Z"}]},
		{"displayName":"Gemini fixture own pool","buckets":[{"bucketId":"own","window":"weekly","remainingFraction":0.5}]}]}`), now)
	if err != nil || len(rows) != 7 {
		t.Fatal("summary windows missing", err, len(rows))
	}
	if *rows[0].WindowSeconds != 18000 || *rows[1].WindowSeconds != 604800 || *rows[1].RemainingFraction != 0 {
		t.Fatal("shared windows conflated")
	}
	for _, index := range []int{2, 3, 4, 5} {
		if rows[index].RemainingFraction != nil {
			t.Fatal("unknown or expired summary invented percentage")
		}
	}
	for _, row := range rows {
		if len(row.ModelIDs) != 0 {
			t.Fatal("model membership inferred from family name")
		}
	}
	if rows[6].Pool != "Gemini fixture own pool" || *rows[6].WindowSeconds != 604800 {
		t.Fatal("week-only independent pool lost")
	}
	if _, err := parseQuotaSummary([]byte(`{"groups":[{"displayName":"Pool","buckets":[{"window":"5h"},{"window":"5h"}]}]}`), now); err == nil {
		t.Fatal("ambiguous duplicate accepted")
	}
}

func TestAntigravityPoolMembershipUsesSpecificNamesAndMatchingFiveHourEvidence(t *testing.T) {
	now := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	rows, err := parseQuotaSummary([]byte(`{"groups":[
		{"displayName":"Gemini Models","description":"Models within this group: Gemini Pro, Gemini Flash","buckets":[{"bucketId":"g5","window":"5h","remainingFraction":0.8,"resetTime":"2026-11-09T04:00:00Z"},{"bucketId":"gw","window":"weekly","remainingFraction":0.7}]},
		{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"own","window":"weekly","remainingFraction":0.4}]},
		{"displayName":"Claude and GPT models","buckets":[{"bucketId":"cw","window":"weekly","remainingFraction":0.8}]}
	]}`), now)
	if err != nil {
		t.Fatal(err)
	}
	fraction, other := 0.8, 0.6
	reset := now.Add(4 * time.Hour).Unix()
	differentReset := reset + 61
	models := []modelDetail{
		{ID: "gemini-pro", DisplayName: "Gemini Pro", RemainingFraction: &fraction, ResetAt: &reset},
		{ID: "gemini-4-argon-high", DisplayName: "Gemini 4 Argon (High)", RemainingFraction: &fraction, ResetAt: &reset},
		{ID: "gemini-other", DisplayName: "Gemini Other", RemainingFraction: &other, ResetAt: &reset},
		{ID: "gemini-reset", DisplayName: "Gemini Reset", RemainingFraction: &fraction, ResetAt: &differentReset},
		{ID: "gemini-unknown", DisplayName: "Gemini Unknown"},
		{ID: "claude-sonnet", DisplayName: "Claude Sonnet", RemainingFraction: &fraction, ResetAt: &reset},
	}
	associateAntigravityPools(models, rows)
	if !reflect.DeepEqual(rows[0].ModelIDs, []string{"gemini-pro"}) || !reflect.DeepEqual(rows[1].ModelIDs, []string{"gemini-pro"}) {
		t.Fatal("family pool absorbed mismatched/unknown/model-specific quota")
	}
	if !reflect.DeepEqual(rows[2].ModelIDs, []string{"gemini-4-argon-high"}) || rows[3].ModelIDs != nil || rows[3].Pool != "Claude & GPT" {
		t.Fatal("specific/week-only grouping changed")
	}
	// Reversing server group order must not make the family claim Argon.
	for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
		rows[i], rows[j] = rows[j], rows[i]
	}
	for i := range rows {
		rows[i].ModelIDs = nil
	}
	associateAntigravityPools(models, rows)
	for _, row := range rows {
		if row.Pool == "Gemini" && !reflect.DeepEqual(row.ModelIDs, []string{"gemini-pro"}) {
			t.Fatal("server order changed pool membership")
		}
	}
}

func TestAntigravityCatalogReadsExactlyOneCatalogAndOneSummary(t *testing.T) {
	for _, summaryStatus := range []int{200, 403, 429, 503} {
		t.Run(http.StatusText(summaryStatus), func(t *testing.T) {
			calls := []string{}
			b := newBackend("")
			b.client.Transport = googleTransport{base: adapterRoundTrip(func(r *http.Request) (*http.Response, error) {
				calls = append(calls, r.URL.Path)
				if r.Method != "POST" || r.URL.Hostname() != "daily-cloudcode-pa.googleapis.com" || r.Header.Get("Authorization") != "Bearer synthetic-access" {
					t.Fatal("changed credential or transport boundary")
				}
				data, _ := io.ReadAll(r.Body)
				var body map[string]string
				if json.Unmarshal(data, &body) != nil || !reflect.DeepEqual(body, map[string]string{"project": "synthetic-project"}) {
					t.Fatal("unreviewed request body")
				}
				switch r.URL.Path {
				case "/v1internal:fetchAvailableModels":
					return adapterResponse(200, `{"models":{"fixture-model":{"quotaInfo":{"remainingFraction":0.4}},"empty":{"quotaInfo":{"remainingFraction":0}}}}`), nil
				case "/v1internal:retrieveUserQuotaSummary":
					return adapterResponse(summaryStatus, `{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":0.4}]}]}`), nil
				default:
					t.Fatal("unexpected request")
					return nil, errors.New("unexpected")
				}
			})}
			result, err := readModelCatalog(context.Background(), b, testCredential("a"))
			if err != nil || len(calls) != 2 || !reflect.DeepEqual(result.Models, []string{testModel}) || len(result.Details) != 2 {
				t.Fatal("summary failure affected catalog", err, calls)
			}
			if summaryStatus == 200 {
				if len(result.SharedWindows) != 1 || result.QuotaIssue != "" {
					t.Fatal("summary lost")
				}
			} else if result.SharedWindows != nil || result.QuotaIssue != "summary_unavailable" {
				t.Fatal("failed summary retained usable quota")
			}
		})
	}
}

func TestKimiQuotaRejectsAmbiguousCounterWindows(t *testing.T) {
	now := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		name string
		body string
	}{
		{"two-short-windows", `{"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":100,"remaining":10}},{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":100,"remaining":90}}]}`},
		{"two-weekly-windows", `{"limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_WEEK"},"detail":{"limit":100,"remaining":10}},{"window":{"duration":7,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":100,"remaining":90}}]}`},
		{"weekly-usage-and-limit", `{"usage":{"limit":100,"remaining":10},"limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_WEEK"},"detail":{"limit":100,"remaining":90}}]}`},
		{"shares-cannot-disambiguate-two-counters", `{"limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_WEEK"},"detail":{"limit":100,"remaining":10}},{"window":{"duration":1,"timeUnit":"TIME_UNIT_WEEK"},"detail":{"limit":100,"remaining":90}}],"usages":{"limit_7d":{"used_ratio":0.5}}}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			rows, err := parseKimiQuota([]byte(test.body), now)
			if err == nil || err.Error() != "duplicate_quota_window" || rows != nil {
				t.Fatal("ambiguous counters silently replaced another allowance")
			}
		})
	}
	for _, ratio := range []string{`0.2`, `"invalid"`} {
		rows, err := parseKimiQuota([]byte(`{"usage":{"limit":100,"remaining":10},"usages":{"limit_7d":{"used_ratio":`+ratio+`}}}`), now)
		if err != nil || len(rows) != 1 || rows[0].ID != "kimi-weekly" {
			t.Fatal("the documented share-over-counter precedence changed", err)
		}
		if ratio == `0.2` {
			if rows[0].RemainingFraction == nil || *rows[0].RemainingFraction != 0.8 {
				t.Fatal("the current share did not replace the legacy counter")
			}
		} else if rows[0].RemainingFraction != nil {
			t.Fatal("an unknown current share reused a legacy balance")
		}
	}
}

func TestKimiQuotaRejectsEmptyGeneralUsage(t *testing.T) {
	now := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	rows, err := parseKimiQuota([]byte(`{"usage":{}}`), now)
	if err == nil || err.Error() != "invalid_quota_summary" || rows != nil {
		t.Fatal("an empty general usage object invented a measured window")
	}
	rows, err = parseKimiQuota([]byte(`{"usage":{},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{}}]}`), now)
	if err != nil || len(rows) != 1 || rows[0].ID != "kimi-session" || rows[0].RemainingFraction != nil || rows[0].WindowSeconds == nil || *rows[0].WindowSeconds != 18000 {
		t.Fatal("an explicit window with an unknown counter was lost", err)
	}
	rows, err = parseKimiQuota([]byte(`{"usage":{"limit":100,"remaining":0,"resetTime":"2030-01-01T00:00:00Z"}}`), now)
	if err != nil || len(rows) != 1 || rows[0].RemainingFraction == nil || *rows[0].RemainingFraction != 0 {
		t.Fatal("a measured zero was confused with an empty object", err)
	}
}

func TestKimiQuotaShapesAndMissingRatios(t *testing.T) {
	now := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	rows, err := parseKimiQuota([]byte(`{"usage":{"limit":"100","used":"12","resetTime":"2030-01-01T00:00:00Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"200","remaining":"88"}}]}`), now)
	if err != nil || len(rows) != 2 {
		t.Fatal(err)
	}
	if *rows[0].RemainingAmount != 88 || *rows[0].TotalAmount != 200 || *rows[1].RemainingFraction != 0.88 {
		t.Fatal("counter quota changed")
	}
	rows, err = parseKimiQuota([]byte(`{"usages":{"limit_5h":{"used_ratio":0.4,"reset_time":1893456000000},"limit_7d":{"usedRatio":0},"limit_month_total":{},"limit_month_code":{"used_ratio":1.2}}}`), now)
	if err != nil || len(rows) != 4 {
		t.Fatal("independent monthly windows lost", err)
	}
	byID := map[string]quotaWindow{}
	for _, row := range rows {
		byID[row.ID] = row
	}
	if byID["kimi-monthly"].RemainingFraction != nil || *byID["kimi-monthly-code"].RemainingFraction != 0 || *byID["kimi-session"].RemainingFraction != 0.6 || *byID["kimi-session"].ResetAt != 1893456000 {
		t.Fatal("ratio/reset normalization failed")
	}
	rows, err = parseKimiQuota([]byte(`{"usage":{"limit":"NaN","used":0}}`), now)
	if err != nil || len(rows) != 1 || rows[0].RemainingFraction != nil {
		t.Fatal("nonfinite count was accepted or its window identity lost")
	}
}

func TestExplicitInvalidResetsRemainUnknown(t *testing.T) {
	now := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	for _, raw := range []string{`"invalid"`, `-1`, `true`, `0`, `1e40`, `{}`} {
		for _, body := range []string{
			`{"usage":{"limit":100,"used":20,"resetTime":` + raw + `}}`,
			`{"usages":{"limit_5h":{"used_ratio":0.2,"reset_time":` + raw + `}}}`,
		} {
			rows, err := parseKimiQuota([]byte(body), now)
			if err != nil || len(rows) != 1 || rows[0].RemainingFraction != nil || rows[0].RemainingAmount != nil {
				t.Fatal("invalid Kimi reset looked current")
			}
		}
		rows, err := parseGrokQuota([]byte(`{"config":{"creditUsagePercent":20,"currentPeriod":{"end":`+raw+`},"onDemandCap":{"val":100},"onDemandUsed":{"val":20}}}`), now)
		if err != nil || len(rows) != 2 || rows[0].RemainingFraction != nil || rows[1].RemainingFraction != nil {
			t.Fatal("invalid Grok reset looked current")
		}
	}
	rows, err := parseKimiQuota([]byte(`{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{}}]}`), now)
	if err != nil || len(rows) != 1 || rows[0].RemainingFraction != nil || *rows[0].WindowSeconds != 18000 {
		t.Fatal("known window with unknown quota disappeared")
	}
}

func TestGrokSharedQuotaDoesNotInventMissingAllowance(t *testing.T) {
	now := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		body  string
		known bool
		count int
	}{
		{`{"config":{"creditUsagePercent":25,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2030-01-01T00:00:00Z"},"onDemandCap":{"val":100},"onDemandUsed":{"val":30}}}`, true, 2},
		{`{"config":{}}`, false, 1},
		{`{"config":{"creditUsagePercent":101}}`, false, 1},
		{`{"config":{"creditUsagePercent":false}}`, false, 1},
		{`{"config":{"creditUsagePercent":0,"billingPeriodEnd":"2020-01-01T00:00:00Z"}}`, false, 1},
	} {
		rows, err := parseGrokQuota([]byte(test.body), now)
		if err != nil || len(rows) != test.count || (rows[0].RemainingFraction != nil) != test.known {
			t.Fatal("grok quota shape changed", err)
		}
		if test.known && (*rows[0].RemainingFraction != 0.75 || *rows[1].RemainingFraction != 0.7) {
			t.Fatal("subscription/on-demand mixed")
		}
	}
}

func TestGrokOnDemandProto3ZeroValue(t *testing.T) {
	now := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		name  string
		used  string
		known bool
		left  float64
	}{
		{"present-empty-cent", `{}`, true, 1},
		{"explicit-zero", `{"val":0}`, true, 1},
		{"encoded-int64-zero", `{"val":"0"}`, true, 1},
		{"known-used", `{"val":30}`, true, 0.7},
		{"over-cap", `{"val":140}`, true, 0},
		{"missing-object", ``, false, 0},
		{"null-object", `null`, false, 0},
		{"scalar-object", `0`, false, 0},
		{"array-object", `[]`, false, 0},
		{"null-value", `{"val":null}`, false, 0},
		{"boolean-value", `{"val":false}`, false, 0},
		{"invalid-value", `{"val":"unknown"}`, false, 0},
		{"negative-value", `{"val":-1}`, false, 0},
		{"fractional-value", `{"val":0.5}`, false, 0},
		{"fractional-string-value", `{"val":"0.5"}`, false, 0},
		{"out-of-range-value", `{"val":1e40}`, false, 0},
		{"unrecognized-field", `{"other":0}`, false, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			used := ""
			if test.used != "" {
				used = `,"onDemandUsed":` + test.used
			}
			rows, err := parseGrokQuota([]byte(`{"config":{"creditUsagePercent":25,"onDemandCap":{"val":100}`+used+`}}`), now)
			if err != nil || len(rows) != 2 || rows[0].RemainingFraction == nil || *rows[0].RemainingFraction != 0.75 {
				t.Fatal("on-demand decoding changed subscription quota", err)
			}
			if (rows[1].RemainingFraction != nil) != test.known || (test.known && *rows[1].RemainingFraction != test.left) {
				t.Fatal("a present proto3 zero, missing object, or invalid value was misread")
			}
			if rows[1].RemainingAmount != nil || rows[1].TotalAmount != nil || rows[1].Unit != "" {
				t.Fatal("on-demand decoding invented absolute amounts or units")
			}
		})
	}
}

func TestKimiAndGrokQuotaUseExistingCredentialAndFailIndependently(t *testing.T) {
	for _, name := range []string{"kimi", "xai"} {
		for _, status := range []int{200, 401, 429, 503} {
			t.Run(name+"/"+http.StatusText(status), func(t *testing.T) {
				var b authBackend
				var h *oauthHTTP
				if name == "kimi" {
					v := newKimiBackend("").(*kimiBackend)
					b, h = v, v.http
				} else {
					v := newXAIBackend("").(*xaiBackend)
					b, h = v, v.http
				}
				c := testCredential("a")
				c.Provider = name
				c.AccountSubject = "fixture-subject"
				c.AccountID = providerAccountID(name, c.AccountSubject)
				calls := 0
				stub := adapterRoundTrip(func(r *http.Request) (*http.Response, error) {
					calls++
					if r.Method != "GET" || r.Header.Get("Authorization") != "Bearer synthetic-access" {
						t.Fatal("quota uses a different credential or mutation method")
					}
					if strings.HasSuffix(r.URL.Path, "/models") {
						return adapterResponse(200, `{"data":[{"id":"fixture-model"}]}`), nil
					}
					if name == "kimi" && r.URL.String() == "https://api.kimi.com/coding/v1/usages" {
						return adapterResponse(status, `{"usage":{"limit":100,"used":40}}`), nil
					}
					if name == "xai" && r.URL.String() == "https://cli-chat-proxy.grok.com/v1/billing?format=credits" {
						return adapterResponse(status, `{"config":{"creditUsagePercent":40}}`), nil
					}
					t.Fatal("unreviewed quota endpoint")
					return nil, errors.New("unexpected")
				})
				h.client.Transport = offlineSDKTransport(t, h.transport, stub)
				result, err := readModelCatalog(context.Background(), b, c)
				if err != nil || calls != 2 || len(result.Models) != 1 || len(result.Details) != 1 || result.Details[0].RemainingFraction != nil {
					t.Fatal("quota changed catalog or invented per-model allowance", err, calls)
				}
				if status == 200 {
					if len(result.SharedWindows) != 1 || result.QuotaIssue != "" {
						t.Fatal("shared quota missing")
					}
				} else if result.QuotaIssue != "summary_unavailable" || len(result.SharedWindows) != 0 {
					t.Fatal("quota failure leaked stale windows")
				}
			})
		}
	}
}

type fixtureCatalogBackend struct {
	*fakeBackend
	result    modelCatalog
	err       error
	catalogFn func(context.Context, credential) (modelCatalog, error)
}

func (b *fixtureCatalogBackend) catalog(ctx context.Context, c credential) (modelCatalog, error) {
	if b.catalogFn != nil {
		return b.catalogFn(ctx, c)
	}
	return b.result, b.err
}

func TestModelDetailsStayBoundToAccountAndNeverOpenAdmission(t *testing.T) {
	now := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	zero, remaining := 0.0, 0.7
	c := testCredential("a")
	c.ExpiresAt = time.Now().Add(time.Hour).Unix()
	p := newPool([]savedAccount{{Credential: c, Enabled: true, ConcurrencyLimit: 1}})
	p.now = func() time.Time { return now }
	b := &fixtureCatalogBackend{fakeBackend: &fakeBackend{}, result: modelCatalog{Models: []string{testModel}, Details: []modelDetail{{ID: testModel, DisplayName: testModel, RemainingFraction: &remaining}, {ID: "exhausted", DisplayName: "Exhausted", RemainingFraction: &zero}}, SharedWindows: []quotaWindow{{ID: "shared", Pool: "Fixture", Label: "5h", RemainingFraction: &remaining}}}}
	p.refreshCatalogs(context.Background(), b, noPersist)
	rows, models := p.snapshots()
	if len(rows) != 1 || len(rows[0].ModelDetails) != 2 || rows[0].ModelDetailsUpdatedAt != now.Unix() || !reflect.DeepEqual(models, []string{testModel}) {
		t.Fatal("display details not published")
	}
	if _, err := p.acquire(context.Background(), "exhausted", nil); err == nil {
		t.Fatal("exhausted display model admitted")
	}
	now = now.Add(catalogTTL + time.Second)
	rows, models = p.snapshots()
	if len(models) != 0 || rows[0].ModelDetails[0].RemainingFraction != nil || rows[0].SharedWindows[0].RemainingFraction != nil {
		t.Fatal("stale quota presented as current")
	}
	b.err = context.DeadlineExceeded
	p.refreshCatalogs(context.Background(), b, noPersist)
	rows, _ = p.snapshots()
	if rows[0].ModelDetailsUpdatedAt == now.Unix() || rows[0].ModelDetails[0].RemainingFraction != nil || len(rows[0].SharedWindows) != 0 {
		t.Fatal("failed refresh renewed old quota")
	}
	// Rehydrated accounts do not inherit runtime observations.
	p.remove(c.AccountID, c.Generation)
	replacement := c
	replacement.Generation = strings.Repeat("c", 32)
	p.add(savedAccount{Credential: replacement, Enabled: true, ConcurrencyLimit: 1})
	rows, _ = p.snapshots()
	if rows[0].ModelDetails != nil || rows[0].ModelDetailsUpdatedAt != 0 {
		t.Fatal("replacement account inherited runtime quota")
	}
}

func TestLateModelQuotaCannotCrossAccountGeneration(t *testing.T) {
	c := testCredential("a")
	p := newPool([]savedAccount{{Credential: c, Enabled: true, ConcurrencyLimit: 1}})
	entered, released, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
	b := &fixtureCatalogBackend{fakeBackend: &fakeBackend{}, catalogFn: func(context.Context, credential) (modelCatalog, error) {
		close(entered)
		<-released
		fraction := 0.5
		return modelCatalog{Models: []string{testModel}, Details: []modelDetail{{ID: testModel, DisplayName: "Fixture", RemainingFraction: &fraction}}}, nil
	}}
	go func() { p.refreshCatalogs(context.Background(), b, noPersist); close(finished) }()
	<-entered
	p.remove(c.AccountID, c.Generation)
	replacement := c
	replacement.Generation = strings.Repeat("c", 32)
	p.add(savedAccount{Credential: replacement, Enabled: true, ConcurrencyLimit: 1})
	close(released)
	<-finished
	rows, models := p.snapshots()
	if len(rows) != 1 || rows[0].Generation != replacement.Generation || rows[0].ModelDetails != nil || rows[0].ModelDetailsUpdatedAt != 0 || len(models) != 0 {
		t.Fatal("late quota crossed generation fence")
	}
}

func TestQuotaReadsKeepOriginAndRedirectGuards(t *testing.T) {
	for _, name := range []string{"kimi", "xai"} {
		t.Run(name, func(t *testing.T) {
			var b authBackend
			var h *oauthHTTP
			if name == "kimi" {
				v := newKimiBackend("").(*kimiBackend)
				b, h = v, v.http
			} else {
				v := newXAIBackend("").(*xaiBackend)
				b, h = v, v.http
			}
			calls := 0
			stub := adapterRoundTrip(func(r *http.Request) (*http.Response, error) {
				calls++
				if strings.HasSuffix(r.URL.Path, "/models") {
					return adapterResponse(200, `{"data":[{"id":"fixture-model"}]}`), nil
				}
				response := adapterResponse(302, `{}`)
				response.Header.Set("Location", "https://example.invalid/stolen")
				return response, nil
			})
			h.client.Transport = offlineSDKTransport(t, h.transport, stub)
			c := fixtureDeviceCredential(name)
			result, err := readModelCatalog(context.Background(), b, c)
			if err != nil || calls != 2 || len(result.Models) != 1 || result.QuotaIssue != "summary_unavailable" {
				t.Fatal("redirect followed or catalog rejected")
			}
			for _, endpoint := range []string{"https://example.invalid/v1/billing?format=credits", "http://api.kimi.com/coding/v1/usages", "https://user@api.kimi.com/coding/v1/usages"} {
				r, _ := http.NewRequest("GET", endpoint, nil)
				if _, err := h.client.Transport.RoundTrip(r); err == nil {
					t.Fatal("credential-bearing origin guard bypassed")
				}
			}
			if calls != 2 {
				t.Fatal("rejected origin reached dial transport")
			}
			wrong := c
			wrong.Provider = "claude"
			if _, err := readModelCatalog(context.Background(), b, wrong); err == nil || calls != 2 {
				t.Fatal("quota used a foreign provider credential")
			}
		})
	}
}

func TestQuotaPrimitivesRejectUnsafeNumbersAndLabels(t *testing.T) {
	for _, value := range []float64{-1, 2, math.NaN(), math.Inf(1)} {
		if validFraction(&value) != nil {
			t.Fatal("invalid fraction accepted")
		}
	}
	for _, value := range []string{"line\nbreak", "\u202Ehidden", strings.Repeat("x", 161)} {
		if safeCatalogLabel(value) != "" {
			t.Fatal("unsafe label accepted")
		}
	}
	tr := xaiSubscriptionTransport{base: adapterRoundTrip(func(*http.Request) (*http.Response, error) { return adapterResponse(200, `{}`), nil })}
	for _, endpoint := range []string{"https://cli-chat-proxy.grok.com/v1/billing", "https://cli-chat-proxy.grok.com/v1/billing?format=credits&other=1", "https://cli-chat-proxy.grok.com/v1/billing?format=credits&format=credits", "https://cli-chat-proxy.grok.com/v1/billing?format=other"} {
		r, _ := http.NewRequest("GET", endpoint, nil)
		if _, err := tr.RoundTrip(r); err == nil {
			t.Fatal("unreviewed billing route accepted")
		}
	}
	r, _ := http.NewRequest("POST", "https://cli-chat-proxy.grok.com/v1/billing?format=credits", nil)
	if _, err := tr.RoundTrip(r); err == nil {
		t.Fatal("billing mutation allowed")
	}
}
