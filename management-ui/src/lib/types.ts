/* ============================================================================
   types — shapes returned by the CLIProxyAPI /v0/management/* endpoints.
   Field names mirror the backend JSON exactly. All collection fields may arrive
   as null; consumers normalize via asArray()/pluckArray().
   ========================================================================== */

/** One OAuth token / auth file under ~/.cli-proxy-api (GET /auth-files → files[]). */
export interface AuthFile {
  auth_index: string;
  created_at: string;
  disabled: boolean;
  failed: number;
  id: string;
  label: string;
  modtime: string;
  name: string;
  path: string;
  provider: string;
  recent_requests?: number[] | null;
  runtime_only: boolean;
  size: number;
  source: string;
  status: string;
  status_message: string;
  success: number;
  type: string;
  unavailable: boolean;
  updated_at: string;
}

/** One entry in an OpenAI-compatible provider's api-key-entries. */
export interface CompatKeyEntry {
  'api-key': string;
  'auth-index'?: string;
}

/** One model alias mapping. */
export interface CompatModel {
  name: string;
  alias: string;
}

/** One OpenAI-compatible provider (GET /openai-compatibility → openai-compatibility[]). */
export interface CompatProvider {
  name: string;
  'display-name'?: string;
  disabled: boolean;
  'base-url': string;
  'api-key-entries': CompatKeyEntry[] | null;
  models: CompatModel[] | null;
}

/** Backend configuration object (GET /config) — partial; only fields we read. */
export interface BackendConfig {
  'proxy-url': string;
  debug: boolean;
  'request-log': boolean;
  'logging-to-file': boolean;
  'usage-statistics-enabled': boolean;
  'request-retry': number;
  'logs-max-total-size-mb'?: number;
  'api-keys': string[] | null;
  'gemini-api-key': string[] | null;
  'claude-api-key': string[] | null;
  'codex-api-key': string[] | null;
  'vertex-api-key': string[] | null;
  'openai-compatibility': CompatProvider[] | null;
  'quota-exceeded'?: { 'switch-project'?: boolean; 'switch-preview-model'?: boolean };
  [key: string]: unknown;
}

/** One request-log line (GET /logs → logs[] when logging enabled). */
export interface LogLine {
  time?: string;
  timestamp?: string;
  level?: string;
  model?: string;
  status?: number;
  message?: string;
  [key: string]: unknown;
}
