package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"regexp"

	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/registry"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/thinking"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/api/handlers"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/pluginapi"
	"github.com/tidwall/gjson"
)

const maximumRoutedModels = 1024

var responseModelID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// The endpoint is already bound to Codex. A menu/cache entry is not evidence
// that a model is available to the admitted account; only upstream can decide.
// The built-in provider route still uses the normal manager and protected lease.
type codexModelRoute struct{}

func (codexModelRoute) HasModelRouters() bool { return true }
func (codexModelRoute) RouteModel(context.Context, pluginapi.ModelRouteRequest) (pluginapi.ModelRouteResponse, bool) {
	return pluginapi.ModelRouteResponse{Handled: true, TargetKind: pluginapi.ModelRouteTargetProvider, Target: "codex"}, true
}

func proxyModelInfo(model string) *registry.ModelInfo {
	// No authoritative capability catalog is supplied here. UserDefined tells
	// the SDK to retain requested reasoning instead of treating nil Thinking as
	// proof that the model cannot reason and stripping reasoning.effort.
	return &registry.ModelInfo{ID: model, Object: "model", OwnedBy: "openai", Type: "codex", DisplayName: model, UserDefined: true}
}

func responseModelBase(model string) (string, bool) {
	parsed := thinking.ParseSuffix(model)
	if len(model) > 128 || !responseModelID.MatchString(parsed.ModelName) {
		return "", false
	}
	if parsed.HasSuffix {
		// ParseSuffix only splits parentheses. Unknown contents are otherwise
		// silently discarded by the SDK, changing the caller's requested intent.
		_, special := thinking.ParseSpecialSuffix(parsed.RawSuffix)
		_, level := thinking.ParseLevelSuffix(parsed.RawSuffix)
		_, numeric := thinking.ParseNumericSuffix(parsed.RawSuffix)
		if !special && !level && !numeric {
			return "", false
		}
	}
	return parsed.ModelName, true
}

func (rt *runtime) ensureResponseModel(ctx context.Context, model string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	rt.modelMu.Lock()
	defer rt.modelMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if _, ok := rt.models[model]; ok {
		return nil
	}
	added := map[string]*registry.ModelInfo{model: proxyModelInfo(model)}
	// RestoreCooldownStates also retains models absent from today's menu.
	// Keep those bindings before reconciliation, which otherwise prunes them.
	for _, id := range rt.ids {
		if account, ok := rt.manager.GetByID(id); ok {
			for saved := range account.ModelStates {
				if _, exists := rt.models[saved]; !exists && responseModelID.MatchString(saved) {
					added[saved] = proxyModelInfo(saved)
				}
			}
		}
	}
	if len(rt.models)+len(added) > maximumRoutedModels {
		return errors.New("model_registry_full")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	for id, info := range added {
		rt.models[id] = info
	}
	models := make([]*registry.ModelInfo, 0, len(rt.models))
	for _, info := range rt.models {
		models = append(models, info)
	}
	for _, id := range rt.ids {
		registry.GetGlobalRegistry().RegisterClient(id, "codex", models)
		// RegisterClient resets registry projections. Reapply the manager's
		// active cooldowns before rebuilding its scheduler model snapshot.
		rt.manager.ReconcileRegistryModelStates(ctx, id)
		rt.manager.RefreshSchedulerEntry(id)
	}
	return nil
}

func (rt *runtime) withResponseModel(next gin.HandlerFunc) gin.HandlerFunc {
	return func(c *gin.Context) {
		body, err := handlers.ReadRequestBody(c)
		model := gjson.GetBytes(body, "model")
		baseModel, validModel := responseModelBase(model.String())
		if err != nil || !gjson.ValidBytes(body) || model.Type != gjson.String || !validModel {
			c.JSON(http.StatusBadRequest, gin.H{"error": gin.H{"message": "A valid explicit model ID is required.", "type": "invalid_request_error", "code": "invalid_model", "param": "model"}})
			return
		}
		if err := rt.ensureResponseModel(c.Request.Context(), baseModel); err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				c.AbortWithStatus(http.StatusRequestTimeout)
				return
			}
			c.JSON(http.StatusServiceUnavailable, gin.H{"error": gin.H{"message": "Local model routing capacity reached.", "type": "server_error", "code": "model_registry_full"}})
			return
		}
		// The SDK reads the body itself. Replay the decoded bytes unchanged;
		// never replace the selected model, effort, tools or conversation input.
		c.Request.Body = io.NopCloser(bytes.NewReader(body))
		c.Request.ContentLength = int64(len(body))
		c.Request.Header.Del("Content-Encoding")
		next(c)
	}
}
