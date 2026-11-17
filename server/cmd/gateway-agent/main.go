package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"netpivot/internal/control"
)

const iface = "netpivot0"

type agent struct {
	base, token, key, port string
	client                 *http.Client
	lastPeers              map[string]string
	appliedRevision        uint64
	filterReady            bool
}

func main() {
	if err := run(); err != nil {
		slog.Error("gateway agent stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	if runtime.GOOS != "linux" {
		return errors.New("gateway agent requires Linux")
	}
	base := strings.TrimSuffix(os.Getenv("NETPIVOT_AGENT_API"), "/")
	u, err := url.Parse(base)
	if err != nil || (u.Scheme != "https" && !(u.Scheme == "http" && u.Hostname() == "127.0.0.1")) ||
		u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("agent API must use HTTPS or local HTTP on 127.0.0.1")
	}
	token := os.Getenv("NETPIVOT_AGENT_TOKEN")
	port := os.Getenv("NETPIVOT_GATEWAY_PORT")
	if port == "" {
		port = "51820"
	}
	portValue, err := strconv.Atoi(port)
	if len(token) < 32 || err != nil || portValue < 1 || portValue > 65535 {
		return errors.New("invalid agent token or port")
	}
	keyPath := os.Getenv("NETPIVOT_GATEWAY_KEY_FILE")
	if keyPath == "" {
		keyPath = "/etc/netpivot/gateway.key"
	}
	keyBytes, err := os.ReadFile(keyPath)
	if err != nil {
		return errors.New("could not read gateway private key file")
	}
	key := strings.TrimSpace(string(keyBytes))
	if !validKey(key) {
		return errors.New("invalid gateway private key")
	}
	a := agent{base: base, token: token, key: key, port: port, client: &http.Client{
		Timeout:       3 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// Drop all forwarded traffic on startup until the desired peer list is applied.
	if err := a.filter(ctx, nil); err != nil {
		return err
	}
	probe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP(control.GatewayIP), Port: 41820})
	if err != nil {
		return fmt.Errorf("could not start gateway probe: %w", err)
	}
	defer probe.Close()
	go func() {
		buf := make([]byte, 64)
		for {
			n, source, err := probe.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if n == 20 && string(buf[:4]) == "NPT1" {
				_, _ = probe.WriteToUDP(buf[:n], source)
			}
		}
	}()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	failures := 0
	for {
		op, cancel := context.WithTimeout(ctx, 8*time.Second)
		err := a.sync(op)
		cancel()
		if err != nil {
			failures++
			if failures == 1 || failures%30 == 0 {
				slog.Warn("gateway reconciliation failed", "error", err)
			}
		} else if failures != 0 {
			slog.Info("gateway reconciliation recovered")
			failures = 0
		}
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

func (a *agent) api(ctx context.Context, method, path string, in, out any) error {
	var data []byte
	if in != nil {
		var err error
		data, err = json.Marshal(in)
		if err != nil {
			return err
		}
	}
	r, err := http.NewRequestWithContext(ctx, method, a.base+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	r.Header.Set("Authorization", "Bearer "+a.token)
	if in != nil {
		r.Header.Set("Content-Type", "application/json")
	}
	resp, err := a.client.Do(r)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("agent API returned status %d", resp.StatusCode)
	}
	if out != nil {
		return json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(out)
	}
	return nil
}

func validKey(key string) bool {
	raw, err := base64.StdEncoding.Strict().DecodeString(key)
	return err == nil && len(raw) == 32 && base64.StdEncoding.EncodeToString(raw) == key
}

func (a *agent) sync(ctx context.Context) error {
	var state control.GatewayState
	if err := a.api(ctx, "GET", "/v1/gateway/state", nil, &state); err != nil {
		return err
	}
	now := time.Now()
	peers := make([]control.GatewayPeer, 0, len(state.Peers))
	keys := make(map[string]string, len(state.Peers))
	usedKeys := make(map[string]bool, len(state.Peers))
	for _, p := range state.Peers {
		if !p.Expires.After(now) {
			continue
		}
		ip, err := netip.ParseAddr(p.Address)
		if err != nil || !allowedAddress(ip) || !validKey(p.Key) || p.Network == "" ||
			keys[p.Address] != "" || usedKeys[p.Key] || p.Expires.Sub(now) > control.LeaseDuration+5*time.Second {
			return errors.New("invalid desired gateway configuration")
		}
		keys[p.Address], usedKeys[p.Key] = p.Key, true
		peers = append(peers, p)
	}
	// Freeze removed and replaced addresses before touching WireGuard. Retain
	// unchanged addresses so another member joining does not interrupt games.
	unchanged := make([]control.GatewayPeer, 0, len(peers))
	changed := len(keys) != len(a.lastPeers)
	for _, p := range peers {
		if a.lastPeers[p.Address] == p.Key {
			unchanged = append(unchanged, p)
		} else {
			changed = true
		}
	}
	if changed || a.lastPeers == nil {
		if err := a.filter(ctx, unchanged); err != nil {
			return err
		}
		var wg strings.Builder
		fmt.Fprintf(&wg, "[Interface]\nPrivateKey = %s\nListenPort = %s\n", a.key, a.port)
		for _, p := range peers {
			fmt.Fprintf(&wg, "[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n", p.Key, p.Address)
		}
		if err := command(ctx, wg.String(), "wg", "syncconf", iface, "/dev/stdin"); err != nil {
			return err
		}
		a.lastPeers = keys
	}
	if changed || !a.filterReady || a.appliedRevision != state.Revision {
		a.filterReady = false
		if err := a.filter(ctx, peers); err != nil {
			return err
		}
		a.appliedRevision = state.Revision
		a.filterReady = true
	}
	return a.api(ctx, "POST", "/v1/gateway/ack", map[string]uint64{"revision": state.Revision}, nil)
}

func allowedAddress(ip netip.Addr) bool {
	if !ip.Is4() {
		return false
	}
	a := ip.As4()
	return a[0] == 10 && a[1] == 203 && a[2] > 0 && a[2] < 255 && a[3] >= 10 && a[3] < 255
}

func rules(peers []control.GatewayPeer, now time.Time) string {
	var rules strings.Builder
	rules.WriteString("flush set inet netpivot pairs\nflush set inet netpivot users\n")
	groups := map[string][]control.GatewayPeer{}
	for _, p := range peers {
		ms := p.Expires.Sub(now).Milliseconds()
		if ms <= 0 {
			continue
		}
		fmt.Fprintf(&rules, "add element inet netpivot users { %s timeout %dms }\n", p.Address, ms)
		groups[p.Network] = append(groups[p.Network], p)
	}
	for _, group := range groups {
		for _, src := range group {
			for _, dst := range group {
				if src.Address == dst.Address {
					continue
				}
				ms := min(src.Expires.Sub(now), dst.Expires.Sub(now)).Milliseconds()
				if ms > 0 {
					fmt.Fprintf(&rules, "add element inet netpivot pairs { %s . %s timeout %dms }\n", src.Address, dst.Address, ms)
				}
			}
		}
	}
	return rules.String()
}

func (a *agent) filter(ctx context.Context, peers []control.GatewayPeer) error {
	return command(ctx, rules(peers, time.Now()), "nft", "-f", "-")
}

func command(ctx context.Context, input, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = strings.NewReader(input)
	// WireGuard input includes a private key. Keep subprocess output out of logs.
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s could not apply gateway configuration: %w", name, err)
	}
	return nil
}
