import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { viteSingleFile } from 'vite-plugin-singlefile';

// viteSingleFile inlines every JS/CSS chunk into one management.html — the exact
// single-file shape the CLIProxyAPI backend serves at /management.html. The Go
// binary embeds this build (internal/managementasset/management.html), so no
// runtime GitHub download occurs.
export default defineConfig({
  base: './',
  plugins: [react(), viteSingleFile()],
  build: {
    assetsInlineLimit: 100_000_000,
    chunkSizeWarningLimit: 100_000,
    cssCodeSplit: false,
    outDir: 'dist',
    emptyOutDir: true,
  },
  server: {
    // DEV PROXY: forward management API calls to the local backend so the dev app
    // runs same-origin (apiClient BASE = ''), avoiding CORS. The Bearer header is
    // injected by the client, not the proxy.
    proxy: {
      '/v0/management': {
        target: 'http://127.0.0.1:8318',
        changeOrigin: true,
      },
    },
  },
});
