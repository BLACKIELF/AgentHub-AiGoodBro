package main

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"
)

func TestWindowsControlEndpointIsStrictIPv4Loopback(t *testing.T) {
	for _, endpoint := range []string{"tcp:localhost:1234", "tcp:0.0.0.0:1234", "tcp:127.0.0.2:1234", "tcp:[::1]:1234", "tcp:127.0.0.1:0", "tcp:127.0.0.1:01234", "tcp:127.0.0.1:1234/path"} {
		c, err := dialControl(context.Background(), endpoint)
		if c != nil {
			c.Close()
		}
		if err == nil {
			t.Fatal("accepted an untrusted control endpoint")
		}
	}
}
func TestWindowsTCPControlUsesExistingBoundedBridgeProtocol(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan struct{})
	defer func() { listener.Close(); <-done }()
	go func() {
		defer close(done)
		c, err := listener.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		var r bridgeRequest
		if json.NewDecoder(c).Decode(&r) != nil || r.Key != "synthetic-control-key" || r.RunID != "synthetic-run" || r.Command != "heartbeat" || r.LeaseID != "synthetic-lease" {
			return
		}
		_ = json.NewEncoder(c).Encode(bridgeReply{OK: true})
	}()
	b := bridge{socket: "tcp:" + listener.Addr().String(), key: "synthetic-control-key", runID: "synthetic-run", exchangeTimeout: time.Second}
	reply, err := b.call(context.Background(), "heartbeat", "synthetic-request", "synthetic-profile", "synthetic-lease")
	if err != nil || !reply.OK {
		t.Fatal("loopback bridge did not preserve the authenticated ownership tuple")
	}
}
