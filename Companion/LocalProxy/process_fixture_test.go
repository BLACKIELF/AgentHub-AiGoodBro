package main

import (
	"bufio"
	"encoding/json"
	"net"
	"net/http"
	"os"
)

// This entry is compiled ONLY into the Go test binary. Production startup has
// no upstream override. Used to exercise the actual Swift Unix bridge against
// the actual Go runtime with a loopback synthetic provider in another process.
func runProtocolFixtureChild() {
	e := &events{out: os.Stdout}
	scanner := bufio.NewScanner(os.Stdin)
	if !scanner.Scan() {
		os.Exit(2)
	}
	var s startup
	if json.Unmarshal(scanner.Bytes(), &s) != nil {
		os.Exit(2)
	}
	rt, err := newRuntime(s, e, os.Getenv("AIGOODBRO_FIXTURE_UPSTREAM"))
	if err != nil {
		e.emit(event{Event: "error", ErrorCode: "fixture_start_failed"})
		os.Exit(2)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		os.Exit(2)
	}
	server := &http.Server{Handler: rt.handler}
	go server.Serve(listener)
	e.emit(event{Event: "ready", Port: listener.Addr().(*net.TCPAddr).Port})
	_ = scanner.Scan()
	_ = server.Close()
	rt.close()
	e.emit(event{Event: "stopped"})
}
