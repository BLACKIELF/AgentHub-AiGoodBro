package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"
)

func readAccountEvents1018(t *testing.T, data []byte) []event {
	t.Helper()
	var result []event
	decoder := json.NewDecoder(bytes.NewReader(data))
	for {
		var value event
		if err := decoder.Decode(&value); err == io.EOF {
			return result
		} else if err != nil {
			t.Fatal(err)
		}
		result = append(result, value)
	}
}

func TestAccountEventChangesAndControlEventsAreImmediate1018(t *testing.T) {
	var output bytes.Buffer
	emitter := &events{out: &output}
	changes := []event{
		{Event: "account", ProfileID: "A", State: "busy"},
		{Event: "account", ProfileID: "B", State: "busy"},
		{Event: "account", ProfileID: "A", State: "ready"},
		{Event: "account", ProfileID: "A", State: "quota", CooldownUntil: 100},
		{Event: "account", ProfileID: "A", State: "quota", CooldownUntil: 101},
		{Event: "account", ProfileID: "A", State: "quota", CooldownUntil: 101, ErrorCode: "quota"},
		{Event: "account", ProfileID: "A", State: "quota", CooldownUntil: 101, ErrorCode: "quota", ErrorDetail: "timeout"},
		{Event: "account", ProfileID: "A", State: "quota", CooldownUntil: 101, ErrorCode: "quota", ErrorDetail: "timeout", ResolutionDetail: "rejected"},
		{Event: "account", ProfileID: "A", State: "busy"},
	}
	for _, value := range changes {
		emitter.emit(value)
		emitter.emit(value)
	}
	want := append([]event(nil), changes...)
	for _, control := range []event{
		{Event: "ready", Port: 54876},
		{Event: "error", ErrorCode: "lease_acquire_unknown", ErrorDetail: "timeout"},
		{Event: "stopped"},
	} {
		emitter.emit(control)
		emitter.emit(control)
		want = append(want, control, control)
	}
	if got := readAccountEvents1018(t, output.Bytes()); !reflect.DeepEqual(got, want) {
		t.Fatalf("lost a real transition or control event: got=%+v want=%+v", got, want)
	}
}

func TestAccountEventSuppressionExpiresWithoutSliding1018(t *testing.T) {
	var output bytes.Buffer
	emitter := &events{out: &output}
	value := event{Event: "account", ProfileID: "A", State: "busy"}
	emitter.emit(value)
	// Move only the test's delivery clock backward; the production clock is
	// monotonic. Repeated polls must not keep pushing this deadline forward.
	previous := emitter.lastAccount["A"]
	previous.at = time.Now().Add(-900 * time.Millisecond)
	emitter.lastAccount["A"] = previous
	emitter.emit(value)
	if got := len(readAccountEvents1018(t, output.Bytes())); got != 1 {
		t.Fatalf("unchanged state repeated inside its interval: %d", got)
	}
	if !emitter.lastAccount["A"].at.Equal(previous.at) {
		t.Fatal("suppressed poll postponed the next status delivery")
	}
	previous.at = time.Now().Add(-time.Second)
	emitter.lastAccount["A"] = previous
	emitter.emit(value)
	if got := readAccountEvents1018(t, output.Bytes()); !reflect.DeepEqual(got, []event{value, value}) {
		t.Fatalf("unchanged state did not refresh after its interval: %+v", got)
	}
}

type failFirstAccountEventWriter1018 struct {
	bytes.Buffer
	failed bool
}

func (w *failFirstAccountEventWriter1018) Write(data []byte) (int, error) {
	if !w.failed {
		w.failed = true
		return 0, errors.New("fixture write failure")
	}
	return w.Buffer.Write(data)
}

func TestFailedAccountEventWriteDoesNotSuppressNextAttempt1018(t *testing.T) {
	output := &failFirstAccountEventWriter1018{}
	emitter := &events{out: output}
	value := event{Event: "account", ProfileID: "A", State: "busy"}
	emitter.emit(value)
	emitter.emit(value)
	if got := readAccountEvents1018(t, output.Bytes()); !reflect.DeepEqual(got, []event{value}) {
		t.Fatalf("failed write incorrectly suppressed the next attempt: %+v", got)
	}
}

func TestConcurrentRepeatedAccountEventsPreserveControlEvents1018(t *testing.T) {
	var output bytes.Buffer
	emitter := &events{out: &output}
	var callers sync.WaitGroup
	started := time.Now()
	for caller := 0; caller < 32; caller++ {
		callers.Add(1)
		go func(caller int) {
			defer callers.Done()
			for i := 0; i < 2_000; i++ {
				emitter.emit(event{Event: "account", ProfileID: fmt.Sprintf("fixture-%d", caller%8), State: "busy"})
			}
			emitter.emit(event{Event: "error", ErrorCode: "lease_acquire_reconciled", ErrorDetail: "timeout"})
		}(caller)
	}
	callers.Wait()
	counts := map[string]int{}
	var errors int
	for _, value := range readAccountEvents1018(t, output.Bytes()) {
		if value.Event == "account" {
			counts[value.ProfileID]++
		} else if value.Event == "error" {
			errors++
		}
	}
	maximumPerProfile := 1 + int(time.Since(started)/time.Second)
	if len(counts) != 8 || errors != 32 {
		t.Fatalf("concurrent status/control delivery changed: profiles=%v errors=%d", counts, errors)
	}
	for profile, count := range counts {
		if count > maximumPerProfile {
			t.Fatalf("profile %s produced %d duplicates, bound %d", profile, count, maximumPerProfile)
		}
	}
}

func TestRepeatedAccountEventsDoNotFillHostPipe1018(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Close(); _ = writer.Close() })
	emitter := &events{out: writer}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 10_000; i++ {
			emitter.emit(event{Event: "account", ProfileID: "fixture-account", State: "busy"})
		}
		emitter.emit(event{Event: "error", ErrorCode: "lease_acquire_unknown", ErrorDetail: "timeout"})
		emitter.emit(event{Event: "ready", Port: 54876})
	}()
	// Model the native host temporarily occupied by rendering: it has not
	// resumed reading stdout yet. Repeated status alone must not fill the pipe
	// and prevent the later critical control event from being written.
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Error("repeated account status filled the host pipe and blocked control events")
	}
	output := make(chan []byte, 1)
	go func() {
		data, _ := io.ReadAll(reader)
		output <- data
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("event writer did not recover after the host resumed reading")
	}
	_ = writer.Close()
	var data []byte
	select {
	case data = <-output:
	case <-time.After(3 * time.Second):
		t.Fatal("host pipe did not close")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	counts := map[string]int{}
	for {
		var value event
		if err := decoder.Decode(&value); err == io.EOF {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		counts[value.Event]++
	}
	if counts["account"] > 2 || counts["account"] == 0 || counts["error"] != 1 || counts["ready"] != 1 {
		t.Fatalf("unexpected status/control event counts: %v", counts)
	}
}
