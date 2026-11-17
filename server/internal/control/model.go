package control

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"strings"
	"time"
)

const (
	Capacity      = 8
	LeaseDuration = 5 * time.Minute
	GatewayIP     = "10.203.0.1"
)

type timeStamp = time.Time

type State struct {
	Devices    map[string]Device
	Challenges map[string]Challenge
	Tokens     map[string]Token
	Networks   map[string]*Network
	Created    map[string]string
	Quarantine map[int]timeStamp
	Revision   uint64
	Applied    uint64
	GatewayAt  time.Time
}

type Device struct{ Key, Name string }
type Challenge struct {
	Key     string
	Expires time.Time
}
type Token struct {
	Device  string
	Expires time.Time
}
type Network struct {
	Name, Owner string
	Subnet      int
	Members     map[string]*Member
	Reserved    map[int]time.Time
	Invite      Invite
}
type Invite struct {
	ID, CodeHash, TokenHash string
	Expires                 time.Time
	Uses                    int
}
type Member struct {
	Host     int
	Key      string
	Lease    string
	Expires  time.Time
	Revision uint64
}

type GatewayPeer struct {
	Network string    `json:"network_id"`
	Address string    `json:"address"`
	Key     string    `json:"public_key"`
	Expires time.Time `json:"expires_at"`
}
type GatewayState struct {
	Revision uint64        `json:"revision"`
	Peers    []GatewayPeer `json:"peers"`
}

type Options struct {
	Endpoint, GatewayKey, AgentToken, InviteOrigin string
	InviteSecret                                   []byte
}

func (o Options) Validate() error {
	host, port, err := net.SplitHostPort(o.Endpoint)
	if err != nil || host == "" || port == "" || !validKey(o.GatewayKey) {
		return errors.New("gateway endpoint or public key is invalid")
	}
	if _, err := netip.ParseAddrPort(net.JoinHostPort("127.0.0.1", port)); err != nil || port == "0" {
		return errors.New("gateway port is invalid")
	}
	u, err := url.Parse(o.InviteOrigin)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("invite origin must be an HTTPS origin without path")
	}
	if len(o.AgentToken) < 32 || len(o.InviteSecret) < 32 {
		return errors.New("agent token and invitation secret must each have at least 32 characters")
	}
	return nil
}

func randomToken() string {
	return base64.RawURLEncoding.EncodeToString(randBytes(24))
}

func randBytes(size int) []byte {
	b := make([]byte, size)
	if _, err := rand.Read(b); err != nil {
		panic("secure random source failed")
	}
	return b
}

func hash(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}

func validKey(value string) bool {
	b, err := base64.StdEncoding.Strict().DecodeString(value)
	return err == nil && len(b) == 32 && base64.StdEncoding.EncodeToString(b) == value &&
		value != "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
}

func address(subnet, host int) string {
	return fmt.Sprintf("10.203.%d.%d", subnet, host)
}

func credentials(secret []byte, id string) (token, code string) {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte("netpivot/invite/" + id))
	sum := mac.Sum(nil)
	token = base64.RawURLEncoding.EncodeToString(sum[:24])
	code = base32.NewEncoding("0123456789ABCDEFGHJKMNPQRSTVWXYZ").EncodeToString(sum[24:29])
	return
}

func codeInput(value string) string {
	return strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(value)))
}

func (s *State) prune(now time.Time) {
	for id, c := range s.Challenges {
		if !c.Expires.After(now) {
			delete(s.Challenges, id)
		}
	}
	for id, t := range s.Tokens {
		if !t.Expires.After(now) {
			delete(s.Tokens, id)
		}
	}
}
