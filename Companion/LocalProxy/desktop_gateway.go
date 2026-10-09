package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// The built-in OpenAI provider keeps Desktop's real ChatGPT control-plane
// identity and persists a provider that still exists after the proxy is off.
// Its inference bearer is verified locally, then replaced before entering the
// account pool. The Desktop credential is never forwarded to pool inference.
func startDesktopGateway(c desktopConnection, environment []string) (*http.Server, string, error) {
	catalog, closeCatalog, err := newDesktopModelCatalog(c.NetworkProxy)
	if err != nil {
		return nil, "", err
	}
	server, endpoint, err := startDesktopGatewayWithCatalog(c, environment, catalog)
	if err != nil {
		closeCatalog()
		return nil, "", err
	}
	server.RegisterOnShutdown(closeCatalog)
	return server, endpoint, nil
}

func startDesktopGatewayWithCatalog(c desktopConnection, environment []string, catalog http.Handler) (*http.Server, string, error) {
	home := ""
	userHome := ""
	for _, entry := range environment {
		name, value, _ := strings.Cut(entry, "=")
		if name == "CODEX_HOME" {
			home = value
		} else if name == "HOME" {
			userHome = value
		}
	}
	if home == "" && userHome != "" {
		home = filepath.Join(userHome, ".codex")
	}
	if !filepath.IsAbs(home) || !desktopEndpoint(c.Endpoint) {
		return nil, "", errors.New("invalid desktop gateway configuration")
	}
	target, err := url.Parse(c.Endpoint)
	if err != nil {
		return nil, "", err
	}
	target.Path = ""
	transport := &http.Transport{Proxy: nil, ResponseHeaderTimeout: 15 * time.Minute}
	proxy := &httputil.ReverseProxy{
		Transport:     transport,
		FlushInterval: -1,
		ErrorLog:      log.New(io.Discard, "", 0),
		Rewrite: func(request *httputil.ProxyRequest) {
			request.SetURL(target)
			request.Out.Header.Set("Authorization", "Bearer "+c.ClientKey)
			// Account and workspace identity belongs to the selected pool lease.
			for _, name := range []string{"ChatGPT-Account-ID", "OpenAI-Organization", "OpenAI-Project", "X-OpenAI-Actor-Authorization", "Cookie"} {
				request.Out.Header.Del(name)
			}
		},
		ErrorHandler: desktopGatewayForwardingError,
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !desktopRequestAuthorized(filepath.Join(home, "auth.json"), r.Header.Get("Authorization")) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if r.Header.Get("Upgrade") != "" {
			w.WriteHeader(http.StatusUpgradeRequired)
			return
		}
		// Codex expects its native {models:[...]} catalog with capabilities,
		// not the generic pool's OpenAI-compatible {data:[{id:...}]} listing.
		// Discovery remains on the signed-in Desktop's official control plane.
		if r.Method == http.MethodGet && r.URL.Path == "/v1/models" {
			catalog.ServeHTTP(w, r)
			return
		}
		if !(r.Method == "POST" && (r.URL.Path == "/v1/responses" || r.URL.Path == "/v1/responses/compact" || (strings.HasPrefix(r.URL.Path, "/v1/") && imageLocalPath(r.URL.Path) != ""))) {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		proxy.ServeHTTP(w, r)
	})
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, "", err
	}
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: time.Minute, ErrorLog: log.New(io.Discard, "", 0)}
	server.RegisterOnShutdown(transport.CloseIdleConnections)
	go func() {
		_ = server.Serve(listener)
		transport.CloseIdleConnections()
		if closer, ok := catalog.(interface{ CloseIdleConnections() }); ok {
			closer.CloseIdleConnections()
		}
	}()
	return server, "http://" + listener.Addr().String() + "/v1", nil
}

func desktopGatewayForwardingError(w http.ResponseWriter, r *http.Request, err error) {
	message := "AiGoodBro could not forward this request to the local proxy. The proxy's running state is unknown."
	var networkError net.Error
	var operationError *net.OpError
	switch {
	case errors.Is(r.Context().Err(), context.Canceled) || errors.Is(err, context.Canceled):
		message = "AiGoodBro request forwarding was canceled."
	case errors.Is(r.Context().Err(), context.DeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &networkError) && networkError.Timeout()):
		message = "AiGoodBro request forwarding timed out. The proxy's running state is unknown."
	case errors.As(err, &operationError) && operationError.Op == "dial" && errors.Is(operationError.Err, syscall.ECONNREFUSED):
		// A refused saved endpoint may belong to a stopped or restarted pool.
		// It does not establish whether another pool is currently running.
		message = "AiGoodBro's saved desktop proxy connection is unavailable. The proxy may have stopped or restarted. Reconnect through AiGoodBro, or reopen Codex normally to use its signed-in account."
	}
	// Preserve the existing response status and client retry behavior. Never
	// expose the transport error: it may contain local paths or credentials.
	http.Error(w, message, http.StatusServiceUnavailable)
}

// Read-only validation against the credential Codex itself currently uses.
// Reload on each request so an official token refresh does not break the route.
// Unsupported credential stores fail closed; no login or credential mutation.
func desktopRequestAuthorized(path, authorization string) bool {
	if !strings.HasPrefix(authorization, "Bearer ") || len(authorization) <= len("Bearer ") {
		return false
	}
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return false
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || !desktopOwned(info) || info.Size() > 1<<20 {
		return false
	}
	var auth struct {
		Mode   string `json:"auth_mode"`
		APIKey string `json:"OPENAI_API_KEY"`
		Tokens struct {
			AccessToken string `json:"access_token"`
		} `json:"tokens"`
	}
	decoder := json.NewDecoder(io.LimitReader(f, 1<<20))
	if decoder.Decode(&auth) != nil || decoder.Decode(new(any)) != io.EOF {
		return false
	}
	token := auth.Tokens.AccessToken
	if auth.Mode == "apikey" || (auth.Mode == "" && token == "") {
		token = auth.APIKey
	} else if auth.Mode != "" && auth.Mode != "chatgpt" {
		return false
	}
	return token != "" && subtle.ConstantTimeCompare([]byte(authorization), []byte("Bearer "+token)) == 1
}
