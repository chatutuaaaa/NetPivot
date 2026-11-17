package main

import (
	"strings"
	"testing"
	"time"

	"netpivot/internal/control"
)

func TestNetworkIsolationRules(t *testing.T) {
	now := time.Now()
	entries := []control.GatewayPeer{
		{Network: "first", Address: "10.203.1.10", Expires: now.Add(time.Minute)},
		{Network: "first", Address: "10.203.1.11", Expires: now.Add(30 * time.Second)},
		{Network: "first", Address: "10.203.1.12", Expires: now},
		{Network: "second", Address: "10.203.2.10", Expires: now.Add(time.Minute)},
	}
	result := rules(entries, now)
	if strings.Count(result, "add element inet netpivot pairs") != 2 ||
		!strings.Contains(result, "10.203.1.10 . 10.203.1.11 timeout 30000ms") ||
		!strings.Contains(result, "10.203.1.11 . 10.203.1.10 timeout 30000ms") ||
		strings.Contains(result, "10.203.1.12") {
		t.Fatalf("gateway generated invalid member permissions:\n%s", result)
	}
}
