package managementasset

import (
	_ "embed"
	"strings"
)

// embeddedManagementHTML is the VibeProxy Ultra management control panel, built
// from management-ui/ (single-file Vite build) and copied here at release time.
// When present, it fully replaces the upstream GitHub-hosted panel: no runtime
// download occurs and the auto-updater becomes a no-op that simply reconciles
// the on-disk copy against these bytes.
//
//go:embed management.html
var embeddedManagementHTML []byte

// HasEmbeddedManagementHTML reports whether a custom control panel is compiled in.
func HasEmbeddedManagementHTML() bool {
	return len(strings.TrimSpace(string(embeddedManagementHTML))) > 0
}

// EmbeddedManagementHTML returns the compiled-in control panel bytes (may be empty).
func EmbeddedManagementHTML() []byte {
	return embeddedManagementHTML
}
