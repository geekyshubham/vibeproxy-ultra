package api

import (
	"net"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// CORS policy for the management API.
//
// The management API serves plaintext provider API keys, linked OAuth accounts and
// full config read/write. The global corsMiddleware answers every route with
// Access-Control-Allow-Origin: *, which is fine for the inference endpoints (they
// require a per-request API key that a browser would not possess) but not for these:
// the management API can be authorised purely by *where the request came from* —
// localhost, when auth is disabled — and a browser attaches that ambient authority
// automatically to requests any site can trigger.
//
// Suppressing the response headers alone would not be enough. gin's ShouldBindJSON
// ignores Content-Type, so a cross-origin
//
//	fetch(url, {method: 'POST', body: '{"value":true}'})
//
// is a CORS *simple* request: no preflight, and the write lands server-side whether or
// not the attacker can read the reply. Disallowed origins therefore have to be refused
// outright, before the handler runs.
//
// Allowed:
//   - No Origin header. Native clients (the Swift app, the TUI, curl) never send one;
//     browsers send it on every request that could carry ambient authority, including
//     form posts, so absence means "not a browser-driven cross-origin request".
//   - Same origin as the request host — the embedded console at /management.html.
//   - Loopback origins, so a `vite dev` server hitting the backend directly still works.
//     A remote attacker cannot forge these: Origin is set by the browser, not the page,
//     which is also what defeats DNS rebinding here (a rebound evil.com still sends
//     Origin: https://evil.com).

// isManagementPath reports whether a request path belongs to the management API.
//
// Matched precisely rather than by bare prefix so a future "/v0/managementsomething"
// route cannot silently inherit the management policy, or escape it.
func isManagementPath(path string) bool {
	return path == "/v0/management" || strings.HasPrefix(path, "/v0/management/")
}

// managementOriginAllowed decides whether a browser origin may talk to the management
// API, and returns the value to echo in Access-Control-Allow-Origin ("" for none).
//
// The echoed value is always the request's own Origin, never "*": with credentials in
// play a wildcard is both rejected by browsers and wrong.
func managementOriginAllowed(c *gin.Context) (origin string, allowed bool) {
	if c == nil || c.Request == nil {
		return "", false
	}

	origin = strings.TrimSpace(c.Request.Header.Get("Origin"))
	if origin == "" {
		// Not a browser cross-origin request. Nothing to allow, nothing to refuse.
		return "", true
	}
	// Some browsers send the literal "null" for opaque origins (sandboxed iframes,
	// file:// pages). That is not same-origin and must not be treated as one.
	if strings.EqualFold(origin, "null") {
		return "", false
	}

	host, ok := originHost(origin)
	if !ok {
		return "", false
	}

	// Same-origin: the console is served by this very server.
	if requestHost, okReq := hostnameOnly(c.Request.Host); okReq && host == requestHost {
		return origin, true
	}

	return origin, hostIsLoopback(host)
}

// originHost extracts the hostname from an Origin header value.
//
// Parsed by hand rather than with net/url because an Origin is a strict
// scheme://host[:port] serialisation, and url.Parse accepts far more than that —
// including values with paths or userinfo that could compare equal to the request host
// while not being the same origin at all.
func originHost(origin string) (string, bool) {
	scheme, rest, found := strings.Cut(origin, "://")
	if !found || scheme == "" || rest == "" {
		return "", false
	}
	// A real Origin has no path, query, fragment or userinfo component.
	if strings.ContainsAny(rest, "/?#@\\") {
		return "", false
	}
	return hostnameOnly(rest)
}

// hostnameOnly strips a port from a host[:port] pair and unwraps bracketed IPv6.
func hostnameOnly(hostPort string) (string, bool) {
	hostPort = strings.TrimSpace(hostPort)
	if hostPort == "" {
		return "", false
	}
	if host, _, err := net.SplitHostPort(hostPort); err == nil {
		hostPort = host
	} else if strings.HasPrefix(hostPort, "[") && strings.HasSuffix(hostPort, "]") {
		// Bracketed IPv6 with no port: "[::1]".
		hostPort = strings.TrimSuffix(strings.TrimPrefix(hostPort, "["), "]")
	}
	hostPort = strings.ToLower(strings.TrimSpace(hostPort))
	if hostPort == "" {
		return "", false
	}
	return hostPort, true
}

// hostIsLoopback reports whether a hostname refers to this machine's loopback.
//
// Only literal IPs and the reserved name "localhost" count. No DNS resolution happens
// here on purpose: resolving attacker-controlled names would make the answer depend on
// their DNS records, which is exactly the rebinding trick this needs to resist.
func hostIsLoopback(host string) bool {
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// applyManagementCORS enforces the policy above. It reports whether the request should
// continue; it has already written the response when it returns false.
func applyManagementCORS(c *gin.Context) bool {
	origin, allowed := managementOriginAllowed(c)

	// The response varies by Origin even when it is absent, so caches must not share
	// an allowed response with a request from a different origin.
	c.Header("Vary", "Origin")

	if !allowed {
		// No CORS headers on the way out, and the request never reaches the handler —
		// which is what stops a no-preflight cross-origin write.
		c.AbortWithStatus(http.StatusForbidden)
		return false
	}

	if origin != "" {
		c.Header("Access-Control-Allow-Origin", origin)
		c.Header("Access-Control-Allow-Credentials", "true")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Management-Key")
	}

	if c.Request.Method == http.MethodOptions {
		c.AbortWithStatus(http.StatusNoContent)
		return false
	}
	return true
}
