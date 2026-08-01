package management

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// Auth-mode discovery for the management console.
//
// This endpoint is deliberately registered OUTSIDE the management auth middleware.
// The console has to know whether a key is needed *before* it can decide to ask for
// one, and the only other way to find out would be to probe an authenticated route
// with an empty key. That probe counts as a failed attempt, so five page loads would
// trip the 5-strike / 30-minute IP ban in AuthenticateManagementKey and lock the user
// out of their own localhost console.
//
// It exposes exactly one boolean and no configuration, so skipping auth here reveals
// nothing an unauthenticated caller could act on.

type authModeResponse struct {
	// AuthRequired is what the console branches on: false means "go straight in".
	AuthRequired bool `json:"authRequired"`
}

// GetAuthMode reports whether this caller must present a management key.
//
// GET /v0/management/auth-mode → {"authRequired": true|false}
//
// The answer is per-caller, not global. Auth can only be skipped for loopback
// clients: remote callers are refused outright while auth is disabled (see
// AuthenticateManagementKey), so telling them "no key needed" would be a lie that
// sends them to a console where every subsequent request 403s.
func (h *Handler) GetAuthMode(c *gin.Context) {
	if h == nil {
		c.JSON(http.StatusOK, authModeResponse{AuthRequired: true})
		return
	}

	// Peer address only, for the same reason as the middleware: a spoofed
	// X-Forwarded-For must not be able to make this answer "no key needed".
	localClient := requestIsLoopback(c)

	disableAuth := false
	if cfg := h.cfg; cfg != nil {
		disableAuth = cfg.RemoteManagement.DisableAuth
	}

	// Fail closed: anything other than "auth is off AND the caller is local" keeps the
	// login prompt, so a misread config can never drop the gate.
	c.JSON(http.StatusOK, authModeResponse{AuthRequired: !(disableAuth && localClient)})
}
