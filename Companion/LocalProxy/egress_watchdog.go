package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"time"
)

type egressSettings struct {
	Enabled      bool     `json:"enabled"`
	MihomoAPI    string   `json:"mihomoAPI"`
	MihomoSecret string   `json:"mihomoSecret"`
	Group        string   `json:"group"`
	Whitelist    []string `json:"whitelist"`
}

func (s egressSettings) validate() error {
	if s.MihomoAPI != "" {
		if _, err := controllerURL(s.MihomoAPI); err != nil {
			return err
		}
	}
	if len(s.MihomoSecret) > 4096 || strings.ContainsAny(s.MihomoSecret, "\r\n\x00") || len(s.Group) > 512 || strings.ContainsAny(s.Group, "\r\n\x00") || strings.TrimSpace(s.Group) != s.Group || len(s.Whitelist) > 100 {
		return errors.New("invalid_egress_settings")
	}
	seen := map[string]bool{}
	for _, node := range s.Whitelist {
		if node == "" || strings.TrimSpace(node) != node || len(node) > 512 || strings.ContainsAny(node, "\r\n\x00") || seen[node] {
			return errors.New("invalid_egress_settings")
		}
		seen[node] = true
	}
	return nil
}
func controllerURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u == nil || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || u.Opaque != "" {
		return nil, errors.New("invalid_egress_api")
	}
	ip := net.ParseIP(u.Hostname())
	if ip == nil || !ip.IsLoopback() {
		return nil, errors.New("invalid_egress_api")
	}
	if port := u.Port(); port != "" {
		p, e := strconv.Atoi(port)
		if e != nil || p < 1 || p > 65535 {
			return nil, errors.New("invalid_egress_api")
		}
	}
	return u, nil
}

type mihomoGroup struct {
	Type string   `json:"type"`
	Now  string   `json:"now"`
	All  []string `json:"all"`
}
type mihomoController struct {
	base      string
	secret    string
	client    *http.Client
	transport *http.Transport
}

func newMihomoController(s egressSettings) (*mihomoController, error) {
	u, err := controllerURL(s.MihomoAPI)
	if err != nil {
		return nil, err
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, _, err := net.SplitHostPort(address)
		ip := net.ParseIP(host)
		if err != nil || ip == nil || !ip.IsLoopback() {
			return nil, errors.New("controller_not_loopback")
		}
		return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, network, address)
	}
	return &mihomoController{base: strings.TrimSuffix(u.String(), "/"), secret: s.MihomoSecret, transport: transport, client: &http.Client{Transport: transport, Timeout: 7 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (c *mihomoController) request(ctx context.Context, method, path string, body []byte) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	if c.secret != "" {
		req.Header.Set("Authorization", "Bearer "+c.secret)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return 0, nil, errors.New("controller_unavailable")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, (64<<10)+1))
	if err != nil || len(data) > 64<<10 {
		return 0, nil, errors.New("controller_invalid")
	}
	return resp.StatusCode, data, nil
}
func (c *mihomoController) group(ctx context.Context, name string) (mihomoGroup, error) {
	status, data, err := c.request(ctx, http.MethodGet, "/proxies/"+url.PathEscape(name), nil)
	var g mihomoGroup
	if err != nil || status != http.StatusOK || json.Unmarshal(data, &g) != nil || g.Type != "Selector" || g.Now == "" || len(g.All) == 0 || len(g.All) > 10000 || !containsNode(g.All, g.Now) {
		return g, errors.New("controller_group_unavailable")
	}
	return g, nil
}
func containsNode(nodes []string, name string) bool {
	for _, n := range nodes {
		if n == name {
			return true
		}
	}
	return false
}

// A controller transport/API failure is not node-death evidence. Only the
// controller's explicit delay timeout (504) allows a failover attempt.
func (c *mihomoController) delay(ctx context.Context, node string) (string, int) {
	q := url.Values{"url": {"http://www.gstatic.com/generate_204"}, "timeout": {"5000"}}
	status, data, err := c.request(ctx, http.MethodGet, "/proxies/"+url.PathEscape(node)+"/delay?"+q.Encode(), nil)
	if err != nil {
		return "unavailable", 0
	}
	if status == http.StatusGatewayTimeout {
		var failure struct {
			Message string `json:"message"`
		}
		if json.Unmarshal(data, &failure) == nil && strings.TrimSpace(failure.Message) != "" {
			return "dead", 0
		}
		return "unavailable", 0
	}
	var value struct {
		Delay *int `json:"delay"`
	}
	if status != http.StatusOK || json.Unmarshal(data, &value) != nil || value.Delay == nil || *value.Delay < 0 || *value.Delay > 120000 {
		return "unavailable", 0
	}
	return "healthy", *value.Delay
}
func (c *mihomoController) selectNode(ctx context.Context, group, node string) error {
	body, _ := json.Marshal(struct {
		Name string `json:"name"`
	}{node})
	status, _, err := c.request(ctx, http.MethodPut, "/proxies/"+url.PathEscape(group), body)
	if err != nil || (status != http.StatusNoContent && status != http.StatusOK) {
		return errors.New("controller_switch_failed")
	}
	return nil
}
func sameGroup(a, b mihomoGroup) bool {
	return a.Type == b.Type && a.Now == b.Now && reflect.DeepEqual(a.All, b.All)
}

func (n *networkRecovery) checkEgress(ctx context.Context, maySwitch bool, requestID string) {
	outcome := event{Event: "egress", State: "unavailable", RequestID: requestID}
	defer func() { n.events.emit(outcome) }()
	if !n.settings.Enabled {
		outcome.State = "disabled"
		return
	}
	if n.settings.MihomoAPI == "" || n.settings.Group == "" {
		outcome.State = "unconfigured"
		return
	}
	if !n.watchdogMu.TryLock() {
		return
	}
	defer n.watchdogMu.Unlock()
	bounded, cancel := context.WithTimeout(ctx, 40*time.Second)
	defer cancel()
	c, err := newMihomoController(n.settings)
	if err != nil {
		return
	}
	defer c.transport.CloseIdleConnections()
	initial, err := c.group(bounded, n.settings.Group)
	if err != nil {
		return
	}
	state, latency := c.delay(bounded, initial.Now)
	outcome.State = state
	outcome.LatencyMS = latency
	if state != "dead" || !maySwitch {
		return
	}
	for _, candidate := range n.settings.Whitelist {
		if bounded.Err() != nil {
			outcome.State = "unavailable"
			return
		}
		if candidate == initial.Now || !containsNode(initial.All, candidate) {
			continue
		}
		state, latency = c.delay(bounded, candidate)
		if state == "unavailable" {
			outcome.State = state
			return
		}
		if state != "healthy" {
			continue
		}
		before, err := c.group(bounded, n.settings.Group)
		if err != nil {
			outcome.State = "unavailable"
			return
		}
		if !sameGroup(initial, before) {
			outcome.State = "changed"
			return
		}
		if c.selectNode(bounded, n.settings.Group, candidate) != nil {
			outcome.State = "unavailable"
			return
		}
		after, err := c.group(bounded, n.settings.Group)
		if err != nil {
			outcome.State = "unavailable"
			return
		}
		if after.Now != candidate || after.Type != initial.Type || !reflect.DeepEqual(after.All, initial.All) {
			outcome.State = "changed"
			return
		}
		outcome.State = "switched"
		outcome.LatencyMS = latency
		n.probeAccounts(ctx, "", true)
		return
	}
	outcome.State = "all_dead"
}
