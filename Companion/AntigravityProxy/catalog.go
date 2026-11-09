package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	ag "github.com/router-for-me/CLIProxyAPI/v8/internal/auth/antigravity"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/misc"
)

// Display observations are separate from Models, which remains the admission
// list. In particular, showing an exhausted model never makes it callable.
type modelDetail struct {
	ID                string   `json:"id"`
	DisplayName       string   `json:"displayName"`
	RemainingFraction *float64 `json:"remainingFraction,omitempty"`
	ResetAt           *int64   `json:"resetAt,omitempty"`
	Disabled          *bool    `json:"disabled,omitempty"`
}

type quotaWindow struct {
	ID                string   `json:"id"`
	Pool              string   `json:"pool"`
	Label             string   `json:"label"`
	RemainingFraction *float64 `json:"remainingFraction,omitempty"`
	ResetAt           *int64   `json:"resetAt,omitempty"`
	ModelIDs          []string `json:"modelIDs,omitempty"`
	WindowSeconds     *int64   `json:"windowSeconds,omitempty"`
	RemainingAmount   *float64 `json:"remainingAmount,omitempty"`
	TotalAmount       *float64 `json:"totalAmount,omitempty"`
	Unit              string   `json:"unit,omitempty"`
	about             string
}

type modelCatalog struct {
	Models        []string
	Details       []modelDetail
	SharedWindows []quotaWindow
	QuotaIssue    string
}

type catalogBackend interface {
	catalog(context.Context, credential) (modelCatalog, error)
}

func readModelCatalog(ctx context.Context, b backend, c credential) (modelCatalog, error) {
	if richer, ok := b.(catalogBackend); ok {
		return richer.catalog(ctx, c)
	}
	models, err := b.models(ctx, c)
	if err != nil {
		return modelCatalog{}, err
	}
	return catalogForIDs(models), nil
}

func catalogForIDs(models []string) modelCatalog {
	result := modelCatalog{Models: models, Details: make([]modelDetail, 0, len(models))}
	for _, id := range models {
		result.Details = append(result.Details, modelDetail{ID: id, DisplayName: id})
	}
	return result
}

func safeCatalogLabel(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 160 || !utf8.ValidString(value) {
		return ""
	}
	for _, r := range value {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) || unicode.Is(unicode.Zl, r) || unicode.Is(unicode.Zp, r) {
			return ""
		}
	}
	return value
}

func validFraction(value *float64) *float64 {
	if value == nil || math.IsNaN(*value) || math.IsInf(*value, 0) || *value < 0 || *value > 1 {
		return nil
	}
	fraction := *value
	return &fraction
}

func quotaReset(value string) *int64 {
	if value == "" {
		return nil
	}
	reset, err := time.Parse(time.RFC3339, value)
	if err != nil || reset.Unix() <= 0 || reset.Unix() > 253402300799 {
		return nil
	}
	epoch := reset.Unix()
	return &epoch
}

func antigravityCatalog(data []byte, now time.Time) (modelCatalog, error) {
	var response struct {
		Models map[string]json.RawMessage `json:"models"`
		Sorts  json.RawMessage            `json:"agentModelSorts"`
	}
	if json.Unmarshal(data, &response) != nil || response.Models == nil || len(response.Models) > 512 {
		return modelCatalog{}, errors.New("invalid_catalog")
	}
	result := modelCatalog{Models: []string{}, Details: []modelDetail{}}
	for id, raw := range response.Models {
		if !modelPattern.MatchString(id) {
			continue
		}
		row := modelDetail{ID: id, DisplayName: id}
		// Optional display metadata must not alter the legacy admission parser.
		var labels map[string]json.RawMessage
		if json.Unmarshal(raw, &labels) == nil {
			var disabled *bool
			if json.Unmarshal(labels["disabled"], &disabled) == nil {
				row.Disabled = disabled
			}
			for _, key := range []string{"displayName", "label"} {
				var value string
				if json.Unmarshal(labels[key], &value) == nil && safeCatalogLabel(value) != "" {
					row.DisplayName = safeCatalogLabel(value)
					break
				}
			}
		}
		var detail struct {
			QuotaInfo *struct {
				RemainingFraction *float64 `json:"remainingFraction"`
				ResetTime         string   `json:"resetTime"`
			} `json:"quotaInfo"`
		}
		admitted := json.Unmarshal(raw, &detail) == nil
		if admitted && detail.QuotaInfo != nil {
			quota := detail.QuotaInfo
			row.RemainingFraction = validFraction(quota.RemainingFraction)
			row.ResetAt = quotaReset(quota.ResetTime)
			if quota.RemainingFraction != nil && (*quota.RemainingFraction <= 0 || *quota.RemainingFraction > 1) {
				admitted = false
			}
			if quota.ResetTime != "" {
				reset, err := time.Parse(time.RFC3339, quota.ResetTime)
				if err != nil || !reset.After(now) {
					admitted = false
					row.RemainingFraction = nil
				}
			}
		}
		if row.Disabled != nil && *row.Disabled {
			admitted = false
		}
		if admitted {
			result.Models = append(result.Models, id)
		}
		result.Details = append(result.Details, row)
	}
	sort.Strings(result.Models)
	ranks := map[string]int{}
	var sorts []struct {
		Groups []struct {
			ModelIDs []string `json:"modelIds"`
		} `json:"groups"`
	}
	if json.Unmarshal(response.Sorts, &sorts) == nil {
		for _, order := range sorts {
			for _, group := range order.Groups {
				for _, id := range group.ModelIDs {
					if _, exists := response.Models[id]; exists {
						if _, seen := ranks[id]; !seen {
							ranks[id] = len(ranks)
						}
					}
				}
			}
		}
	}
	sort.Slice(result.Details, func(i, j int) bool {
		left, leftKnown := ranks[result.Details[i].ID]
		right, rightKnown := ranks[result.Details[j].ID]
		if leftKnown != rightKnown {
			return leftKnown
		}
		if leftKnown {
			return left < right
		}
		return result.Details[i].ID < result.Details[j].ID
	})
	return result, nil
}

func (b *sdkBackend) catalog(ctx context.Context, c credential) (modelCatalog, error) {
	result, err := b.fetchModelCatalog(ctx, c)
	if err != nil {
		return modelCatalog{}, err
	}
	quotaCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	result.SharedWindows, err = b.sharedQuotaWindows(quotaCtx, c)
	if err != nil {
		result.SharedWindows = nil
		result.QuotaIssue = "summary_unavailable"
	} else {
		associateAntigravityPools(result.Details, result.SharedWindows)
	}
	return result, nil
}

func (b *sdkBackend) sharedQuotaWindows(ctx context.Context, c credential) ([]quotaWindow, error) {
	body, _ := json.Marshal(map[string]string{"project": c.ProjectID})
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, ag.DailyAPIEndpoint+"/v1internal:retrieveUserQuotaSummary", bytes.NewReader(body))
	if err != nil {
		return nil, errors.New("quota_summary_failed")
	}
	r.Header.Set("Authorization", "Bearer "+c.AccessToken)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("User-Agent", misc.AntigravityUserAgent())
	resp, err := b.client.Do(r)
	if err != nil {
		return nil, errors.New("quota_summary_failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, errors.New("quota_summary_failed")
	}
	data, err := readBounded(resp.Body, 1<<20)
	if err != nil {
		return nil, err
	}
	return parseQuotaSummary(data, time.Now())
}

func parseQuotaSummary(data []byte, now time.Time) ([]quotaWindow, error) {
	var response struct {
		Groups []json.RawMessage `json:"groups"`
	}
	if json.Unmarshal(data, &response) != nil || response.Groups == nil || len(response.Groups) > 32 {
		return nil, errors.New("invalid_quota_summary")
	}
	windows := []quotaWindow{}
	seen := map[string]bool{}
	for _, raw := range response.Groups {
		var group struct {
			DisplayName string            `json:"displayName"`
			Description string            `json:"description"`
			Buckets     []json.RawMessage `json:"buckets"`
		}
		if json.Unmarshal(raw, &group) != nil || safeCatalogLabel(group.DisplayName) == "" || len(group.Buckets) > 32 {
			continue
		}
		pool := quotaPoolName(safeCatalogLabel(group.DisplayName))
		if pool == "" {
			continue
		}
		about := strings.ToLower(group.DisplayName)
		if len(group.Description) <= 4096 {
			about += " " + strings.ToLower(group.Description)
		}
		for _, rawBucket := range group.Buckets {
			var bucket struct {
				BucketID          string          `json:"bucketId"`
				Window            string          `json:"window"`
				DisplayName       string          `json:"displayName"`
				RemainingFraction json.RawMessage `json:"remainingFraction"`
				ResetTime         string          `json:"resetTime"`
				Disabled          bool            `json:"disabled"`
			}
			if json.Unmarshal(rawBucket, &bucket) != nil || bucket.Disabled {
				continue
			}
			label := safeCatalogLabel(bucket.DisplayName)
			if label == "" {
				label = safeCatalogLabel(bucket.Window)
			}
			if label == "" {
				label = safeCatalogLabel(bucket.BucketID)
			}
			if label == "" {
				continue
			}
			key, _ := json.Marshal([]string{pool, bucket.BucketID, bucket.Window, label})
			digest := sha256.Sum256(key)
			id := "summary-" + hex.EncodeToString(digest[:])
			if seen[id] {
				return nil, errors.New("duplicate_quota_window")
			}
			seen[id] = true
			row := quotaWindow{ID: id, Pool: pool, Label: label, ResetAt: quotaReset(bucket.ResetTime), about: about}
			var fraction *float64
			if json.Unmarshal(bucket.RemainingFraction, &fraction) == nil {
				row.RemainingFraction = validFraction(fraction)
			}
			if bucket.ResetTime != "" && (row.ResetAt == nil || *row.ResetAt <= now.Unix()) {
				row.RemainingFraction = nil
			}
			var seconds int64
			switch strings.ToLower(bucket.Window) {
			case "5h":
				seconds = 18000
			case "weekly":
				seconds = 604800
			}
			if seconds > 0 {
				row.WindowSeconds = &seconds
			}
			windows = append(windows, row)
			if len(windows) > 256 {
				return nil, errors.New("too_many_quota_windows")
			}
		}
	}
	return windows, nil
}

func quotaPoolName(value string) string {
	if strings.HasSuffix(strings.ToLower(value), " models") {
		value = strings.TrimSpace(value[:len(value)-len(" models")])
	}
	return strings.ReplaceAll(value, " and ", " & ")
}

// Match the verified upstream grouping rules without changing admission. A
// model-specific versioned pool wins over family pools regardless of order.
// Family membership needs an explicit family name and the same 5-hour reading;
// a weekly-only pool never consumes a model's otherwise visible 5-hour quota.
func associateAntigravityPools(models []modelDetail, windows []quotaWindow) {
	for _, model := range models {
		if model.Disabled != nil && *model.Disabled {
			continue
		}
		selected, longest := "", 0
		for _, window := range windows {
			if !strings.ContainsAny(window.Pool, "0123456789") {
				continue
			}
			prefix := strings.ToLower(window.Pool)
			for _, name := range []string{model.DisplayName, strings.ReplaceAll(model.ID, "-", " ")} {
				name = strings.ToLower(name)
				if (name == prefix || strings.HasPrefix(name, prefix+" ") || strings.HasPrefix(name, prefix+"(")) && len(prefix) > longest {
					selected, longest = window.Pool, len(prefix)
				}
			}
		}
		if selected == "" && model.RemainingFraction != nil {
			family := ""
			id := strings.ToLower(model.ID)
			for _, known := range []string{"gemini", "claude", "gpt-oss"} {
				if strings.HasPrefix(id, known) {
					family = known
					break
				}
			}
			if family == "" {
				continue
			}
			matches := map[string]bool{}
			for _, window := range windows {
				if strings.ContainsAny(window.Pool, "0123456789") || window.WindowSeconds == nil || *window.WindowSeconds != 18000 ||
					window.RemainingFraction == nil || !strings.Contains(window.about, family) ||
					math.Abs(*model.RemainingFraction-*window.RemainingFraction) > 0.005 {
					continue
				}
				if model.ResetAt != nil && window.ResetAt != nil && math.Abs(float64(*model.ResetAt-*window.ResetAt)) >= 60 {
					continue
				}
				matches[window.Pool] = true
			}
			if len(matches) == 1 {
				for pool := range matches {
					selected = pool
				}
			}
		}
		if selected != "" {
			for i := range windows {
				if windows[i].Pool == selected {
					windows[i].ModelIDs = append(windows[i].ModelIDs, model.ID)
				}
			}
		}
	}
}
