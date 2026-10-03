package main

import (
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestNetworkProxyValidation(t *testing.T) {
	for _, raw := range []string{"", "http://127.0.0.1:7897", "socks5://localhost:1080", "http://[::1]:7897", "http://proxy.example:8080"} {
		if _, err := parseNetworkProxy(raw); err != nil {
			t.Errorf("valid proxy rejected")
		}
	}
	for _, raw := range []string{"https://localhost:443", "socks5h://localhost:1080", "ftp://localhost:21", "http://localhost", "http://localhost:0", "http://localhost:65536", "http://localhost:07897", "http://localhost:-1", "http://user:secret@localhost:7897", "http://localhost:7897/", "http://localhost:7897?key=secret", "http://localhost:7897?", "http://localhost:7897#x", "http://localhost:7897#", "http://localhost:7897\n", " http://localhost:7897", "http://bad_host:7897", "http://[fe80::1%25en0]:7897"} {
		if _, err := parseNetworkProxy(raw); err == nil {
			t.Errorf("invalid proxy accepted: %q", raw)
		}
	}
}

func TestExplicitProxyUsesCONNECTWithoutCredentialLeak(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	var upstreamCalls int
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamCalls++
		if !b.hasLease("A") {
			t.Error("TLS upstream called without lease")
		}
		if r.Header.Get("Authorization") != "Bearer fixture-A" {
			t.Error("missing synthetic upstream credential")
		}
		complete(w, "A")
	}))
	defer upstream.Close()
	target := strings.TrimPrefix(upstream.URL, "https://")
	var mu sync.Mutex
	connectCalls := 0
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "CONNECT" || r.Host != target {
			t.Error("unexpected proxy destination")
			w.WriteHeader(403)
			return
		}
		if r.Header.Get("Authorization") != "" || r.Header.Get("Proxy-Authorization") != "" {
			t.Error("credential exposed on CONNECT")
		}
		mu.Lock()
		connectCalls++
		mu.Unlock()
		remote, err := net.Dial("tcp", target)
		if err != nil {
			t.Error(err)
			w.WriteHeader(502)
			return
		}
		client, buffer, err := w.(http.Hijacker).Hijack()
		if err != nil {
			remote.Close()
			t.Error(err)
			return
		}
		_, _ = buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		_ = buffer.Flush()
		go func() { defer client.Close(); defer remote.Close(); _, _ = io.Copy(client, remote) }()
		go func() { defer client.Close(); defer remote.Close(); _, _ = io.Copy(remote, buffer) }()
	}))
	defer proxy.Close()
	s.NetworkProxy = proxy.URL
	rt, server, out := startTestRuntime(t, s, upstream.URL)
	roots := x509.NewCertPool()
	roots.AddCert(upstream.Certificate())
	rt.transport.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	// Explicit selection must not inherit an unrelated environment proxy.
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:1")
	t.Setenv("ALL_PROXY", "socks5://127.0.0.1:1")
	response := request(t, s, server.URL, false)
	body := consume(t, response)
	waitEmpty(t, b)
	if response.StatusCode != 200 || !strings.Contains(body, "done-A") {
		t.Fatalf("proxied request failed: %d", response.StatusCode)
	}
	mu.Lock()
	defer mu.Unlock()
	if connectCalls != 1 || upstreamCalls != 1 {
		t.Fatalf("proxy/upstream counts %d/%d", connectCalls, upstreamCalls)
	}
	if strings.Contains(out.String(), proxy.URL) || strings.Contains(out.String(), "fixture-A") || strings.Contains(out.String(), "refresh_token") {
		t.Fatal("unsafe event")
	}
	for _, record := range rt.manager.List() {
		if record.Metadata["refresh_token"] != nil || record.Metadata["access_token"] != nil {
			t.Fatal("manager retained tokens")
		}
	}
}
