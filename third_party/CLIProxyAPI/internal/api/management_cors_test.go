package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// corsEngine builds an engine wired exactly like the production one for CORS purposes:
// the global corsMiddleware, plus a management route and a non-management route that
// both record whether the handler actually ran.
func corsEngine(t *testing.T) (*gin.Engine, *bool) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	engine.Use(corsMiddleware())

	handlerRan := false
	record := func(c *gin.Context) {
		handlerRan = true
		c.JSON(http.StatusOK, gin.H{"secret": "sk-live-plaintext-provider-key"})
	}
	for _, method := range []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
		engine.Handle(method, "/v0/management/config", record)
		engine.Handle(method, "/v1/chat/completions", record)
	}
	return engine, &handlerRan
}

func doCORS(t *testing.T, method, path, origin string) (*httptest.ResponseRecorder, bool) {
	t.Helper()
	engine, ran := corsEngine(t)
	req := httptest.NewRequest(method, path, strings.NewReader(`{"value":true}`))
	req.Host = "127.0.0.1:8318"
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)
	return rec, *ran
}

// The core vulnerability: any website the user visits can issue a no-preflight
// cross-origin request to the loopback management API. With auth disabled, the request
// is authorised by origin alone, so both reading credentials and writing config have to
// be refused before the handler runs.
func TestManagementRejectsForeignBrowserOrigins(t *testing.T) {
	foreign := []string{
		"https://evil.com",
		"http://evil.com",
		"https://sub.evil.co.uk",
		"null",                    // sandboxed iframe / file:// page
		"https://127.0.0.1.evil.com",  // loopback as a subdomain label
		"https://evil.com:127.0.0.1",  // loopback in the port position
		"https://localhost.evil.com",
		"https://evil.com/127.0.0.1",  // not a valid Origin serialisation at all
		"https://user@127.0.0.1",      // userinfo smuggling the real host
		"not-a-url",
	}

	// Every method matters, not just GET: a simple POST needs no preflight, so
	// suppressing response headers would not have prevented the write.
	for _, method := range []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
		for _, origin := range foreign {
			t.Run(method+" "+origin, func(t *testing.T) {
				rec, ran := doCORS(t, method, "/v0/management/config", origin)

				if ran {
					t.Errorf("handler ran for foreign origin %q — a cross-origin %s reached the management API", origin, method)
				}
				if rec.Code != http.StatusForbidden {
					t.Errorf("status = %d, want 403 for foreign origin %q", rec.Code, origin)
				}
				if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
					t.Errorf("Access-Control-Allow-Origin = %q, want empty for foreign origin %q", got, origin)
				}
				if strings.Contains(rec.Body.String(), "sk-live") {
					t.Errorf("response body leaked credentials to origin %q", origin)
				}
			})
		}
	}
}

// The wildcard must never appear on a management response — with credentials in play a
// browser would reject it anyway, and echoing it would defeat the whole policy.
func TestManagementNeverSendsWildcardOrigin(t *testing.T) {
	for _, origin := range []string{"", "http://127.0.0.1:8318", "https://evil.com"} {
		rec, _ := doCORS(t, http.MethodGet, "/v0/management/config", origin)
		if got := rec.Header().Get("Access-Control-Allow-Origin"); got == "*" {
			t.Errorf("management response carried ACAO: * for origin %q", origin)
		}
		if got := rec.Header().Get("Vary"); !strings.Contains(got, "Origin") {
			t.Errorf("Vary = %q, want it to include Origin so caches do not cross origins", got)
		}
	}
}

// Native clients (the Swift app, the TUI, curl) send no Origin header and must keep
// working untouched.
func TestManagementAllowsRequestsWithNoOrigin(t *testing.T) {
	for _, method := range []string{http.MethodGet, http.MethodPost, http.MethodDelete} {
		rec, ran := doCORS(t, method, "/v0/management/config", "")
		if !ran {
			t.Errorf("%s with no Origin was blocked; native clients would break", method)
		}
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 for %s with no Origin", rec.Code, method)
		}
	}
}

// The embedded console is same-origin, and a loopback dev server must also work.
func TestManagementAllowsSameOriginAndLoopback(t *testing.T) {
	allowed := []string{
		"http://127.0.0.1:8318", // the embedded console at /management.html
		"http://localhost:5173", // vite dev server
		"http://127.0.0.1:5173",
		"http://[::1]:5173",
		"https://localhost",
		"http://127.5.5.5:8080", // all of 127.0.0.0/8
	}
	for _, origin := range allowed {
		t.Run(origin, func(t *testing.T) {
			rec, ran := doCORS(t, http.MethodGet, "/v0/management/config", origin)
			if !ran {
				t.Errorf("handler did not run for allowed origin %q", origin)
			}
			if rec.Code != http.StatusOK {
				t.Errorf("status = %d, want 200 for %q", rec.Code, origin)
			}
			// Echo the origin itself, never the wildcard, so credentials are usable.
			if got := rec.Header().Get("Access-Control-Allow-Origin"); got != origin {
				t.Errorf("Access-Control-Allow-Origin = %q, want %q", got, origin)
			}
			if got := rec.Header().Get("Access-Control-Allow-Credentials"); got != "true" {
				t.Errorf("Access-Control-Allow-Credentials = %q, want true", got)
			}
		})
	}
}

// Preflights short-circuit, but only for origins that are actually allowed — an allowed
// preflight must not be the thing that green-lights a foreign origin.
func TestManagementPreflight(t *testing.T) {
	rec, _ := doCORS(t, http.MethodOptions, "/v0/management/config", "http://127.0.0.1:8318")
	if rec.Code != http.StatusNoContent {
		t.Errorf("allowed preflight status = %d, want 204", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Headers"); !strings.Contains(got, "Authorization") {
		t.Errorf("Access-Control-Allow-Headers = %q, want it to include Authorization", got)
	}

	rec, _ = doCORS(t, http.MethodOptions, "/v0/management/config", "https://evil.com")
	if rec.Code != http.StatusForbidden {
		t.Errorf("foreign preflight status = %d, want 403", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("foreign preflight echoed ACAO %q", got)
	}
}

// The inference endpoints keep the permissive wildcard: they are authorised by a
// per-request API key that a browser does not hold ambiently, and third-party web
// clients depend on the open policy.
func TestNonManagementRoutesKeepWildcardCORS(t *testing.T) {
	rec, ran := doCORS(t, http.MethodPost, "/v1/chat/completions", "https://some-web-client.example")
	if !ran {
		t.Error("inference handler was blocked; the wildcard policy must be unchanged there")
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Errorf("Access-Control-Allow-Origin = %q, want * on inference routes", got)
	}
}

func TestIsManagementPath(t *testing.T) {
	yes := []string{"/v0/management", "/v0/management/config", "/v0/management/auth-mode", "/v0/management/api-keys"}
	no := []string{"/v0/managementsomething", "/v0/management-extra", "/v1/chat/completions", "/management.html", "/", "/v0"}
	for _, p := range yes {
		if !isManagementPath(p) {
			t.Errorf("isManagementPath(%q) = false, want true", p)
		}
	}
	for _, p := range no {
		if isManagementPath(p) {
			t.Errorf("isManagementPath(%q) = true, want false", p)
		}
	}
}

func TestHostIsLoopback(t *testing.T) {
	for _, h := range []string{"localhost", "app.localhost", "127.0.0.1", "127.9.9.9", "::1", "::ffff:127.0.0.1"} {
		if !hostIsLoopback(h) {
			t.Errorf("hostIsLoopback(%q) = false, want true", h)
		}
	}
	// Names that merely look like loopback must not resolve as such — no DNS lookup
	// happens here precisely so attacker-controlled records cannot decide the answer.
	for _, h := range []string{"localhost.evil.com", "127.0.0.1.evil.com", "evil.com", "0.0.0.0", "192.168.1.1", "10.0.0.1", "", "notlocalhost"} {
		if hostIsLoopback(h) {
			t.Errorf("hostIsLoopback(%q) = true, want false", h)
		}
	}
}
