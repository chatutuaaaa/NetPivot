package control

import (
	"context"
	"crypto/ed25519"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type API struct {
	store   Store
	options Options
	now     func() time.Time
	limits  limiter
}

func NewAPI(store Store, options Options) http.Handler {
	a := &API{store: store, options: options, now: time.Now}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { write(w, 200, map[string]bool{"ok": true}) })
	mux.HandleFunc("GET /readyz", a.handle(a.ready))
	mux.HandleFunc("POST /v1/auth/challenges", a.handle(a.challenge))
	mux.HandleFunc("POST /v1/sessions", a.handle(a.authenticate))
	mux.HandleFunc("GET /v1/networks", a.member(a.list))
	mux.HandleFunc("POST /v1/networks", a.member(a.create))
	mux.HandleFunc("GET /v1/networks/{id}", a.member(a.detail))
	mux.HandleFunc("POST /v1/networks/{id}/invitations", a.member(a.issueInvite))
	mux.HandleFunc("DELETE /v1/networks/{id}/invitations", a.member(a.revokeInvite))
	mux.HandleFunc("POST /v1/invitations/resolve", a.member(a.resolve))
	mux.HandleFunc("POST /v1/invitations/redeem", a.member(a.redeem))
	mux.HandleFunc("POST /v1/networks/{id}/connect", a.member(a.connect))
	mux.HandleFunc("GET /v1/networks/{id}/config", a.member(a.config))
	mux.HandleFunc("POST /v1/leases/{id}/renew", a.member(a.renew))
	mux.HandleFunc("DELETE /v1/leases/{id}", a.member(a.disconnect))
	mux.HandleFunc("PATCH /v1/networks/{id}/owner", a.member(a.transfer))
	mux.HandleFunc("DELETE /v1/networks/{id}/members/{device}", a.member(a.remove))
	mux.HandleFunc("DELETE /v1/networks/{id}", a.member(a.disband))
	mux.HandleFunc("GET /v1/gateway/state", a.agent(a.desired))
	mux.HandleFunc("POST /v1/gateway/ack", a.agent(a.ack))
	mux.HandleFunc("GET /j", a.landing)
	mux.HandleFunc("GET /invite.js", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		_, _ = io.WriteString(w, `const c = new URLSearchParams(location.hash.slice(1)).get("c"); if (/^[0-9A-HJKMNP-TV-Z]{8}$/.test(c || "")) document.getElementById("code").textContent = c;`)
	})
	return mux
}

type apiError struct {
	Status    int    `json:"-"`
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

func (e *apiError) Error() string { return e.Code }

func problem(status int, code, message string) error {
	return &apiError{Status: status, Code: code, Message: message, Retryable: status == 503 || status == 429}
}

type handler func(*http.Request, *State, string, time.Time) (any, error)

func (a *API) handle(fn handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := randomToken()
		w.Header().Set("X-Request-ID", id)
		w.Header().Set("Cache-Control", "no-store")
		r.Body = http.MaxBytesReader(w, r.Body, 8192)
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		r = r.WithContext(ctx)
		var result any
		err := a.store.Run(ctx, func(s *State) error {
			var err error
			result, err = fn(r, s, "", a.now().UTC())
			return err
		})
		if err != nil {
			var failure *apiError
			if !errors.As(err, &failure) {
				slog.Error("request storage failure", "request_id", id)
				failure = &apiError{503, "SERVICE_UNAVAILABLE", "服务暂时不可用，请重试", true}
			}
			if failure.Retryable {
				w.Header().Set("Retry-After", "2")
			}
			write(w, failure.Status, struct {
				*apiError
				RequestID string `json:"request_id"`
			}{failure, id})
			return
		}
		if result == nil {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		write(w, http.StatusOK, result)
	}
}

func write(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func decode(r *http.Request, target any) error {
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(target) != nil || d.Decode(new(any)) != io.EOF {
		return problem(400, "INVALID_BODY", "请求格式无效")
	}
	return nil
}

func bearer(r *http.Request) string {
	value, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || len(value) > 512 {
		return ""
	}
	return value
}

func (a *API) member(fn handler) http.HandlerFunc {
	return a.handle(func(r *http.Request, s *State, _ string, now time.Time) (any, error) {
		t := s.Tokens[hash(bearer(r))]
		if t.Device == "" || !t.Expires.After(now) {
			return nil, problem(401, "AUTH_REQUIRED", "设备需要重新验证")
		}
		return fn(r, s, t.Device, now)
	})
}

func (a *API) agent(fn handler) http.HandlerFunc {
	guarded := a.handle(fn)
	return func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(hash(bearer(r))), []byte(hash(a.options.AgentToken))) != 1 {
			write(w, 401, map[string]string{"code": "AUTH_REQUIRED"})
			return
		}
		guarded(w, r)
	}
}

func (a *API) ready(_ *http.Request, s *State, _ string, now time.Time) (any, error) {
	if now.Sub(s.GatewayAt) > 10*time.Second {
		return nil, problem(503, "GATEWAY_UNAVAILABLE", "连接节点暂时不可用")
	}
	return map[string]bool{"ok": true}, nil
}

type counter struct {
	next  time.Time
	count int
}
type limiter struct {
	mu      sync.Mutex
	entries map[string]counter
	sweep   time.Time
}

func (l *limiter) allow(key string, max int, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.entries == nil {
		l.entries = make(map[string]counter)
	}
	if !l.sweep.After(now) {
		for k, v := range l.entries {
			if !v.next.After(now) {
				delete(l.entries, k)
			}
		}
		l.sweep = now.Add(time.Minute)
	}
	c, exists := l.entries[key]
	if !exists && len(l.entries) >= 10000 {
		return false
	}
	if !c.next.After(now) {
		c = counter{next: now.Add(time.Minute)}
	}
	if c.count >= max {
		return false
	}
	c.count++
	l.entries[key] = c
	return true
}

func origin(r *http.Request) string {
	// NETPIVOT_TRUST_PROXY is enabled only behind the supplied private Caddy proxy.
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if trustedProxy && net.ParseIP(r.Header.Get("X-NetPivot-Client-IP")) != nil {
		return r.Header.Get("X-NetPivot-Client-IP")
	}
	return host
}

var trustedProxy bool

func TrustPrivateProxy() { trustedProxy = true }

func (a *API) challenge(r *http.Request, s *State, _ string, now time.Time) (any, error) {
	s.prune(now)
	if !a.limits.allow("challenge/"+origin(r), 60, now) || len(s.Challenges) >= 10000 {
		return nil, problem(429, "RATE_LIMITED", "操作太频繁，请稍后重试")
	}
	var input struct {
		Key string `json:"public_key"`
	}
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	if !validKey(input.Key) {
		return nil, problem(400, "INVALID_KEY", "设备公钥无效")
	}
	nonce := randomToken()
	s.Challenges[nonce] = Challenge{input.Key, now.Add(time.Minute)}
	return map[string]string{"challenge": nonce}, nil
}

func (a *API) authenticate(r *http.Request, s *State, _ string, now time.Time) (any, error) {
	if !a.limits.allow("session/"+origin(r), 60, now) {
		return nil, problem(429, "RATE_LIMITED", "操作太频繁，请稍后重试")
	}
	var input struct{ Challenge, Signature, Name string }
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	c, found := s.Challenges[input.Challenge]
	key, _ := base64.StdEncoding.DecodeString(c.Key)
	sig, _ := base64.StdEncoding.DecodeString(input.Signature)
	if !found || !c.Expires.After(now) || !ed25519.Verify(key, []byte("NetPivot session v1\n"+input.Challenge), sig) {
		return nil, problem(401, "INVALID_CHALLENGE", "设备验证失败，请重试")
	}
	delete(s.Challenges, input.Challenge)
	device := hash(c.Key)
	name := strings.TrimSpace(input.Name)
	if name == "" {
		name = "我的设备"
	}
	if utf8.RuneCountInString(name) > 40 {
		return nil, problem(400, "INVALID_NAME", "设备名称最多 40 个字符")
	}
	if _, found := s.Devices[device]; !found && len(s.Devices) >= 10000 {
		return nil, problem(503, "DEVICE_LIMIT", "服务设备数量已达上限")
	}
	s.Devices[device] = Device{c.Key, name}
	token := randomToken()
	s.Tokens[hash(token)] = Token{device, now.Add(15 * time.Minute)}
	return map[string]string{"token": token, "device_id": device}, nil
}

func (a *API) landing(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'")
	_, _ = io.WriteString(w, `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>NetPivot 邀请</title><h1>加入 NetPivot 网络</h1><p>在 iPhone 或 iPad 上安装邀请人提供的 NetPivot 测试版，重新打开链接，或在「加入网络」中输入邀请码。</p><p>邀请码 <strong id="code">请向邀请人获取</strong></p><script src="/invite.js"></script></html>`)
}
