package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"time"
)

const desktopModelCatalogURL = "https://chatgpt.com/backend-api/codex/models"
const desktopModelCatalogLimit = 16 << 20

var desktopCatalogVersion = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$`)

type desktopModelCatalog struct{ client *http.Client }

func (catalog desktopModelCatalog) CloseIdleConnections() { catalog.client.CloseIdleConnections() }

func newDesktopModelCatalog(networkProxy string) (http.Handler, func(), error) {
	proxy, err := parseNetworkProxy(networkProxy)
	if err != nil {
		return nil, nil, err
	}
	transport := &http.Transport{
		DialContext:         (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 20 * time.Second,
		IdleConnTimeout: time.Minute,
	}
	if proxy != nil {
		transport.Proxy = http.ProxyURL(proxy)
	}
	client := &http.Client{Transport: transport, Timeout: 30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return desktopModelCatalog{client: client}, transport.CloseIdleConnections, nil
}

func (catalog desktopModelCatalog) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil || len(query) > 1 || len(query["client_version"]) != 1 || !desktopCatalogVersion.MatchString(query.Get("client_version")) {
		http.Error(w, "Invalid model catalog query.", http.StatusBadRequest)
		return
	}
	request, err := http.NewRequestWithContext(r.Context(), http.MethodGet, desktopModelCatalogURL+"?"+query.Encode(), nil)
	if err != nil {
		w.WriteHeader(http.StatusBadGateway)
		return
	}
	// This credential has already been checked against the Desktop's current
	// auth file. It goes only to the same official discovery endpoint as Codex,
	// never to the pool, a caller-supplied URL or a redirect destination.
	for _, name := range []string{"Authorization", "ChatGPT-Account-ID", "User-Agent", "Originator", "OpenAI-Beta", "X-Codex-Client-Version", "If-None-Match"} {
		if value := r.Header.Get(name); value != "" {
			request.Header.Set(name, value)
		}
	}
	request.Header.Set("Accept", "application/json")
	response, err := catalog.client.Do(request)
	if err != nil {
		http.Error(w, "Official model catalog unavailable.", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotModified {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	if response.StatusCode != http.StatusOK {
		status := http.StatusBadGateway
		if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests {
			status = response.StatusCode
		}
		http.Error(w, "Official model catalog unavailable.", status)
		return
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, desktopModelCatalogLimit+1))
	var envelope struct {
		Models []json.RawMessage `json:"models"`
	}
	if err != nil || len(body) > desktopModelCatalogLimit || json.Unmarshal(body, &envelope) != nil || envelope.Models == nil {
		http.Error(w, "Invalid official model catalog.", http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if etag := response.Header.Get("ETag"); etag != "" {
		w.Header().Set("ETag", etag)
	}
	_, _ = w.Write(body)
}
