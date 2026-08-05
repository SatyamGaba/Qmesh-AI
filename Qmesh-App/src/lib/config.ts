/**
 * ============================================================================
 *  ENGINE CONFIG — the modes the chat picker offers + how each is resolved
 * ============================================================================
 * The app talks to any OpenAI-compatible chat engine (`/v1/chat/completions`).
 * These presets mirror ARCHITECTURE_PLAN §3's mode map — local / split / remote
 * — plus a mock offline floor. A mode with no engine URL configured shows up as
 * unavailable (greyed) in the picker until its engine is wired.
 *
 * Config is read in the browser, so every engine URL/model must be a
 * `NEXT_PUBLIC_*` env var (Next only exposes those to client code). The active
 * preset id is persisted in localStorage, so switching modes needs no rebuild.
 */

export type EngineMode = "mock" | "openai";

export interface EngineConfig {
  /** "mock" = canned on-device stream (offline floor); "openai" = real engine. */
  mode: EngineMode;
  /** OpenAI-compatible base URL, including the /v1 suffix. Empty for mock. */
  baseUrl: string;
  /** Model id sent in the request body — must match the engine's /v1/models. */
  model: string;
  /** Optional bearer token; llama-server needs none, so usually empty. */
  apiKey: string;
}

export interface EnginePreset extends EngineConfig {
  /** Stable id, also the localStorage value: mock | local | split | remote. */
  id: string;
  /** Short label shown in the picker. */
  label: string;
  /** One-line description of what this mode routes to. */
  hint: string;
  /** false when this mode has no engine URL yet — shown greyed, not selectable. */
  available: boolean;
}

const MODEL = process.env.NEXT_PUBLIC_ENGINE_MODEL || "";
const API_KEY = process.env.NEXT_PUBLIC_ENGINE_API_KEY || "";

// The original single-engine var maps to the remote slot for back-compat.
const LEGACY_URL = process.env.NEXT_PUBLIC_ENGINE_BASE_URL || "";

const URLS = {
  local: process.env.NEXT_PUBLIC_ENGINE_LOCAL_URL || "",
  split: process.env.NEXT_PUBLIC_ENGINE_SPLIT_URL || "",
  remote: process.env.NEXT_PUBLIC_ENGINE_REMOTE_URL || LEGACY_URL,
};

function openaiPreset(
  id: string,
  label: string,
  hint: string,
  baseUrl: string,
): EnginePreset {
  return {
    id,
    label,
    hint,
    mode: "openai",
    baseUrl,
    model: MODEL,
    apiKey: API_KEY,
    available: baseUrl.length > 0,
  };
}

/** All modes, in the order shown in the picker. */
export const PRESETS: EnginePreset[] = [
  {
    id: "mock",
    label: "Mock",
    hint: "Canned reply — fully offline, no engine",
    mode: "mock",
    baseUrl: "",
    model: "",
    apiKey: "",
    available: true,
  },
  openaiPreset("local", "On-device", "llama.cpp running on this phone", URLS.local),
  openaiPreset("split", "Split", "Phone + laptop worker (RPC split)", URLS.split),
  openaiPreset("remote", "Remote", "Engine on the laptop", URLS.remote),
];

// Default mode: honor NEXT_PUBLIC_ENGINE_MODE, landing on the first available
// real engine when set to "openai", else the mock floor.
const DEFAULT_ID =
  process.env.NEXT_PUBLIC_ENGINE_MODE === "openai"
    ? (PRESETS.find((p) => p.mode === "openai" && p.available)?.id ?? "mock")
    : "mock";

const LS_KEY = "qmesh.engine";

/** Event fired when the active mode changes, so the picker can stay in sync. */
export const ENGINE_CHANGE_EVENT = "qmesh:engine-change";

/** The active preset id (falls back to the default on SSR / bad storage). */
export function getActivePresetId(): string {
  if (typeof window === "undefined") return DEFAULT_ID;
  try {
    const id = window.localStorage.getItem(LS_KEY);
    if (id && PRESETS.some((p) => p.id === id)) return id;
  } catch {
    // storage blocked — fall through to default
  }
  return DEFAULT_ID;
}

/** The active preset, coerced to a usable one (mock) if its engine is gone. */
export function getActivePreset(): EnginePreset {
  const id = getActivePresetId();
  const p = PRESETS.find((x) => x.id === id);
  if (p && (p.available || p.mode === "mock")) return p;
  return PRESETS[0]; // mock — always available
}

/** The engine config the adapter should use right now. */
export function getEngine(): EngineConfig {
  const p = getActivePreset();
  return { mode: p.mode, baseUrl: p.baseUrl, model: p.model, apiKey: p.apiKey };
}

/** Switch modes. No-op for unknown/unavailable ids. */
export function setActivePreset(id: string): void {
  if (typeof window === "undefined") return;
  const p = PRESETS.find((x) => x.id === id);
  if (!p || (!p.available && p.mode !== "mock")) return;
  try {
    window.localStorage.setItem(LS_KEY, id);
    window.dispatchEvent(new CustomEvent(ENGINE_CHANGE_EVENT, { detail: id }));
  } catch {
    // storage blocked — nothing to persist
  }
}

// Console helpers for tweaking without a UI: qmeshSetEngine("remote").
if (typeof window !== "undefined") {
  const w = window as unknown as Record<string, unknown>;
  w.qmeshSetEngine = setActivePreset;
  w.qmeshGetEngine = getEngine;
  w.qmeshPresets = PRESETS;
}
