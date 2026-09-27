package main

import (
	"errors"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

var proxyHostLabel = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$`)
var proxyPort = regexp.MustCompile(`^[1-9][0-9]{0,4}$`)

// The native parent resolves system settings. The child accepts one explicit,
// credential-free URL and never consults HTTP_PROXY/HTTPS_PROXY/ALL_PROXY.
func parseNetworkProxy(raw string) (*url.URL, error) {
	if raw == "" {
		return nil, nil
	}
	invalid := func() (*url.URL, error) { return nil, errors.New("invalid_network_proxy") }
	if len(raw) > 2048 || strings.ContainsAny(raw, "?#") || strings.IndexFunc(raw, func(r rune) bool { return r <= 32 || r == 127 }) >= 0 {
		return invalid()
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "socks5") || u.User != nil || u.Opaque != "" || u.Path != "" || u.RawPath != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.RawFragment != "" {
		return invalid()
	}
	host, port, err := net.SplitHostPort(u.Host)
	if err != nil || host == "" || !proxyPort.MatchString(port) {
		return invalid()
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return invalid()
	}
	if net.ParseIP(host) == nil {
		if len(host) > 253 {
			return invalid()
		}
		for _, label := range strings.Split(host, ".") {
			if !proxyHostLabel.MatchString(label) {
				return invalid()
			}
		}
	}
	if strings.ContainsAny(host, "%/@\\") {
		return invalid()
	}
	return u, nil
}
