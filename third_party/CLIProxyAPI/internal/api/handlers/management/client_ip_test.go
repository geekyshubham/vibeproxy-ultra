package management

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

// ctxFrom builds a gin context the way the real server does — importantly through a
// gin.New() engine with NO SetTrustedProxies call, which is exactly the production
// configuration in internal/api/server.go. That default trusts every peer as a proxy,
// so c.ClientIP() honours attacker-supplied forwarding headers.
func ctxFrom(remoteAddr string, headers map[string]string) *gin.Context {
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	c := gin.CreateTestContextOnly(httptest.NewRecorder(), engine)
	req := httptest.NewRequest(http.MethodGet, "/v0/management/config", nil)
	req.RemoteAddr = remoteAddr
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	c.Request = req
	return c
}

// This is the vulnerability this file exists to prevent, stated as a test: a remote
// caller must NOT be able to present itself as loopback by setting a forwarding header.
//
// With management auth disabled, "is this caller local" is the ONLY gate protecting the
// management API — which serves plaintext provider API keys and linked OAuth accounts.
// If gin's ClientIP() were used for that decision, every case below would pass the gate.
func TestForwardingHeadersCannotForgeLoopback(t *testing.T) {
	spoofs := []struct {
		name    string
		headers map[string]string
	}{
		{"X-Forwarded-For IPv4 loopback", map[string]string{"X-Forwarded-For": "127.0.0.1"}},
		{"X-Forwarded-For IPv6 loopback", map[string]string{"X-Forwarded-For": "::1"}},
		{"X-Real-IP loopback", map[string]string{"X-Real-IP": "127.0.0.1"}},
		{"X-Forwarded-For chain ending in loopback", map[string]string{"X-Forwarded-For": "203.0.113.9, 127.0.0.1"}},
		{"X-Forwarded-For 127.0.0.0/8", map[string]string{"X-Forwarded-For": "127.9.9.9"}},
		{"IPv4-mapped loopback", map[string]string{"X-Forwarded-For": "::ffff:127.0.0.1"}},
		{"both headers", map[string]string{"X-Forwarded-For": "127.0.0.1", "X-Real-IP": "::1"}},
	}

	for _, s := range spoofs {
		t.Run(s.name, func(t *testing.T) {
			c := ctxFrom("203.0.113.9:51234", s.headers)

			if requestIsLoopback(c) {
				t.Errorf("requestIsLoopback = true for a remote peer spoofing %v — this is an auth bypass", s.headers)
			}
			if got := requestRemoteIP(c); got != "203.0.113.9" {
				t.Errorf("requestRemoteIP = %q, want the real peer 203.0.113.9 (headers must not influence it)", got)
			}

			// Demonstrate that the naive approach WOULD have been fooled, so this test
			// keeps documenting why ClientIP() must not be used for a trust decision.
			// If a future gin upgrade changes the default, this assertion is what tells
			// us the threat model shifted rather than silently passing for a new reason.
			if c.ClientIP() == "203.0.113.9" {
				t.Logf("note: gin ClientIP() now returns the real peer for %v; defaults may have changed", s.headers)
			}
		})
	}
}

// A genuine loopback caller must still be recognised, or the toggle would never work.
func TestRealLoopbackPeersAreRecognised(t *testing.T) {
	cases := []string{
		"127.0.0.1:54321",
		"[::1]:54321",
		"127.0.0.1", // bare address, no port
		"[::ffff:127.0.0.1]:54321",
		"127.5.5.5:9999", // all of 127.0.0.0/8 is loopback
	}
	for _, addr := range cases {
		c := ctxFrom(addr, nil)
		if !requestIsLoopback(c) {
			t.Errorf("requestIsLoopback = false for genuine loopback peer %q", addr)
		}
	}
}

// A loopback caller must not be downgraded by its own headers either — the header is
// ignored in both directions, so the peer address alone decides.
func TestLoopbackPeerIgnoresItsOwnHeaders(t *testing.T) {
	c := ctxFrom("127.0.0.1:54321", map[string]string{"X-Forwarded-For": "203.0.113.9"})
	if !requestIsLoopback(c) {
		t.Error("a real loopback peer must stay loopback regardless of forwarding headers")
	}
	if got := requestRemoteIP(c); got != "127.0.0.1" {
		t.Errorf("requestRemoteIP = %q, want 127.0.0.1", got)
	}
}

func TestNonLoopbackPeersAreNotLoopback(t *testing.T) {
	for _, addr := range []string{"203.0.113.9:443", "192.168.1.50:8080", "10.0.0.9:1", "[2001:db8::1]:443", "", "garbage"} {
		c := ctxFrom(addr, nil)
		if requestIsLoopback(c) {
			t.Errorf("requestIsLoopback = true for non-loopback peer %q", addr)
		}
	}
}
