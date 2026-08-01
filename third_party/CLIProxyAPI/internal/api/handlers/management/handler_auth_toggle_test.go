package management

import (
	"net/http"
	"testing"

	"github.com/router-for-me/CLIProxyAPI/v7/internal/config"
)

// The management console is a localhost tool, so VibeProxy Ultra lets the user turn the
// key requirement off. These tests pin the safety property that makes that acceptable:
// disabling auth must never expose management beyond the local machine, because the
// management API hands out plaintext API keys and linked accounts.

func TestDisableAuth_LocalClientNeedsNoKey(t *testing.T) {
	h := &Handler{
		cfg: &config.Config{
			RemoteManagement: config.RemoteManagement{DisableAuth: true},
		},
		failedAttempts: make(map[string]*attemptInfo),
	}

	// No secret configured anywhere and no key supplied: with auth enabled this would
	// fail "remote management key not set", which is exactly the friction being removed.
	for _, ip := range []string{"127.0.0.1", "::1"} {
		allowed, statusCode, errMsg := h.AuthenticateManagementKey(ip, true, "")
		if !allowed {
			t.Fatalf("local client %s denied with auth disabled: status=%d msg=%q", ip, statusCode, errMsg)
		}
	}
}

// The core security guard: auth off must refuse non-local callers even when the user has
// separately enabled remote management, so flipping this switch cannot silently publish
// the console through a tunnel.
func TestDisableAuth_RemoteClientRefusedEvenWhenAllowRemote(t *testing.T) {
	h := &Handler{
		cfg: &config.Config{
			RemoteManagement: config.RemoteManagement{
				DisableAuth: true,
				AllowRemote: true,
				SecretKey:   "",
			},
		},
		failedAttempts: make(map[string]*attemptInfo),
		envSecret:      "test-secret",
	}

	// Even presenting the correct key must not grant remote access while auth is off:
	// the server cannot distinguish a legitimate remote user from anyone else who
	// reached the port, so it declines rather than guessing.
	for _, provided := range []string{"", "test-secret", "wrong"} {
		allowed, statusCode, errMsg := h.AuthenticateManagementKey("203.0.113.7", false, provided)
		if allowed {
			t.Fatalf("remote client allowed with auth disabled (provided=%q)", provided)
		}
		if statusCode != http.StatusForbidden {
			t.Errorf("provided=%q: status = %d, want %d", provided, statusCode, http.StatusForbidden)
		}
		if errMsg != "management authentication is disabled, so remote access is refused" {
			t.Errorf("provided=%q: unexpected message %q", provided, errMsg)
		}
	}
}

// Regression: the disable-auth check must run BEFORE the failed-attempt ban, or a user
// who mistyped their key five times and then switched auth off would stay locked out of
// their own localhost console for the full 30-minute window.
func TestDisableAuth_ClearsPathForLocallyBannedClient(t *testing.T) {
	cfg := &config.Config{}
	h := &Handler{
		cfg:            cfg,
		failedAttempts: make(map[string]*attemptInfo),
		envSecret:      "test-secret",
	}

	// Earn a ban with auth still enabled.
	for i := 0; i < 5; i++ {
		if allowed, _, _ := h.AuthenticateManagementKey("127.0.0.1", true, "wrong-secret"); allowed {
			t.Fatalf("attempt %d unexpectedly allowed", i+1)
		}
	}
	if allowed, statusCode, _ := h.AuthenticateManagementKey("127.0.0.1", true, "test-secret"); allowed || statusCode != http.StatusForbidden {
		t.Fatalf("expected an active ban before disabling auth (allowed=%v status=%d)", allowed, statusCode)
	}

	// Now switch auth off, as a user would in Settings.
	cfg.RemoteManagement.DisableAuth = true

	allowed, statusCode, errMsg := h.AuthenticateManagementKey("127.0.0.1", true, "")
	if !allowed {
		t.Fatalf("local client still blocked after disabling auth: status=%d msg=%q", statusCode, errMsg)
	}

	// The ban must still apply to remote callers, which are refused outright.
	if allowed, _, _ := h.AuthenticateManagementKey("203.0.113.7", false, "test-secret"); allowed {
		t.Fatal("remote client must remain refused while auth is disabled")
	}
}

// With the toggle off (the default), every pre-existing rule must behave exactly as before.
func TestDisableAuthDefaultOff_PreservesKeyEnforcement(t *testing.T) {
	h := &Handler{
		cfg:            &config.Config{},
		failedAttempts: make(map[string]*attemptInfo),
		envSecret:      "test-secret",
	}

	if allowed, statusCode, _ := h.AuthenticateManagementKey("127.0.0.1", true, ""); allowed || statusCode != http.StatusUnauthorized {
		t.Errorf("missing key: allowed=%v status=%d, want denied/401", allowed, statusCode)
	}
	if allowed, _, _ := h.AuthenticateManagementKey("127.0.0.1", true, "test-secret"); !allowed {
		t.Error("correct key must still be accepted when auth is enabled")
	}
	// Remote without AllowRemote stays refused by the original rule.
	if allowed, statusCode, errMsg := h.AuthenticateManagementKey("203.0.113.7", false, "test-secret"); allowed ||
		statusCode != http.StatusForbidden || errMsg != "remote management disabled" {
		t.Errorf("remote: allowed=%v status=%d msg=%q, want denied/403/remote management disabled", allowed, statusCode, errMsg)
	}
}

// A nil config must not be read as "auth disabled" — failing open would be the worst
// possible default for an endpoint that exposes credentials.
func TestDisableAuth_NilConfigStillEnforces(t *testing.T) {
	h := &Handler{
		failedAttempts: make(map[string]*attemptInfo),
		envSecret:      "test-secret",
	}
	if allowed, _, _ := h.AuthenticateManagementKey("127.0.0.1", true, ""); allowed {
		t.Fatal("nil config must not disable authentication")
	}
}
