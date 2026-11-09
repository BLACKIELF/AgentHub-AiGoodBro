// Offline native-host fixture. It never listens, opens a browser or calls an API.
// A test-only working-directory name selects an adversarial IPC sequence.
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

var providers = []string{"antigravity", "claude", "kimi", "xai"}

func fixtureCredential(provider string) map[string]any {
	prefix := provider
	if provider == "antigravity" {
		prefix = "ag"
	}
	project := ""
	if provider == "antigravity" {
		project = "synthetic-project"
	}
	return map[string]any{
		"provider": provider, "accountID": prefix + "-" + strings.Repeat("a", 32),
		"generation": strings.Repeat("b", 32), "maskedIdentity": "f***@e***",
		"accessToken": "synthetic-access-" + provider, "refreshToken": "synthetic-refresh-" + provider,
		"projectID": project, "expiresAt": time.Now().Add(time.Hour).Unix(),
	}
}

func fixtureAccount(credential map[string]any) map[string]any {
	provider := credential["provider"].(string)
	return map[string]any{
		"id": credential["accountID"], "provider": provider, "generation": credential["generation"],
		"maskedIdentity": credential["maskedIdentity"], "enabled": true, "concurrencyLimit": 1,
		"inFlight": 0, "state": "ready", "models": []string{"shared-fixture", provider + "-fixture"},
	}
}

func addFixtureModelDetails(row map[string]any) {
	row["modelDetailsUpdatedAt"] = time.Now().Unix()
	row["modelDetails"] = []map[string]any{
		{"id": "antigravity-fixture", "displayName": "Fixture model", "remainingFraction": 0.4, "resetAt": int64(4102444800)},
		{"id": "exhausted-fixture", "displayName": "Exhausted fixture", "remainingFraction": 0.0},
		{"id": "unknown-fixture", "displayName": "Unknown fixture"},
		{"id": "expired-fixture", "displayName": "Expired fixture", "resetAt": int64(946684800)},
	}
	row["sharedWindows"] = []map[string]any{{"id": "fixture-pool", "pool": "Fixture pool", "label": "5-hour", "remainingFraction": 0.4, "windowSeconds": 18000}}
}

type pendingWrite struct {
	credential map[string]any
	purpose    string
	provider   string
	session    string
}

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	if !scanner.Scan() {
		return
	}
	wd, _ := os.Getwd()
	scenario := filepath.Base(wd)
	out := json.NewEncoder(os.Stdout)
	if strings.HasPrefix(scenario, "pending-refresh-") {
		runPendingRefreshFixture(scanner, out, scanner.Bytes(), scenario)
		return
	}
	emit := func(value any) { _ = out.Encode(value) }
	active := map[string]map[string]any{}
	if scenario == "large-model-snapshot" {
		var bootstrap struct {
			Accounts []struct {
				Credential map[string]any `json:"credential"`
			} `json:"accounts"`
		}
		if json.Unmarshal(scanner.Bytes(), &bootstrap) != nil {
			return
		}
		for index, saved := range bootstrap.Accounts {
			row := fixtureAccount(saved.Credential)
			models, details := []string{}, []map[string]any{}
			for model := 0; model < 512; model++ {
				id := fmt.Sprintf("fixture-model-%04d", model)
				id += strings.Repeat("x", 32-len(id))
				models = append(models, id)
				details = append(details, map[string]any{"id": id, "displayName": fmt.Sprintf("Fixture Model %d", model),
					"remainingFraction": float64(index+1) / 100, "resetAt": int64(1_893_456_000)})
			}
			row["models"], row["modelDetails"], row["modelDetailsUpdatedAt"] = models, details, int64(1_794_182_400)
			windows := []map[string]any{}
			for window := 0; window < 3; window++ {
				windows = append(windows, map[string]any{"id": fmt.Sprintf("summary-%03d", window), "pool": "Fixture Shared Pool",
					"label": "5 hours", "remainingFraction": float64(index+1) / 100, "resetAt": int64(1_893_456_000), "windowSeconds": 18000, "modelIDs": models})
			}
			row["sharedWindows"] = windows
			active[row["id"].(string)] = row
		}
	}
	pending := map[string]pendingWrite{}
	var session, requestedProvider string
	antigravityAttempts := 0
	snapshotRefreshes := 0
	limitClaudeCatalog := false
	snapshot := func(crossCatalog bool) {
		rows := []any{}
		catalogs := map[string][]string{}
		keys := make([]string, 0, len(active))
		for key := range active {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, provider := range providers {
			catalogs[provider] = []string{}
			for _, key := range keys {
				row := active[key]
				if row["provider"] == provider {
					rows = append(rows, row)
					if row["enabled"] == true {
						catalogs[provider] = row["models"].([]string)
					}
				}
			}
		}
		if crossCatalog {
			catalogs["antigravity"] = append(catalogs["antigravity"], "claude-fixture")
		}
		if limitClaudeCatalog && len(catalogs["claude"]) > 0 {
			catalogs["claude"] = []string{"claude-fixture"}
		}
		emit(map[string]any{"event": "snapshot", "accounts": rows, "models": catalogs["antigravity"], "providerModels": catalogs})
	}
	persist := func(request, purpose, provider, label string, credential map[string]any) {
		pending[request] = pendingWrite{credential: credential, purpose: purpose, provider: provider, session: session}
		emit(map[string]any{
			"event": "persist_credential", "provider": label, "requestID": request,
			"sessionID": session, "purpose": purpose, "accountID": credential["accountID"],
			"generation": credential["generation"], "credential": credential,
		})
	}
	emit(map[string]any{"event": "ready", "port": 18081, "providers": providers})
	snapshot(false)
	for scanner.Scan() {
		var command map[string]any
		if json.Unmarshal(scanner.Bytes(), &command) != nil {
			return
		}
		switch command["command"] {
		case "auth":
			session, _ = command["requestID"].(string)
			requestedProvider, _ = command["provider"].(string)
			if scenario == "cancel-late" {
				continue
			}
			credential, label := fixtureCredential(requestedProvider), requestedProvider
			if scenario == "multi-same-provider" && requestedProvider == "antigravity" {
				antigravityAttempts++
				idChar := "a"
				if antigravityAttempts == 2 {
					idChar = "c"
				}
				credential["accountID"] = "ag-" + strings.Repeat(idChar, 32)
			}
			if active[credential["accountID"].(string)] != nil {
				emit(map[string]any{"event": "auth_result", "provider": requestedProvider, "sessionID": session, "code": "account_exists"})
				continue
			}
			switch scenario {
			case "provider-credential-add":
				credential, label = fixtureCredential("claude"), "claude"
			case "provider-prefix-add":
				credential["provider"], label = "claude", "claude"
			case "provider-label-add":
				label = "claude"
			}
			persist("synthetic-add-"+requestedProvider, "add", requestedProvider, label, credential)
		case "cancel_auth":
			if scenario == "cancel-late" {
				persist("synthetic-cancelled-add", "add", requestedProvider, requestedProvider, fixtureCredential(requestedProvider))
			}
		case "persist_result":
			request, _ := command["requestID"].(string)
			write, exists := pending[request]
			if !exists {
				return
			}
			delete(pending, request)
			if write.purpose == "add" {
				code := "credential_store_rejected"
				if command["ok"] == true {
					row := fixtureAccount(write.credential)
					if strings.HasPrefix(scenario, "model-details") {
						addFixtureModelDetails(row)
					}
					active[write.credential["accountID"].(string)] = row
					code = "ok"
				}
				snapshot(false)
				result := map[string]any{"event": "auth_result", "provider": write.provider, "sessionID": write.session, "code": code}
				if code == "ok" {
					result["accountID"] = write.credential["accountID"]
				}
				emit(result)
			}
			// Fixed, non-secret marker: rejection tests await a real IPC round trip.
			if write.purpose == "refresh" || scenario == "cancel-late" {
				emit(map[string]any{"event": "error", "code": "fixture_write_acknowledged"})
			}
		case "set_enabled":
			if id, ok := command["accountID"].(string); ok && active[id] != nil {
				active[id]["enabled"] = command["enabled"]
			}
			snapshot(false)
		case "snapshot":
			snapshot(false)
		case "refresh_models":
			if scenario == "large-model-snapshot" {
				snapshotRefreshes++
				if snapshotRefreshes == 1 {
					// Repeat the complete large frame then a small barrier event.
					snapshot(false)
					emit(map[string]any{"event": "error", "code": "fixture_snapshot_acknowledged"})
				} else if snapshotRefreshes == 2 {
					// A syntactically valid but oversized snapshot must never
					// publish its account content, even in a long pipe sequence.
					_, _ = io.WriteString(os.Stdout, "{\"event\":\"snapshot\",\"padding\":\"")
					chunk := strings.Repeat("x", 4096)
					for written := 0; written <= 32<<20; written += len(chunk) {
						if _, err := io.WriteString(os.Stdout, chunk); err != nil {
							return
						}
					}
					_, _ = io.WriteString(os.Stdout, "\",\"accounts\":[]}\n")
				}
				continue
			}
			if scenario == "oversized-snapshot-error" {
				emit(map[string]any{"event": "error", "code": "snapshot_too_large"})
				continue
			}
			if strings.HasPrefix(scenario, "model-details") {
				snapshotRefreshes++
				row := active[fixtureCredential("antigravity")["accountID"].(string)]
				details := row["modelDetails"].([]map[string]any)
				switch scenario {
				case "model-details-invalid-fraction":
					details[0]["remainingFraction"] = 2.0
				case "model-details-invalid-name":
					details[0]["displayName"] = "unsafe\u202ename"
				case "model-details-invalid-duplicate":
					details[1]["id"] = details[0]["id"]
				case "model-details-invalid-time":
					row["modelDetailsUpdatedAt"] = -1
				case "model-details-invalid-window":
					row["sharedWindows"].([]map[string]any)[0]["remainingFraction"] = -1.0
				case "model-details":
					if snapshotRefreshes == 2 {
						details[0]["remainingFraction"] = 0.2
					}
					if snapshotRefreshes == 3 {
						delete(row, "sharedWindows")
						row["quotaIssue"] = "summary_unavailable"
						details[0]["remainingFraction"] = 0.1
					}
				}
				for i := 0; i < 5; i++ {
					snapshot(false)
				}
				emit(map[string]any{"event": "error", "code": "fixture_snapshot_acknowledged"})
				continue
			}
			if scenario == "snapshot-updates" {
				snapshotRefreshes++
				switch snapshotRefreshes {
				case 2:
					limitClaudeCatalog = true
				case 3:
					row := active[fixtureCredential("claude")["accountID"].(string)]
					row["inFlight"], row["state"] = 1, "busy"
				case 4:
					active[fixtureCredential("claude")["accountID"].(string)]["cooldownUntil"] = int64(4102444800)
				}
				for i := 0; i < 5; i++ {
					snapshot(false)
				}
				// A fixed error event acts as a pipe-order barrier for this
				// offline scenario; subscriptions count it separately.
				emit(map[string]any{"event": "error", "code": "fixture_snapshot_acknowledged"})
				continue
			}
			if scenario == "cross-catalog" {
				snapshot(true)
				continue
			}
			credential, label := fixtureCredential("antigravity"), "antigravity"
			if scenario == "provider-credential-refresh" {
				credential, label = fixtureCredential("claude"), "claude"
			} else if scenario == "provider-label-refresh" {
				label = "claude"
			}
			persist("synthetic-refresh", "refresh", "antigravity", label, credential)
		case "remove":
			id, _ := command["accountID"].(string)
			if account := active[id]; account != nil {
				provider := account["provider"].(string)
				delete(active, id)
				persist("synthetic-revoked-refresh", "refresh", provider, provider, fixtureCredential(provider))
			}
			snapshot(false)
		case "shutdown":
			return
		}
	}
}

// Only synthetic bootstrap values enter this isolated fixture. Markers expose
// ACK state, never credentials, and no network/SDK functionality is imported.
func runPendingRefreshFixture(scanner *bufio.Scanner, out *json.Encoder, data []byte, scenario string) {
	var bootstrap struct {
		Accounts []struct {
			Credential map[string]any `json:"credential"`
			Pending    *struct {
				Base       string         `json:"baseFingerprint"`
				Credential map[string]any `json:"credential"`
			} `json:"pendingRefresh"`
		} `json:"accounts"`
	}
	if json.Unmarshal(data, &bootstrap) != nil || len(bootstrap.Accounts) != 1 {
		return
	}
	active := bootstrap.Accounts[0].Credential
	candidate := map[string]any{}
	for key, value := range active {
		candidate[key] = value
	}
	candidate["accessToken"], candidate["refreshToken"] = "synthetic-pending-access", "synthetic-pending-refresh"
	candidate["expiresAt"] = float64(4_102_444_800)
	fingerprint := fixtureCredentialFingerprint(active)
	marker := "fixture_bootstrap_active"
	if pending := bootstrap.Accounts[0].Pending; pending != nil {
		candidate, fingerprint, marker = pending.Credential, pending.Base, "fixture_bootstrap_pending"
		if fixtureCredentialFingerprint(active) == fixtureCredentialFingerprint(candidate) {
			marker = "fixture_bootstrap_promoted"
		}
	}
	emit := func(value any) { _ = out.Encode(value) }
	removed := false
	snapshot := func() {
		rows := []any{}
		models := []string{}
		if !removed {
			row := fixtureAccount(active)
			row["lastError"] = marker
			rows, models = append(rows, row), row["models"].([]string)
		}
		emit(map[string]any{"event": "snapshot", "accounts": rows, "models": []string{}, "providerModels": map[string][]string{"xai": models}})
	}
	emit(map[string]any{"event": "ready", "port": 18081, "providers": providers})
	snapshot()
	stage := 0
	if scenario == "pending-refresh-no-stage" {
		stage = 1
	}
	purposes := []string{"refresh_pending", "refresh_promote", "refresh_discard"}
	emitStage := func() {
		if stage >= len(purposes) {
			return
		}
		value := map[string]any{}
		for key, v := range candidate {
			value[key] = v
		}
		base := fingerprint
		if scenario == "pending-refresh-wrong-base" {
			base = strings.Repeat("0", 64)
		}
		if scenario == "pending-refresh-wrong-generation" {
			value["generation"] = strings.Repeat("z", 32)
		}
		if scenario == "pending-refresh-oversize" {
			value["accessToken"], value["refreshToken"] = strings.Repeat(`"`, 16384), strings.Repeat(`"`, 16384)
		}
		emit(map[string]any{"event": "persist_credential", "provider": value["provider"], "accountID": value["accountID"],
			"generation": value["generation"], "requestID": "synthetic-pending-write", "purpose": purposes[stage],
			"expectedCredentialFingerprint": base, "credential": value})
	}
	for scanner.Scan() {
		var command map[string]any
		if json.Unmarshal(scanner.Bytes(), &command) != nil {
			return
		}
		switch command["command"] {
		case "snapshot":
			snapshot()
		case "refresh_models":
			emitStage()
		case "persist_result":
			ok := command["ok"] == true
			marker = fmt.Sprintf("fixture_stage_%d_%t", stage, ok)
			if ok {
				if stage == 1 {
					active = candidate
				}
				stage++
			}
			if removed {
				emit(map[string]any{"event": "error", "code": "fixture_late_pending_ack"})
			} else {
				snapshot()
			}
		case "remove":
			removed = true
			stage = 0
			emitStage()
			snapshot()
		case "shutdown":
			return
		}
	}
}

func fixtureCredentialFingerprint(c map[string]any) string {
	h := sha256.New()
	_, _ = io.WriteString(h, "aigoodbro-proxy-credential-v1\x00")
	for _, key := range []string{"provider", "accountID", "generation", "maskedIdentity", "accessToken", "refreshToken", "projectID", "expiresAt", "idToken", "deviceID", "accountSubject", "organizationID", "refreshExpiresAt"} {
		value, _ := c[key].(string)
		if key == "expiresAt" || key == "refreshExpiresAt" {
			number, _ := c[key].(float64)
			value = strconv.FormatInt(int64(number), 10)
		}
		_, _ = io.WriteString(h, strconv.Itoa(len(value))+":"+value)
	}
	return hex.EncodeToString(h.Sum(nil))
}
