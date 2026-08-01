package management

import (
	"net"

	"github.com/gin-gonic/gin"
)

// Trust decisions for management requests must never come from gin's ClientIP().
//
// The engine is built with gin.New() and never calls SetTrustedProxies, so gin runs its
// defaults: every peer is a trusted proxy and ClientIP() returns the value of the
// caller's own X-Forwarded-For / X-Real-IP header. Deriving "is this caller local" from
// that header lets any remote caller claim to be 127.0.0.1 — which, with auth disabled,
// would hand an unauthenticated attacker the management API and therefore plaintext
// provider API keys and linked OAuth accounts.
//
// The TCP peer address cannot be forged the same way (a spoofed source address does not
// complete a TCP handshake), so loopback checks use RemoteAddr exclusively.

// requestIsLoopback reports whether the request arrived over the loopback interface,
// judged only by the connection's peer address.
//
// IsLoopback covers all the forms that matter: 127.0.0.0/8 (not just 127.0.0.1), ::1,
// and the IPv4-mapped ::ffff:127.0.0.1 that Go normalises into a 4-in-6 address.
func requestIsLoopback(c *gin.Context) bool {
	if c == nil || c.Request == nil {
		return false
	}
	ip := requestRemoteIP(c)
	if ip == "" {
		return false
	}
	parsed := net.ParseIP(ip)
	return parsed != nil && parsed.IsLoopback()
}

// requestRemoteIP returns the peer IP from RemoteAddr, with no header involvement.
//
// This is also the correct key for failed-attempt bookkeeping: keying the ban map on a
// client-supplied header would let an attacker rotate the header to get unlimited
// key guesses, and would let them poison another caller's entry.
func requestRemoteIP(c *gin.Context) string {
	if c == nil || c.Request == nil {
		return ""
	}
	addr := c.Request.RemoteAddr
	if addr == "" {
		return ""
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		// Some transports (and httptest defaults) supply a bare address with no port.
		if net.ParseIP(addr) != nil {
			return addr
		}
		return ""
	}
	return host
}
