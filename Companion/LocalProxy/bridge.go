package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"time"
)

type bridge struct {
	socket, key, runID                            string
	once                                          sync.Once
	normal, maintenance, reconciliation           chan struct{}
	queueTimeout, exchangeTimeout, resolveTimeout time.Duration // Test overrides; zero selects production bounds.
}
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
	OK              bool     `json:"ok"`
	Order           []string `json:"order,omitempty"`
	LastResortIDs   []string `json:"lastResortIDs,omitempty"`
	DeferredIDs     []string `json:"deferredIDs,omitempty"`
	CreditFallback  bool     `json:"creditFallback,omitempty"`
	LeaseID         string   `json:"leaseID"`
	AccessToken     string   `json:"accessToken"`
	AccountID       string   `json:"accountID"`
	ExpiresAt       int64    `json:"expiresAt"`
	Error           string   `json:"error"`
	Resolution      string   `json:"resolution"`
	RetryAt         int64    `json:"retryAt"`
	QuotaObservedAt float64  `json:"quotaObservedAt,omitempty"`
}

func (b *bridge) call(ctx context.Context, command, requestID, profileID, leaseID string) (bridgeReply, error) {
	// Waiting for a slot cannot consume the exchange budget. Cancellation in
	// this phase proves the command was never sent to the host.
	queueLimit := b.queueTimeout
	if queueLimit == 0 {
		queueLimit = 25 * time.Second
	}
	if command == "acquire_resolve" {
		queueLimit = b.resolveLimit()
	} else if command == "order_end" {
		queueLimit = 2 * time.Second
	}
	queue, cancelQueue := context.WithTimeout(ctx, queueLimit)
	defer cancelQueue()
	b.once.Do(func() {
		b.normal = make(chan struct{}, 6)
		b.maintenance = make(chan struct{}, 2)
		b.reconciliation = make(chan struct{}, 2)
	})
	capacity := b.normal
	if command == "acquire_resolve" {
		// Resolving an ambiguous acquire must not queue behind maintenance
		// exchanges that may themselves be stalled waiting for the host.
		capacity = b.reconciliation
	} else if command == "heartbeat" || command == "release" || command == "order_end" {
		capacity = b.maintenance
	}
	busy := bridgeReply{Error: "control_busy"}
	select {
	case capacity <- struct{}{}:
		defer func() { <-capacity }()
	case <-ctx.Done():
		return busy, nil
	case <-queue.Done():
		return busy, nil
	}
	// Once issued, a lease operation must finish or be reconciled even if its
	// HTTP client disconnects. The host gets the full exchange bound here.
	wireContext := ctx
	if command != "order" && command != "order_end" && command != "quota_recovery" {
		wireContext = context.WithoutCancel(ctx)
	}
	exchangeLimit := b.exchangeTimeout
	if exchangeLimit == 0 {
		exchangeLimit = 25 * time.Second
	}
	if command == "acquire_resolve" {
		exchangeLimit = b.resolveLimit()
	} else if command == "order_end" {
		exchangeLimit = 2 * time.Second
	}
	bounded, cancel := context.WithTimeout(wireContext, exchangeLimit)
	defer cancel()
	exchangeDeadline, _ := bounded.Deadline()
	preSendFailures := 0
	// Repeating this exact owned heartbeat cannot create a lease or revive a
	// terminal one. At most two early-EOF replays share the original full
	// exchange deadline; acquire/release and other failures do not replay.
	retryHeartbeat := command == "heartbeat" && b.runID != "" && b.key != "" && requestID != "" && profileID != "" && leaseID != ""
	heartbeatRetries := 0
	for attempt := 0; ; attempt++ {
		if ctx.Err() != nil || bounded.Err() != nil {
			return busy, nil
		}
		exchangeStarted := time.Now()
		reply, err := b.exchange(bounded, command, requestID, profileID, leaseID)
		exchangeElapsed := time.Since(exchangeStarted)
		busyRetryReserve := time.Duration(0)
		if err != nil {
			if retryHeartbeat && err.Error() == "bridge_eof" && heartbeatRetries < 2 && ctx.Err() == nil && bounded.Err() == nil {
				heartbeatRetries++
				continue
			}
			// Dial failure proves no command was sent. Retry at most three
			// connection attempts within the existing exchange budget. Other
			// lease operations retain their ambiguous post-connect outcome.
			if err.Error() != "bridge_unavailable" {
				return reply, err
			}
			preSendFailures++
			if preSendFailures >= 3 {
				return reply, err
			}
		} else {
			if reply.Error != "control_busy" {
				return reply, nil
			}
			// A busy response is authoritative only without success or payload data.
			if reply.OK || reply.LeaseID != "" || reply.AccessToken != "" || reply.AccountID != "" || len(reply.Order) != 0 || len(reply.LastResortIDs) != 0 || len(reply.DeferredIDs) != 0 || reply.ExpiresAt != 0 || reply.CreditFallback || reply.Resolution != "" || reply.RetryAt != 0 || reply.QuotaObservedAt != 0 {
				return bridgeReply{}, errors.New("bridge_invalid")
			}
			busyRetryReserve = max(exchangeElapsed, 50*time.Millisecond)
		}
		delay := time.Duration(50*(1<<min(attempt, 2))) * time.Millisecond
		// Do not turn a confirmed no-mutation reply into an unknown outcome
		// by issuing a retry that cannot fit its last observed round trip.
		if busyRetryReserve > 0 && time.Until(exchangeDeadline) <= delay+busyRetryReserve {
			return busy, nil
		}
		timer := time.NewTimer(delay)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return busy, nil
		case <-bounded.Done():
			timer.Stop()
			return busy, nil
		}
		if busyRetryReserve > 0 && time.Until(exchangeDeadline) <= busyRetryReserve {
			return busy, nil
		}
	}
}

func heartbeatTransportFailure(err error) bool {
	if err == nil {
		return false
	}
	switch err.Error() {
	case "bridge_timeout", "bridge_eof", "bridge_unavailable":
		return true
	}
	return false
}

func (b *bridge) resolveLimit() time.Duration {
	if b.resolveTimeout > 0 {
		return b.resolveTimeout
	}
	return 8 * time.Second
}

func (b *bridge) exchange(ctx context.Context, command, requestID, profileID, leaseID string) (bridgeReply, error) {
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", b.socket)
	if err != nil {
		if ctx.Err() != nil {
			return bridgeReply{}, errors.New("bridge_timeout")
		}
		return bridgeReply{}, errors.New("bridge_unavailable")
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	deadline, _ := ctx.Deadline()
	_ = conn.SetDeadline(deadline)
	if json.NewEncoder(conn).Encode(bridgeRequest{1, b.runID, b.key, command, requestID, profileID, leaseID}) != nil {
		if ctx.Err() != nil {
			return bridgeReply{}, errors.New("bridge_timeout")
		}
		return bridgeReply{}, errors.New("bridge_eof")
	}
	// A reply is committed only after its terminating newline arrives. Scanner
	// accepts a final unterminated token at EOF, which could expose credentials
	// even when the Swift writer failed and rolled the lease back.
	line, readErr := bufio.NewReaderSize(conn, 64<<10).ReadSlice('\n')
	if readErr != nil {
		var networkError net.Error
		if ctx.Err() != nil || (errors.As(readErr, &networkError) && networkError.Timeout()) {
			return bridgeReply{}, errors.New("bridge_timeout")
		}
		if errors.Is(readErr, bufio.ErrBufferFull) {
			return bridgeReply{}, errors.New("bridge_decode")
		}
		return bridgeReply{}, errors.New("bridge_eof")
	}
	var reply bridgeReply
	if json.Unmarshal(line, &reply) != nil {
		return bridgeReply{}, errors.New("bridge_decode")
	}
	return reply, nil
}
