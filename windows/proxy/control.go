package main

import (
	"context"
	"errors"
	"net"
	goruntime "runtime"
	"strconv"
	"strings"
)

// Windows uses an authenticated, ephemeral IPv4 loopback control listener.
// The per-run 256-bit key remains in stdin/memory, never a command argument.
func dialControl(ctx context.Context, address string) (net.Conn, error) {
	if strings.HasPrefix(address, "tcp:") {
		endpoint := strings.TrimPrefix(address, "tcp:")
		host, portText, err := net.SplitHostPort(endpoint)
		port, portErr := strconv.Atoi(portText)
		if err != nil || portErr != nil || host != "127.0.0.1" || port < 1 || port > 65535 || strconv.Itoa(port) != portText {
			return nil, errors.New("invalid_control_endpoint")
		}
		return (&net.Dialer{}).DialContext(ctx, "tcp4", endpoint)
	}
	if goruntime.GOOS == "windows" {
		return nil, errors.New("invalid_control_endpoint")
	}
	return (&net.Dialer{}).DialContext(ctx, "unix", address)
}
