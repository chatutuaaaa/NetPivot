package control

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

type testClient struct {
	token, device, key string
}

func call(api http.Handler, client testClient, method, path string, body any) *httptest.ResponseRecorder {
	data, _ := json.Marshal(body)
	req := httptest.NewRequest(method, path, bytes.NewReader(data))
	req.Header.Set("Authorization", "Bearer "+client.token)
	req.Header.Set("Idempotency-Key", "test-operation-123456")
	rec := httptest.NewRecorder()
	api.ServeHTTP(rec, req)
	return rec
}

func expect[T any](t *testing.T, rec *httptest.ResponseRecorder, status int) T {
	t.Helper()
	var result T
	if rec.Code != status {
		t.Fatalf("status %d, want %d: %s", rec.Code, status, rec.Body)
	}
	if status != 204 {
		if err := json.NewDecoder(rec.Body).Decode(&result); err != nil {
			t.Fatal(err)
		}
	}
	return result
}

func identity(t *testing.T, api http.Handler, name string) testClient {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	challenge := expect[map[string]string](t, call(api, testClient{}, "POST", "/v1/auth/challenges", map[string]string{
		"public_key": base64.StdEncoding.EncodeToString(pub),
	}), 200)["challenge"]
	signature := base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte("NetPivot session v1\n"+challenge)))
	body := map[string]string{"challenge": challenge, "signature": signature, "name": name}
	session := expect[map[string]string](t, call(api, testClient{}, "POST", "/v1/sessions", body), 200)
	expect[apiError](t, call(api, testClient{}, "POST", "/v1/sessions", body), 401)
	return testClient{session["token"], session["device_id"], base64.StdEncoding.EncodeToString(randBytes(32))}
}

func TestNetworkLifecycle(t *testing.T) {
	store := Store(&MemoryStore{})
	if dsn := os.Getenv("NETPIVOT_TEST_DATABASE_URL"); dsn != "" {
		var err error
		store, err = OpenPostgres(t.Context(), dsn)
		if err != nil {
			t.Fatal(err)
		}
		// This suite expects an empty, dedicated integration database.
		if err = store.Run(t.Context(), func(s *State) error {
			if len(s.Networks) != 0 || len(s.Devices) != 0 {
				return fmt.Errorf("test requires an empty database")
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	key := base64.StdEncoding.EncodeToString(randBytes(32))
	agent := testClient{token: randomToken()}
	api := NewAPI(store, Options{
		Endpoint: "vpn.example.com:51820", GatewayKey: key, AgentToken: agent.token,
		InviteOrigin: "https://vpn.example.com", InviteSecret: randBytes(32),
	})
	owner := identity(t, api, "Host")
	expect[apiError](t, call(api, owner, "GET", "/readyz", nil), 503)
	creation := call(api, owner, "POST", "/v1/networks", map[string]string{"name": "Farm"})
	network := expect[NetworkView](t, creation, 200)
	path := "/v1/networks/" + network.ID
	repeated := expect[NetworkView](t, call(api, owner, "POST", "/v1/networks", map[string]string{"name": "Farm"}), 200)
	if network.ID != repeated.ID {
		t.Fatal("idempotent create produced another network")
	}
	expect[apiError](t, call(api, owner, "POST", "/v1/networks", map[string]string{"name": "Other"}), 409)
	invite := expect[map[string]string](t, call(api, owner, "POST", path+"/invitations", nil), 200)
	if !strings.Contains(invite["url"], "&c="+invite["code"]) {
		t.Fatal("invalid fallback link")
	}
	devices := []testClient{owner}
	for i := 0; i < 8; i++ {
		devices = append(devices, identity(t, api, fmt.Sprintf("Guest %d", i)))
	}
	outside := identity(t, api, "Outside")
	expect[apiError](t, call(api, outside, "GET", path, nil), 404)
	expect[apiError](t, call(api, outside, "GET", "/v1/gateway/state", nil), 401)
	body := map[string]string{"credential": strings.ToLower(invite["code"][:4]) + "-" + invite["code"][4:]}
	expect[map[string]any](t, call(api, devices[1], "POST", "/v1/invitations/resolve", body), 200)
	candidates := make(chan testClient, 8)
	var wg sync.WaitGroup
	for _, device := range devices[1:] {
		wg.Go(func() {
			rec := call(api, device, "POST", "/v1/invitations/redeem", body)
			if rec.Code == 200 {
				candidates <- device
				return
			}
			data, _ := io.ReadAll(rec.Body)
			if rec.Code != 409 || !strings.Contains(string(data), "NETWORK_FULL") {
				t.Errorf("unexpected response: %d %s", rec.Code, data)
			}
		})
	}
	wg.Wait()
	close(candidates)
	joined := []testClient{owner}
	for device := range candidates {
		joined = append(joined, device)
	}
	if len(joined) != 8 {
		t.Fatalf("network has %d members, want 8", len(joined))
	}
	expect[VirtualNetworkAgain](t, call(api, joined[1], "POST", "/v1/invitations/redeem", body), 200)
	expect[apiError](t, call(api, joined[1], "DELETE", path+"/members/"+joined[2].device, nil), 403)
	for _, d := range joined {
		expect[map[string]string](t, call(api, d, "POST", path+"/connect", map[string]string{"public_key": d.key}), 200)
	}
	expect[apiError](t, call(api, owner, "GET", path+"/config", nil), 503)
	state := expect[GatewayState](t, call(api, agent, "GET", "/v1/gateway/state", nil), 200)
	if len(state.Peers) != 8 {
		t.Fatalf("gateway has %d peers, want 8", len(state.Peers))
	}
	unique := map[string]bool{}
	for _, peer := range state.Peers {
		if peer.Network != network.ID || unique[peer.Address] {
			t.Fatal("incorrect peer address allocation")
		}
		unique[peer.Address] = true
	}
	expect[any](t, call(api, agent, "POST", "/v1/gateway/ack", map[string]uint64{"revision": state.Revision}), 204)
	expect[map[string]bool](t, call(api, owner, "GET", "/readyz", nil), 200)
	victim := joined[1]
	config := expect[Snapshot](t, call(api, victim, "GET", path+"/config", nil), 200)
	if len(config.Routes) != 2 || config.PublicKey != key || config.Lease == "" {
		t.Fatal("incorrect split tunnel configuration")
	}
	expect[any](t, call(api, owner, "DELETE", path+"/members/"+victim.device, nil), 204)
	expect[apiError](t, call(api, victim, "POST", "/v1/leases/"+config.Lease+"/renew", nil), 404)
	expect[apiError](t, call(api, victim, "POST", "/v1/invitations/redeem", body), 404)
	state = expect[GatewayState](t, call(api, agent, "GET", "/v1/gateway/state", nil), 200)
	if len(state.Peers) != 7 {
		t.Fatal("removed peer still announced")
	}
	expect[any](t, call(api, owner, "DELETE", path, nil), 204)
	state = expect[GatewayState](t, call(api, agent, "GET", "/v1/gateway/state", nil), 200)
	if len(state.Peers) != 0 {
		t.Fatal("disbanded network retained peers")
	}
}

type VirtualNetworkAgain = NetworkView

func TestLeaseExpiry(t *testing.T) {
	now := time.Now()
	s := State{Networks: map[string]*Network{"net": {
		Subnet: 1, Members: map[string]*Member{"expired": {Host: 10, Expires: now}, "active": {Host: 11, Expires: now.Add(time.Minute)}},
	}}}
	output, err := (&API{}).desired(nil, &s, "", now)
	if err != nil {
		t.Fatal(err)
	}
	peers := output.(GatewayState).Peers
	if len(peers) != 1 || peers[0].Address != "10.203.1.11" {
		t.Fatalf("incorrect peers: %+v", peers)
	}
}
