package management

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/config"
)

// authModeFor drives GetAuthMode the way gin would, for a given client IP and config.
func authModeFor(t *testing.T, clientIP string, cfg *config.Config) bool {
	t.Helper()
	gin.SetMode(gin.TestMode)

	h := &Handler{cfg: cfg, failedAttempts: make(map[string]*attemptInfo)}

	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	req := httptest.NewRequest(http.MethodGet, "/v0/management/auth-mode", nil)
	// gin derives ClientIP from RemoteAddr, which must be host:port. JoinHostPort
	// rather than string concatenation because IPv6 needs brackets ("[::1]:54321");
	// a bare "::1:54321" does not parse and the IP would come back empty.
	req.RemoteAddr = net.JoinHostPort(clientIP, "54321")
	c.Request = req

	h.GetAuthMode(c)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (the console must always get an answer)", rec.Code)
	}
	var body authModeResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("response did not unmarshal: %v (body %q)", err, rec.Body.String())
	}
	return body.AuthRequired
}

func cfgWithDisableAuth(disable bool) *config.Config {
	cfg := &config.Config{}
	cfg.RemoteManagement.DisableAuth = disable
	return cfg
}

// The whole point of the toggle: a local caller with auth disabled walks straight in.
func TestAuthModeLocalCallerWithAuthDisabledNeedsNoKey(t *testing.T) {
	for _, ip := range []string{"127.0.0.1", "::1"} {
		if authModeFor(t, ip, cfgWithDisableAuth(true)) {
			t.Errorf("authRequired = true for local caller %s with auth disabled, want false", ip)
		}
	}
}

// The guard that makes the toggle safe. Remote callers are refused outright while auth
// is disabled, so answering "no key needed" would send them to a console that 403s on
// every request. It must keep saying a key is required.
func TestAuthModeRemoteCallerAlwaysRequiresAuth(t *testing.T) {
	for _, ip := range []string{"192.168.1.50", "10.0.0.9", "203.0.113.7"} {
		if !authModeFor(t, ip, cfgWithDisableAuth(true)) {
			t.Errorf("authRequired = false for remote caller %s, want true — remote access is refused while auth is disabled", ip)
		}
	}
}

// Default config (auth on) must gate everyone, local included.
func TestAuthModeRequiresAuthWhenEnabled(t *testing.T) {
	if !authModeFor(t, "127.0.0.1", cfgWithDisableAuth(false)) {
		t.Error("authRequired = false for local caller with auth enabled, want true")
	}
	if !authModeFor(t, "192.168.1.50", cfgWithDisableAuth(false)) {
		t.Error("authRequired = false for remote caller with auth enabled, want true")
	}
}

// Fail closed: a missing config must never be read as "auth is off".
func TestAuthModeFailsClosedWithoutConfig(t *testing.T) {
	if !authModeFor(t, "127.0.0.1", nil) {
		t.Error("authRequired = false with nil config, want true (must fail closed)")
	}

	// A nil handler cannot consult config at all, so it must also fail closed.
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest(http.MethodGet, "/v0/management/auth-mode", nil)
	var nilHandler *Handler
	nilHandler.GetAuthMode(c)

	var body authModeResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("nil-handler response did not unmarshal: %v", err)
	}
	if !body.AuthRequired {
		t.Error("authRequired = false from nil handler, want true (must fail closed)")
	}
}

// The response must carry the exact field the console branches on. A rename here would
// leave AuthContext reading undefined and silently keep the gate up forever.
func TestAuthModeResponseFieldName(t *testing.T) {
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	req := httptest.NewRequest(http.MethodGet, "/v0/management/auth-mode", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	c.Request = req

	h := &Handler{cfg: cfgWithDisableAuth(true), failedAttempts: make(map[string]*attemptInfo)}
	h.GetAuthMode(c)

	var raw map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	value, ok := raw["authRequired"]
	if !ok {
		t.Fatalf("response has no \"authRequired\" field; got %v", raw)
	}
	if value != false {
		t.Errorf("authRequired = %v, want false", value)
	}
	if len(raw) != 1 {
		t.Errorf("response exposes %d fields (%v); it must reveal nothing beyond the flag", len(raw), raw)
	}
}
