package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
)

func writeReadyFile(path, address string) error {
	if path == "" {
		return nil
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() || port == "0" {
		return fmt.Errorf("ready_address")
	}
	if err := ensurePrivateDir(filepath.Dir(path)); err != nil {
		return err
	}
	file, err := openPrivateFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	if err := json.NewEncoder(file).Encode(struct {
		SchemaVersion int    `json:"schemaVersion"`
		PID           int    `json:"pid"`
		Listen        string `json:"listen"`
	}{1, os.Getpid(), address}); err != nil {
		return err
	}
	return file.Sync()
}

func validateConfiguredListen(config Config) error {
	host, port, err := net.SplitHostPort(config.Listen)
	if err == nil && port == "0" && config.ReadyFile != "" && (config.RequireToken == nil || *config.RequireToken) {
		return validateLoopback(net.JoinHostPort(host, "1"))
	}
	return validateLoopback(config.Listen)
}
