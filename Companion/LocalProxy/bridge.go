package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"time"
)

type bridge struct{ socket, key, runID string }
type bridgeRequest struct {
	SchemaVersion int    `json:"schemaVersion"`
	RunID         string `json:"runID"`
	Key           string `json:"key"`
	Command       string `json:"command"`
	RequestID     string `json:"requestID"`
	ProfileID     string `json:"profileID"`
	LeaseID       string `json:"leaseID,omitempty"`
}
type bridgeReply struct {
	OK          bool     `json:"ok"`
	Order       []string `json:"order,omitempty"`
	LeaseID     string   `json:"leaseID"`
	AccessToken string   `json:"accessToken"`
	AccountID   string   `json:"accountID"`
	ExpiresAt   int64    `json:"expiresAt"`
	Error       string   `json:"error"`
	RetryAt     int64    `json:"retryAt"`
}

func (b *bridge) call(ctx context.Context, command, requestID, profileID, leaseID string) (bridgeReply, error) {
	ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", b.socket)
	if err != nil {
		return bridgeReply{}, errors.New("bridge_unavailable")
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	deadline, _ := ctx.Deadline()
	_ = conn.SetDeadline(deadline)
	if json.NewEncoder(conn).Encode(bridgeRequest{1, b.runID, b.key, command, requestID, profileID, leaseID}) != nil {
		return bridgeReply{}, errors.New("bridge_unavailable")
	}
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), 64<<10)
	if !scanner.Scan() {
		return bridgeReply{}, errors.New("bridge_unavailable")
	}
	var reply bridgeReply
	if json.Unmarshal(scanner.Bytes(), &reply) != nil {
		return bridgeReply{}, errors.New("bridge_invalid")
	}
	return reply, nil
}
