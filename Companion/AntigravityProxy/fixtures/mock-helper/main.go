// Offline native-host fixture. It never listens, opens a browser or calls an API.
// A test-only working-directory name selects an adversarial IPC sequence.
package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
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
	emit := func(value any) { _ = out.Encode(value) }
	active := map[string]map[string]any{}
	pending := map[string]pendingWrite{}
	var session, requestedProvider string
	snapshot := func(crossCatalog bool) {
		rows := []any{}
		catalogs := map[string][]string{}
		for _, provider := range providers {
			catalogs[provider] = []string{}
			for _, row := range active {
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
				code := "oauth_failed"
				if command["ok"] == true {
					active[write.credential["accountID"].(string)] = fixtureAccount(write.credential)
					code = "ok"
				}
				snapshot(false)
				emit(map[string]any{"event": "auth_result", "provider": write.provider, "sessionID": write.session, "code": code})
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
