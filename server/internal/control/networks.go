package control

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

type MemberView struct {
	ID      string `json:"device_id"`
	Name    string `json:"name"`
	Address string `json:"address"`
	Online  bool   `json:"online"`
}

type NetworkView struct {
	ID      string       `json:"id"`
	Name    string       `json:"name"`
	Owner   string       `json:"owner_device_id"`
	Members []MemberView `json:"members"`
}

func networkView(s *State, id string, n *Network, now time.Time) NetworkView {
	members := make([]MemberView, 0, len(n.Members))
	for device, m := range n.Members {
		members = append(members, MemberView{
			device, s.Devices[device].Name, address(n.Subnet, m.Host),
			m.Expires.After(now) && m.Revision <= s.Applied && now.Sub(s.GatewayAt) <= 10*time.Second,
		})
	}
	sort.Slice(members, func(i, j int) bool { return members[i].Address < members[j].Address })
	return NetworkView{id, n.Name, n.Owner, members}
}

func membership(s *State, id, device string) (*Network, error) {
	n := s.Networks[id]
	if n == nil || n.Members[device] == nil {
		return nil, problem(404, "NETWORK_UNAVAILABLE", "网络已关闭或你已退出")
	}
	return n, nil
}

func owned(s *State, id, device string) (*Network, error) {
	n, err := membership(s, id, device)
	if err != nil {
		return nil, err
	}
	if n.Owner != device {
		return nil, problem(403, "NOT_OWNER", "只有管理员可以执行此操作")
	}
	return n, nil
}

func (a *API) list(_ *http.Request, s *State, device string, now time.Time) (any, error) {
	out := []NetworkView{}
	for id, n := range s.Networks {
		if n.Members[device] != nil {
			out = append(out, networkView(s, id, n, now))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (a *API) detail(r *http.Request, s *State, device string, now time.Time) (any, error) {
	id := r.PathValue("id")
	n, err := membership(s, id, device)
	if err != nil {
		return nil, err
	}
	return networkView(s, id, n, now), nil
}

func (a *API) create(r *http.Request, s *State, device string, now time.Time) (any, error) {
	var input struct{ Name string }
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	key := r.Header.Get("Idempotency-Key")
	if len(key) < 16 || len(key) > 100 {
		return nil, problem(400, "INVALID_IDEMPOTENCY_KEY", "缺少有效的请求标识")
	}
	name := strings.TrimSpace(input.Name)
	if name == "" {
		name = "朋友的联机网络"
	}
	if utf8.RuneCountInString(name) > 40 {
		return nil, problem(400, "INVALID_NAME", "网络名称最多 40 个字符")
	}
	key = device + "/" + key
	if id := s.Created[key]; id != "" {
		n, err := membership(s, id, device)
		if err != nil {
			return nil, err
		}
		if n.Name != name {
			return nil, problem(409, "IDEMPOTENCY_CONFLICT", "请求标识已用于其他操作")
		}
		return networkView(s, id, n, now), nil
	}
	if !a.limits.allow("create/"+device, 5, now) || !a.limits.allow("create-ip/"+origin(r), 20, now) {
		return nil, problem(429, "RATE_LIMITED", "创建太频繁，请稍后重试")
	}
	used := make(map[int]bool)
	count := 0
	for _, n := range s.Networks {
		used[n.Subnet] = true
		if n.Owner == device {
			count++
		}
	}
	if count >= 5 {
		return nil, problem(409, "OWNER_LIMIT", "每台设备最多管理 5 个网络")
	}
	for slot := 1; slot < 255; slot++ {
		if used[slot] || s.Quarantine[slot].After(now) {
			continue
		}
		n := &Network{Name: name, Owner: device, Subnet: slot, Members: map[string]*Member{device: {Host: 10}}, Reserved: map[int]time.Time{}}
		id := randomToken()
		s.Networks[id] = n
		s.Created[key] = id
		return networkView(s, id, n, now), nil
	}
	return nil, problem(503, "ADDRESS_POOL_EXHAUSTED", "服务暂时没有可分配的地址")
}

func (a *API) issueInvite(r *http.Request, s *State, device string, now time.Time) (any, error) {
	n, err := owned(s, r.PathValue("id"), device)
	if err != nil {
		return nil, err
	}
	rotate := r.URL.Query().Get("rotate") == "1"
	if n.Invite.ID == "" || !n.Invite.Expires.After(now) || n.Invite.Uses >= Capacity-1 || rotate {
		if !a.limits.allow("issue/"+device, 10, now) {
			return nil, problem(429, "RATE_LIMITED", "操作太频繁，请稍后重试")
		}
		for {
			id := randomToken()
			token, code := credentials(a.options.InviteSecret, id)
			collision := false
			for _, other := range s.Networks {
				if other.Invite.Expires.After(now) && other.Invite.CodeHash == hash(code) {
					collision = true
					break
				}
			}
			if !collision {
				n.Invite = Invite{id, hash(code), hash(token), now.Add(30 * time.Minute), 0}
				break
			}
		}
	}
	token, code := credentials(a.options.InviteSecret, n.Invite.ID)
	return struct {
		Code    string    `json:"code"`
		URL     string    `json:"url"`
		Expires time.Time `json:"expires_at"`
	}{code, a.options.InviteOrigin + "/j#t=" + token + "&c=" + code, n.Invite.Expires}, nil
}

func (a *API) revokeInvite(r *http.Request, s *State, device string, _ time.Time) (any, error) {
	n, err := owned(s, r.PathValue("id"), device)
	if err != nil {
		return nil, err
	}
	n.Invite = Invite{}
	return nil, nil
}

func (a *API) findInvite(r *http.Request, s *State, device string, now time.Time) (string, *Network, error) {
	if !a.limits.allow("invite/"+device, 10, now) || !a.limits.allow("invite-ip/"+origin(r), 30, now) {
		return "", nil, problem(429, "RATE_LIMITED", "尝试次数过多，请稍后重试")
	}
	var input struct{ Credential string }
	if err := decode(r, &input); err != nil {
		return "", nil, err
	}
	tokenDigest, codeDigest := hash(input.Credential), hash(codeInput(input.Credential))
	for id, n := range s.Networks {
		i := n.Invite
		if i.ID != "" && i.Expires.After(now) && (i.TokenHash == tokenDigest || i.CodeHash == codeDigest) &&
			(i.Uses < Capacity-1 || len(n.Members) == Capacity || n.Members[device] != nil) {
			return id, n, nil
		}
	}
	return "", nil, problem(404, "INVITE_UNAVAILABLE", "邀请已失效，请让朋友重新分享")
}

func (a *API) resolve(r *http.Request, s *State, device string, now time.Time) (any, error) {
	_, n, err := a.findInvite(r, s, device, now)
	if err != nil {
		return nil, err
	}
	return struct {
		Name    string `json:"name"`
		Inviter string `json:"inviter"`
		Count   int    `json:"count"`
	}{n.Name, s.Devices[n.Owner].Name, len(n.Members)}, nil
}

func (a *API) redeem(r *http.Request, s *State, device string, now time.Time) (any, error) {
	id, n, err := a.findInvite(r, s, device, now)
	if err != nil {
		return nil, err
	}
	if n.Members[device] != nil {
		return networkView(s, id, n, now), nil
	}
	if len(n.Members) >= Capacity {
		return nil, problem(409, "NETWORK_FULL", "网络人数已满（最多 8 台设备）")
	}
	used := make(map[int]bool)
	for _, m := range n.Members {
		used[m.Host] = true
	}
	for host := 10; host < 255; host++ {
		if used[host] || n.Reserved[host].After(now) {
			continue
		}
		n.Members[device] = &Member{Host: host}
		n.Invite.Uses++
		return networkView(s, id, n, now), nil
	}
	return nil, problem(503, "ADDRESS_POOL_EXHAUSTED", "网络暂时没有可分配的地址")
}

func (a *API) transfer(r *http.Request, s *State, device string, now time.Time) (any, error) {
	id := r.PathValue("id")
	n, err := owned(s, id, device)
	if err != nil {
		return nil, err
	}
	var input struct {
		Device string `json:"device_id"`
	}
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	if n.Members[input.Device] == nil {
		return nil, problem(404, "MEMBER_NOT_FOUND", "找不到目标成员")
	}
	if input.Device != device {
		count := 0
		for _, network := range s.Networks {
			if network.Owner == input.Device {
				count++
			}
		}
		if count >= 5 {
			return nil, problem(409, "OWNER_LIMIT", "对方管理的网络数量已达上限")
		}
	}
	n.Owner = input.Device
	n.Invite = Invite{}
	return networkView(s, id, n, now), nil
}

func (a *API) remove(r *http.Request, s *State, device string, now time.Time) (any, error) {
	id, target := r.PathValue("id"), r.PathValue("device")
	n, err := membership(s, id, device)
	if err != nil {
		return nil, err
	}
	if target != device && n.Owner != device {
		return nil, problem(403, "NOT_OWNER", "只有管理员可以移除其他成员")
	}
	if target == n.Owner {
		return nil, problem(409, "OWNER_REQUIRED", "请先转让管理权，或解散网络")
	}
	if m := n.Members[target]; m != nil {
		n.Reserved[m.Host] = now.Add(24 * time.Hour)
		delete(n.Members, target)
		n.Invite = Invite{}
		s.Revision++
	}
	return nil, nil
}

func (a *API) disband(r *http.Request, s *State, device string, now time.Time) (any, error) {
	id := r.PathValue("id")
	if s.Networks[id] == nil {
		return nil, nil
	}
	n, err := owned(s, id, device)
	if err != nil {
		return nil, err
	}
	delete(s.Networks, id)
	// Keep recent create requests idempotent across disband and retries.
	s.Quarantine[n.Subnet] = now.Add(24 * time.Hour)
	s.Revision++
	return nil, nil
}

type Snapshot struct {
	Schema    int       `json:"schema_version"`
	Network   string    `json:"network_id"`
	Revision  uint64    `json:"revision"`
	Lease     string    `json:"lease_id"`
	Expires   time.Time `json:"lease_expires_at"`
	Address   string    `json:"address"`
	Routes    []string  `json:"routes"`
	Endpoint  string    `json:"endpoint"`
	PublicKey string    `json:"public_key"`
	MTU       int       `json:"mtu"`
}

func (a *API) snapshot(s *State, id string, n *Network, m *Member, now time.Time) (any, error) {
	if !m.Expires.After(now) {
		return nil, problem(409, "LEASE_EXPIRED", "连接许可已过期，请重新连接")
	}
	if m.Revision > s.Applied || now.Sub(s.GatewayAt) > 10*time.Second {
		return nil, problem(503, "GATEWAY_PENDING", "正在准备连接节点，请稍后重试")
	}
	return Snapshot{1, id, m.Revision, m.Lease, m.Expires, address(n.Subnet, m.Host) + "/32",
		[]string{fmt.Sprintf("10.203.%d.0/24", n.Subnet), GatewayIP + "/32"}, a.options.Endpoint, a.options.GatewayKey, 1280}, nil
}

func (a *API) connect(r *http.Request, s *State, device string, now time.Time) (any, error) {
	id := r.PathValue("id")
	n, err := membership(s, id, device)
	if err != nil {
		return nil, err
	}
	var input struct {
		Key string `json:"public_key"`
	}
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	if !validKey(input.Key) || input.Key == a.options.GatewayKey {
		return nil, problem(400, "INVALID_KEY", "隧道公钥无效")
	}
	for _, other := range s.Networks {
		for memberID, m := range other.Members {
			if m.Key == input.Key && (other != n || memberID != device) {
				return nil, problem(409, "KEY_CONFLICT", "此隧道公钥已用在其他连接")
			}
		}
	}
	m := n.Members[device]
	if m.Lease == "" || !m.Expires.After(now) || m.Key != input.Key {
		if !a.limits.allow("connect/"+device, 12, now) {
			return nil, problem(429, "RATE_LIMITED", "连接太频繁，请稍后重试")
		}
		for otherID, other := range s.Networks {
			if prior := other.Members[device]; otherID != id && prior != nil {
				prior.Expires = time.Time{}
			}
		}
		s.Revision++
		m.Lease, m.Key, m.Expires, m.Revision = randomToken(), input.Key, now.Add(LeaseDuration), s.Revision
	}
	return map[string]string{"lease_id": m.Lease}, nil
}

func (a *API) config(r *http.Request, s *State, device string, now time.Time) (any, error) {
	id := r.PathValue("id")
	n, err := membership(s, id, device)
	if err != nil {
		return nil, err
	}
	return a.snapshot(s, id, n, n.Members[device], now)
}

func findLease(s *State, device, lease string) (string, *Network, *Member) {
	for id, n := range s.Networks {
		if m := n.Members[device]; m != nil && m.Lease == lease {
			return id, n, m
		}
	}
	return "", nil, nil
}

func (a *API) renew(r *http.Request, s *State, device string, now time.Time) (any, error) {
	id, _, m := findLease(s, device, r.PathValue("id"))
	if m == nil {
		return nil, problem(404, "LEASE_REVOKED", "连接已撤销，请返回网络列表")
	}
	if !m.Expires.After(now) {
		return nil, problem(409, "LEASE_EXPIRED", "连接许可已过期，请重新连接")
	}
	if m.Expires.Sub(now) <= 4*time.Minute {
		s.Revision++
		m.Expires, m.Revision = now.Add(LeaseDuration), s.Revision
		return map[string]string{"network_id": id}, nil
	}
	return map[string]string{"network_id": id}, nil
}

func (a *API) disconnect(r *http.Request, s *State, device string, _ time.Time) (any, error) {
	_, _, m := findLease(s, device, r.PathValue("id"))
	if m != nil && !m.Expires.IsZero() {
		m.Expires = time.Time{}
		s.Revision++
	}
	return nil, nil
}

func (a *API) desired(_ *http.Request, s *State, _ string, now time.Time) (any, error) {
	state := GatewayState{Revision: s.Revision, Peers: []GatewayPeer{}}
	for id, n := range s.Networks {
		for _, m := range n.Members {
			if m.Expires.After(now) {
				state.Peers = append(state.Peers, GatewayPeer{id, address(n.Subnet, m.Host), m.Key, m.Expires})
			}
		}
	}
	sort.Slice(state.Peers, func(i, j int) bool { return state.Peers[i].Address < state.Peers[j].Address })
	return state, nil
}

func (a *API) ack(r *http.Request, s *State, _ string, now time.Time) (any, error) {
	var input struct{ Revision uint64 }
	if err := decode(r, &input); err != nil {
		return nil, err
	}
	if input.Revision > s.Revision {
		return nil, problem(409, "INVALID_REVISION", "未知配置版本")
	}
	// One designated writer manages a gateway. An old ack must not commit newer state.
	s.Applied, s.GatewayAt = input.Revision, now
	return nil, nil
}
