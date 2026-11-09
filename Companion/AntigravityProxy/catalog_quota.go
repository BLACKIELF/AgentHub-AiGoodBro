package main

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Both endpoints use the already-authorized provider credential. A quota read
// is presentation only: its failure cannot fail a successful model discovery.
func (b *kimiBackend) catalog(ctx context.Context, c credential) (modelCatalog, error) {
	models, err := b.models(ctx, c)
	if err != nil {
		return modelCatalog{}, err
	}
	result := catalogForIDs(models)
	var raw json.RawMessage
	headers := kimiHeaders(c.DeviceID)
	headers.Set("Authorization", "Bearer "+c.AccessToken)
	quotaCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	_, err = b.http.json(quotaCtx, http.MethodGet, "https://api.kimi.com/coding/v1/usages", headers, nil, &raw)
	if err == nil {
		result.SharedWindows, err = parseKimiQuota(raw, time.Now())
	}
	if err != nil {
		result.SharedWindows = nil
		result.QuotaIssue = "summary_unavailable"
	}
	return result, nil
}

func (b *xaiBackend) catalog(ctx context.Context, c credential) (modelCatalog, error) {
	models, err := b.models(ctx, c)
	if err != nil {
		return modelCatalog{}, err
	}
	result := catalogForIDs(models)
	var raw json.RawMessage
	headers := http.Header{"Authorization": {"Bearer " + c.AccessToken}}
	quotaCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	_, err = b.http.json(quotaCtx, http.MethodGet, "https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers, nil, &raw)
	if err == nil {
		result.SharedWindows, err = parseGrokQuota(raw, time.Now())
	}
	if err != nil {
		result.SharedWindows = nil
		result.QuotaIssue = "summary_unavailable"
	}
	return result, nil
}

func quotaNumber(raw any) (float64, bool) {
	var n float64
	switch value := raw.(type) {
	case float64:
		n = value
	case string:
		parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
		if err != nil {
			return 0, false
		}
		n = parsed
	default:
		return 0, false
	}
	return n, !math.IsNaN(n) && !math.IsInf(n, 0) && n >= 0 && n <= 9_007_199_254_740_991
}

func quotaMap(raw any) map[string]any { value, _ := raw.(map[string]any); return value }

func quotaEpoch(raw any) *int64 {
	if s, ok := raw.(string); ok {
		if value := quotaReset(s); value != nil {
			return value
		}
	}
	n, ok := quotaNumber(raw)
	if !ok || n == 0 {
		return nil
	}
	if n > 1e11 {
		n /= 1000
	}
	if n <= 0 || n > 253402300799 {
		return nil
	}
	epoch := int64(n)
	if epoch <= 0 {
		return nil
	}
	return &epoch
}

func quotaResetFields(row map[string]any, keys ...string) (*int64, bool) {
	var reset *int64
	for _, key := range keys {
		value, present := row[key]
		if !present || value == nil {
			continue
		}
		parsed := quotaEpoch(value)
		if parsed == nil {
			return nil, false
		}
		if reset == nil {
			reset = parsed
		}
	}
	return reset, true
}

func clearExpiredQuota(window *quotaWindow, now time.Time) {
	if window.ResetAt != nil && *window.ResetAt <= now.Unix() {
		window.RemainingFraction = nil
		window.RemainingAmount = nil
		window.TotalAmount = nil
	}
}

func counterQuota(row map[string]any, id, label string, seconds int64, now time.Time) (quotaWindow, bool) {
	reset, validReset := quotaResetFields(row, "resetTime", "resetAt", "reset_at", "reset_time")
	window := quotaWindow{ID: id, Pool: "Kimi Code", Label: label, ResetAt: reset}
	if seconds > 0 {
		window.WindowSeconds = &seconds
	}
	total, validTotal := quotaNumber(row["limit"])
	used, validUsed := quotaNumber(row["used"])
	remaining, validRemaining := quotaNumber(row["remaining"])
	if raw, present := row["used"]; present && raw != nil && !validUsed {
		return window, true
	}
	if raw, present := row["remaining"]; present && raw != nil && !validRemaining {
		return window, true
	}
	if !validReset || !validTotal || total <= 0 {
		return window, row != nil
	}
	if validUsed {
		remaining = math.Max(0, total-used)
	} else if !validRemaining || remaining > total {
		return window, row != nil
	}
	fraction := remaining / total
	window.RemainingFraction = &fraction
	window.RemainingAmount, window.TotalAmount = &remaining, &total
	clearExpiredQuota(&window, now)
	return window, true
}

func parseKimiQuota(data []byte, now time.Time) ([]quotaWindow, error) {
	var response map[string]any
	if json.Unmarshal(data, &response) != nil {
		return nil, errors.New("invalid_quota_summary")
	}
	if nested := quotaMap(response["data"]); nested != nil {
		response = nested
	}
	windows := map[string]quotaWindow{}
	if row := quotaMap(response["usage"]); len(row) > 0 {
		if window, ok := counterQuota(row, "kimi-weekly", "7-day", 604800, now); ok {
			windows[window.ID] = window
		}
	}
	if rawLimits, exists := response["limits"]; exists && rawLimits != nil {
		limits, ok := rawLimits.([]any)
		if !ok || len(limits) > 256 {
			return nil, errors.New("invalid_quota_summary")
		}
		for index, raw := range limits {
			item := quotaMap(raw)
			period := quotaMap(item["window"])
			n, _ := quotaNumber(period["duration"])
			unit, _ := period["timeUnit"].(string)
			multiplier := float64(0)
			switch unit {
			case "TIME_UNIT_MINUTE":
				multiplier = 60
			case "TIME_UNIT_HOUR":
				multiplier = 3600
			case "TIME_UNIT_DAY":
				multiplier = 86400
			case "TIME_UNIT_WEEK":
				multiplier = 604800
			case "TIME_UNIT_MONTH":
				multiplier = 2592000
			}
			seconds := int64(0)
			if n*multiplier > 0 && n*multiplier <= 31622400 {
				seconds = int64(n * multiplier)
			}
			id, label := "kimi-limit-"+strconv.Itoa(index), "Usage"
			switch seconds {
			case 18000:
				id, label = "kimi-session", "5-hour"
			case 604800:
				id, label = "kimi-weekly", "7-day"
			case 2592000:
				id, label = "kimi-monthly", "Monthly"
			}
			row := quotaMap(item["detail"])
			if row == nil {
				row = item
			}
			if window, ok := counterQuota(row, id, label, seconds, now); ok {
				// Duration alone cannot prove that two counters share an
				// allowance. Keep the documented usages precedence below,
				// but never silently replace another counter window.
				if _, exists := windows[id]; exists {
					return nil, errors.New("duplicate_quota_window")
				}
				windows[id] = window
			}
		}
	}
	shares := quotaMap(response["usages"])
	for _, spec := range []struct {
		key, camel, id, label string
		seconds               int64
	}{
		{"limit_5h", "limit5h", "kimi-session", "5-hour", 18000},
		{"limit_7d", "limit7d", "kimi-weekly", "7-day", 604800},
		{"limit_month_total", "limitMonthTotal", "kimi-monthly", "Monthly total", 2592000},
		{"limit_month_code", "limitMonthCode", "kimi-monthly-code", "Monthly Code", 2592000},
	} {
		row := quotaMap(shares[spec.key])
		if row == nil {
			row = quotaMap(shares[spec.camel])
		}
		if row == nil {
			continue
		}
		reset, validReset := quotaResetFields(row, "resetTime", "resetAt", "reset_at", "reset_time")
		window := quotaWindow{ID: spec.id, Pool: "Kimi Code", Label: spec.label, WindowSeconds: &spec.seconds, ResetAt: reset}
		ratio, ok := quotaNumber(row["used_ratio"])
		if !ok {
			ratio, ok = quotaNumber(row["usedRatio"])
		}
		if ok && validReset {
			remaining := math.Max(0, 1-ratio)
			window.RemainingFraction = &remaining
		}
		// Missing or malformed ratios stay unknown, including when a legacy
		// counter exists for the same window; never claim fresh zero usage.
		clearExpiredQuota(&window, now)
		windows[spec.id] = window
	}
	if len(windows) == 0 {
		return nil, errors.New("invalid_quota_summary")
	}
	result := make([]quotaWindow, 0, len(windows))
	for _, window := range windows {
		result = append(result, window)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result, nil
}

// Grok's Option<Cent> distinguishes a missing object from the proto3 zero
// encoded as {} (grok-build billing.rs, commit 07e35a3dfeed2f200d319ef6c893b5ea286d9a51).
// This default belongs only to Cent, never to generic quota objects.
func grokCentValue(raw any) (float64, bool) {
	value := quotaMap(raw)
	if value == nil {
		return 0, false
	}
	if len(value) == 0 {
		return 0, true
	}
	amount, ok := quotaNumber(value["val"])
	return amount, ok && math.Trunc(amount) == amount
}

func parseGrokQuota(data []byte, now time.Time) ([]quotaWindow, error) {
	var response map[string]any
	if json.Unmarshal(data, &response) != nil {
		return nil, errors.New("invalid_quota_summary")
	}
	config := quotaMap(response["config"])
	if config == nil {
		return nil, errors.New("invalid_quota_summary")
	}
	period := quotaMap(config["currentPeriod"])
	reset, validReset := quotaResetFields(period, "end")
	if reset == nil && validReset {
		reset, validReset = quotaResetFields(config, "billingPeriodEnd")
	}
	window := quotaWindow{ID: "grok-subscription", Pool: "Grok", Label: "Credits", ResetAt: reset}
	var seconds int64
	switch period["type"] {
	case "USAGE_PERIOD_TYPE_DAILY":
		window.Label, seconds = "Daily", 86400
	case "USAGE_PERIOD_TYPE_WEEKLY":
		window.Label, seconds = "7-day", 604800
	case "USAGE_PERIOD_TYPE_MONTHLY":
		window.Label, seconds = "Monthly", 2592000
	}
	if seconds > 0 {
		window.WindowSeconds = &seconds
	}
	if used, ok := quotaNumber(config["creditUsagePercent"]); ok && used <= 100 && validReset {
		remaining := 1 - used/100
		window.RemainingFraction = &remaining
	}
	clearExpiredQuota(&window, now)
	result := []quotaWindow{window}
	cap, capOK := grokCentValue(config["onDemandCap"])
	used, usedOK := grokCentValue(config["onDemandUsed"])
	if capOK && cap > 0 {
		onDemand := quotaWindow{ID: "grok-on-demand", Pool: "Grok on-demand", Label: "On-demand", ResetAt: reset}
		if usedOK && validReset {
			remaining := math.Max(0, 1-used/cap)
			onDemand.RemainingFraction = &remaining
		}
		clearExpiredQuota(&onDemand, now)
		result = append(result, onDemand)
	}
	return result, nil
}
