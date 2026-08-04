/**
 * ============================================================================
 *  ENGINE CONFIG — where the chat adapter sends inference requests
 * ============================================================================
 * The app talks to any OpenAI-compatible chat engine (`/v1/chat/completions`).
 * For the demo that's a llama-server on the laptop; later the same interface
 * fronts the split / all_remote / all_local modes (see ARCHITECTURE_PLAN §3).
 *
 * Resolution order (first wins), so the target can change with zero rebuild:
 *   1. localStorage override  — set at runtime from the phone (see setEngine)
 *   2. NEXT_PUBLIC_* env       — baked at build time (.env.local)
 *   3. hard-coded fallback     — the mock, so the app always has a floor
 *
 * `NEXT_PUBLIC_` is required: these are read in the browser, and Next only
 * exposes env vars with that prefix to client code.
 */

export type EngineMode = "mock" | "openai";

export interface EngineConfig {
  /** Which adapter to use. "mock" = canned on-device stream (offline floor). */
  mode: EngineMode;
  /** OpenAI-compatible base URL, including the /v1 suffix. */
  baseUrl: string;
  /** Model id sent in the request body — must match the engine's /v1/models. */
  model: string;
  /** Optional bearer token; llama-server needs none, so usually empty. */
  apiKey: string;
}

const LS_KEY = "qmesh.engine";

const ENV_DEFAULTS: EngineConfig = {
  mode: (process.env.NEXT_PUBLIC_ENGINE_MODE as EngineMode) || "mock",
  baseUrl: process.env.NEXT_PUBLIC_ENGINE_BASE_URL || "",
  model: process.env.NEXT_PUBLIC_ENGINE_MODEL || "",
  apiKey: process.env.NEXT_PUBLIC_ENGINE_API_KEY || "",
};

/**
 * Read the effective engine config. Safe on the server (SSR) — it just returns
 * the env defaults there, since localStorage only exists in the browser.
 */
export function getEngine(): EngineConfig {
  if (typeof window === "undefined") return ENV_DEFAULTS;
  try {
    const raw = window.localStorage.getItem(LS_KEY);
    if (raw) {
      const override = JSON.parse(raw) as Partial<EngineConfig>;
      return { ...ENV_DEFAULTS, ...override };
    }
  } catch {
    // Corrupt/blocked storage — fall back to env defaults.
  }
  return ENV_DEFAULTS;
}

/**
 * Persist a runtime override (e.g. from a settings screen or the console:
 * `qmeshSetEngine({ mode: "openai", baseUrl: "http://10.73.51.58:8082/v1", model: "qwen3-4b" })`).
 * Pass null to clear and fall back to env defaults.
 */
export function setEngine(override: Partial<EngineConfig> | null): void {
  if (typeof window === "undefined") return;
  if (override === null) {
    window.localStorage.removeItem(LS_KEY);
  } else {
    window.localStorage.setItem(LS_KEY, JSON.stringify(override));
  }
}

// Expose a console helper for on-device tweaking without a UI yet.
if (typeof window !== "undefined") {
  (window as unknown as { qmeshSetEngine?: typeof setEngine }).qmeshSetEngine =
    setEngine;
  (window as unknown as { qmeshGetEngine?: typeof getEngine }).qmeshGetEngine =
    getEngine;
}
