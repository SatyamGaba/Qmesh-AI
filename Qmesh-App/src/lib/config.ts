/**
 * ============================================================================
 *  ENGINE CONFIG — the modes the chat picker offers + how each is resolved
 * ============================================================================
 * The app talks to any OpenAI-compatible chat engine (`/v1/chat/completions`).
 * These presets mirror ARCHITECTURE_PLAN §3's mode map — local / split / remote.
 * A mode with no engine URL configured shows up as unavailable (greyed) in the
 * picker until its engine is wired.
 *
 * Config resolves in two layers:
 *
 *   1. `NEXT_PUBLIC_*` env vars — the build-time defaults. Next inlines these,
 *      so they freeze at `next build`; in the Android shell they are baked into
 *      the APK's static bundle and cannot be edited on the device at all.
 *   2. localStorage overrides written by the Settings sheet — the runtime layer.
 *      This is what makes a new Wi-Fi/hotspot survivable: the laptop's LAN IP
 *      changes, you retype it in the UI, and nothing has to be rebuilt.
 *
 * Overrides win when present. A field equal to its env default is not stored,
 * so clearing an override always lands back on the built-in value.
 *
 * Everything is read at *run* time (`getEngine()` is called per message), so an
 * edit takes effect on the very next send — no remount, no lost conversation.
 */

export interface EngineConfig {
  /** OpenAI-compatible base URL, including the /v1 suffix. */
  baseUrl: string;
  /** Model id sent in the request body — must match the engine's /v1/models. */
  model: string;
  /** Optional bearer token; llama-server needs none, so usually empty. */
  apiKey: string;
}

/**
 * Why a mode can't be used right now.
 *   "unset" — no engine URL configured for it yet.
 *   "model" — configured and quite possibly running, but the selected model is
 *             not one this engine can hold (the 30B on the phone).
 */
export type BlockReason = "unset" | "model";

export interface EnginePreset extends EngineConfig {
  /** Stable id, also the localStorage value: local | split | remote. */
  id: string;
  /** Short label shown in the picker. */
  label: string;
  /** One-line description of what this mode routes to. */
  hint: string;
  /** Why this mode is unusable, or null when it is fine. */
  blockedBy: BlockReason | null;
  /** `blockedBy === null` — shown greyed and unselectable when false. */
  available: boolean;
}

/* -------------------------------------------------------------------------- */
/*  Env defaults                                                              */
/* -------------------------------------------------------------------------- */

// NEXT_PUBLIC_* vars are substituted textually at build time, so each one has to
// be spelled out as a literal — `process.env[key]` would not be replaced.
// ENV_MODEL is defined below MODEL_OPTIONS, whose first entry is its fallback.
const ENV_API_KEY = process.env.NEXT_PUBLIC_ENGINE_API_KEY || "";

// The original single-engine var maps to the remote slot for back-compat.
const LEGACY_URL = process.env.NEXT_PUBLIC_ENGINE_BASE_URL || "";

/**
 * The three real engines, in picker order. Also drives the Settings form.
 *
 * `fixed` marks an address that cannot meaningfully differ from its default.
 * On-device is the only one: scripts/phone_split.sh hardcodes both
 * `--port 8082` and the matching `adb forward`, so nothing on the phone will
 * ever answer elsewhere without editing that script. Split's port, by contrast,
 * is a `PORT=` env override the script expects you to follow, and Remote's host
 * is whatever the laptop's address is on today's network.
 */
export const ENGINE_ENDPOINTS = [
  {
    id: "local",
    label: "On-device",
    hint: "llama.cpp running on this phone",
    envUrl: process.env.NEXT_PUBLIC_ENGINE_LOCAL_URL || "",
    fixed: true,
  },
  {
    id: "split",
    label: "Split",
    hint: "Phone + laptop worker (RPC split)",
    envUrl: process.env.NEXT_PUBLIC_ENGINE_SPLIT_URL || "",
    fixed: false,
  },
  {
    id: "remote",
    label: "Remote",
    hint: "Engine on the laptop",
    envUrl: process.env.NEXT_PUBLIC_ENGINE_REMOTE_URL || LEGACY_URL,
    fixed: false,
  },
] as const;

export type EndpointId = (typeof ENGINE_ENDPOINTS)[number]["id"];

/**
 * The models the Settings dropdown offers, in menu order. `id` is the string
 * sent in the request body and has to match what the engine reports at
 * /v1/models — for llama-server that is whatever `--alias` it was launched
 * with, so this list and the launch flags must be kept in step.
 *
 * Adding a model is one entry here — nothing else in the app needs to know.
 *
 * `servedBy` is the enforced half of the size note in `hint`: an engine not
 * listed there is greyed out while this model is selected, and a send routed to
 * it is refused. Without it the picker stays happy and llama-server — which
 * ignores the `model` field in the request body and answers with whatever it
 * actually loaded — quietly returns 4B output labelled 30B.
 *
 * The first entry is the build default when `NEXT_PUBLIC_ENGINE_MODEL` is
 * unset, so keep the most broadly servable model at the top — every mode,
 * phone included, has to be able to answer with it.
 */
export const MODEL_OPTIONS = [
  {
    id: "qwen3-4b",
    label: "Qwen3 4B",
    hint: "2.2 GB — small enough for the phone, so every mode can serve it.",
    servedBy: ["local", "split", "remote"],
  },
  {
    id: "qwen3-30b-a3b",
    label: "Qwen3 30B-A3B",
    hint: "17.4 GB, MoE — laptop-side only. Use Split or Remote; the phone cannot hold it.",
    servedBy: ["split", "remote"],
  },
] as const;

/**
 * The model in force with no override set. Previously this could be the empty
 * string ("send no model name, let the engine serve whatever it loaded"), but
 * that option is gone from the picker — and a value matching no option would
 * make the select display its first entry while the form still held "", so Save
 * would silently change the model. Falling back to a real id keeps the control
 * and the value in step.
 */
const ENV_MODEL = process.env.NEXT_PUBLIC_ENGINE_MODEL || MODEL_OPTIONS[0].id;

/** Every field the Settings sheet can edit. The api key stays env-only. */
export interface EngineSettings {
  local: string;
  split: string;
  remote: string;
  model: string;
}

/** The build-time values — what the app falls back to with no overrides set. */
export const ENV_SETTINGS: EngineSettings = {
  local: ENGINE_ENDPOINTS[0].envUrl,
  split: ENGINE_ENDPOINTS[1].envUrl,
  remote: ENGINE_ENDPOINTS[2].envUrl,
  model: ENV_MODEL,
};

const SETTING_KEYS = ["local", "split", "remote", "model"] as const;

/**
 * Endpoints whose address is a constant. Overrides for these are refused on
 * both read and write, so a stale entry from an earlier build — or a hand-edited
 * one — can never pin the app to an address nothing is listening on.
 */
const FIXED_KEYS: ReadonlySet<string> = new Set(
  ENGINE_ENDPOINTS.filter((e) => e.fixed).map((e) => e.id),
);

/* -------------------------------------------------------------------------- */
/*  URL normalization                                                         */
/* -------------------------------------------------------------------------- */

/**
 * Turn whatever the user typed into a usable OpenAI-compatible base URL.
 *
 * Accepts `192.168.1.50`, `192.168.1.50:8082`, `http://host:8082` and
 * `http://host:8082/v1`, converging them all on `http://host:8082/v1`.
 * When the input carries no port, the port is taken from `template` (that
 * field's env default) — after a network change usually only the host differs,
 * so retyping just the IP should keep the port that was already working.
 *
 * Text that isn't parseable as a URL is handed back untouched rather than
 * mangled; the Test button is what tells the user it won't resolve.
 */
export function normalizeBaseUrl(input: string, template = ""): string {
  const raw = input.trim();
  if (!raw) return "";

  let url: URL;
  try {
    url = new URL(/^[a-z]+:\/\//i.test(raw) ? raw : `http://${raw}`);
  } catch {
    return raw;
  }

  if (!url.port) {
    try {
      const port = new URL(template).port;
      if (port) url.port = port;
    } catch {
      // no usable template — leave the default port for the scheme
    }
  }

  // Only supply /v1 when no path was given; a custom path is left alone.
  const path = url.pathname.replace(/\/+$/, "");
  url.pathname = path === "" ? "/v1" : path;

  return url.toString().replace(/\/+$/, "");
}

/* -------------------------------------------------------------------------- */
/*  Override storage                                                          */
/* -------------------------------------------------------------------------- */

const LS_KEY = "qmesh.engine"; // active mode id
const SETTINGS_KEY = "qmesh.settings"; // endpoint overrides
const AUTO_PRIVACY_KEY = "qmesh.autoPrivacy"; // "1" when auto-privacy is on

/** Fired when the active mode changes, so the picker can stay in sync. */
export const ENGINE_CHANGE_EVENT = "qmesh:engine-change";
/** Fired when endpoint overrides are saved or reset. */
export const SETTINGS_CHANGE_EVENT = "qmesh:settings-change";
/** Fired when the auto-privacy toggle changes. */
export const PRIVACY_CHANGE_EVENT = "qmesh:privacy-change";

/**
 * Subscribe to any config change — active mode, endpoint overrides, the
 * auto-privacy toggle, or an edit made in another tab. Shaped for
 * `useSyncExternalStore`.
 */
export function subscribeConfig(onChange: () => void): () => void {
  window.addEventListener(ENGINE_CHANGE_EVENT, onChange);
  window.addEventListener(SETTINGS_CHANGE_EVENT, onChange);
  window.addEventListener(PRIVACY_CHANGE_EVENT, onChange);
  window.addEventListener("storage", onChange);
  return () => {
    window.removeEventListener(ENGINE_CHANGE_EVENT, onChange);
    window.removeEventListener(SETTINGS_CHANGE_EVENT, onChange);
    window.removeEventListener(PRIVACY_CHANGE_EVENT, onChange);
    window.removeEventListener("storage", onChange);
  };
}

function readRaw(): string | null {
  if (typeof window === "undefined") return null;
  try {
    return window.localStorage.getItem(SETTINGS_KEY);
  } catch {
    return null; // storage blocked — env defaults only
  }
}

/** Parse stored overrides, ignoring anything malformed. */
function parseOverrides(raw: string | null): Partial<EngineSettings> {
  if (!raw) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") return {};
    const record = parsed as Record<string, unknown>;
    const out: Partial<EngineSettings> = {};
    for (const key of SETTING_KEYS) {
      if (FIXED_KEYS.has(key)) continue;
      const value = record[key];
      if (typeof value === "string" && value !== "") out[key] = value;
    }
    return out;
  } catch {
    return {};
  }
}

/** The values actually in force right now: override where set, else env. */
export function getSettings(): EngineSettings {
  const overrides = parseOverrides(readRaw());
  return { ...ENV_SETTINGS, ...overrides };
}

/**
 * Persist the Settings form. URLs are normalized first, and any field that
 * matches its env default is dropped rather than stored — so an override only
 * exists while it actually differs, and resetting a field restores the built-in
 * value even if the env default later changes.
 */
export function saveSettings(next: EngineSettings): void {
  if (typeof window === "undefined") return;

  const cleaned: EngineSettings = {
    local: normalizeBaseUrl(next.local, ENV_SETTINGS.local),
    split: normalizeBaseUrl(next.split, ENV_SETTINGS.split),
    remote: normalizeBaseUrl(next.remote, ENV_SETTINGS.remote),
    model: next.model.trim(),
  };

  const overrides: Partial<EngineSettings> = {};
  for (const key of SETTING_KEYS) {
    if (FIXED_KEYS.has(key)) continue;
    if (cleaned[key] && cleaned[key] !== ENV_SETTINGS[key]) {
      overrides[key] = cleaned[key];
    }
  }

  try {
    if (Object.keys(overrides).length === 0) {
      window.localStorage.removeItem(SETTINGS_KEY);
    } else {
      window.localStorage.setItem(SETTINGS_KEY, JSON.stringify(overrides));
    }
    window.dispatchEvent(new CustomEvent(SETTINGS_CHANGE_EVENT));
  } catch {
    // storage blocked — nothing to persist
  }
}

/** Drop every override, returning the app to its build-time config. */
export function resetSettings(): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.removeItem(SETTINGS_KEY);
    window.dispatchEvent(new CustomEvent(SETTINGS_CHANGE_EVENT));
  } catch {
    // storage blocked — nothing to clear
  }
}

/* -------------------------------------------------------------------------- */
/*  Presets                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * Which engines can serve a model id. An id matching no option — a custom or
 * hand-edited value — restricts nothing: we know its name and nothing else, so
 * second-guessing where it can run would be invention.
 */
function servedBy(modelId: string): readonly string[] | null {
  return MODEL_OPTIONS.find((m) => m.id === modelId)?.servedBy ?? null;
}

function buildPresets(s: EngineSettings): EnginePreset[] {
  const serves = servedBy(s.model);
  return ENGINE_ENDPOINTS.map((e) => {
    const blockedBy: BlockReason | null =
      s[e.id].length === 0
        ? "unset"
        : serves && !serves.includes(e.id)
          ? "model"
          : null;
    return {
      id: e.id,
      label: e.label,
      hint: e.hint,
      baseUrl: s[e.id],
      model: s.model,
      apiKey: ENV_API_KEY,
      blockedBy,
      available: blockedBy === null,
    };
  });
}

/**
 * Can this mode hold this model? Takes ids rather than a preset so the Settings
 * sheet can ask about a model the user has selected but not yet saved.
 */
export function modeCanServe(endpointId: string, modelId: string): boolean {
  const serves = servedBy(modelId);
  return !serves || serves.includes(endpointId);
}

/** Short chip shown next to a greyed mode in the picker. */
export function blockedLabel(p: EnginePreset): string | null {
  if (p.blockedBy === "unset") return "not set up";
  if (p.blockedBy === "model") return "too big";
  return null;
}

/**
 * The full sentence behind a greyed mode — used both as the Settings warning
 * and as the error text when a send lands on a blocked engine.
 */
export function blockedReason(p: EnginePreset): string | null {
  if (p.blockedBy === "unset") {
    return `${p.label} has no engine address configured. Set one up in Settings, or pick another mode.`;
  }
  if (p.blockedBy === "model") {
    const m = MODEL_OPTIONS.find((x) => x.id === p.model);
    const others = ENGINE_ENDPOINTS.filter((e) =>
      (m?.servedBy as readonly string[] | undefined)?.includes(e.id),
    ).map((e) => e.label);
    // Deliberately not splicing in the model's `hint` — it already ends with
    // its own "use Split or Remote" advice, which would say this twice.
    return `${p.label} can't hold ${m?.label ?? p.model}. Use ${formatList(others)}, or choose a smaller model in Settings.`;
  }
  return null;
}

/** "a", "a or b", "a, b or c" — for listing the modes that would work. */
function formatList(items: readonly string[]): string {
  if (items.length <= 1) return items[0] ?? "another mode";
  return `${items.slice(0, -1).join(", ")} or ${items[items.length - 1]}`;
}

/**
 * Env-only presets. Used as the server snapshot during SSR/hydration, where
 * localStorage does not exist yet.
 */
export const ENV_PRESETS: EnginePreset[] = buildPresets(ENV_SETTINGS);

// Presets are rebuilt only when the stored overrides actually change, so
// getPresets() keeps returning the same array identity between edits — which is
// what useSyncExternalStore requires to avoid re-render loops.
let cachedRaw: string | null | undefined;
let cachedPresets: EnginePreset[] = ENV_PRESETS;

/** All modes, in the order shown in the picker, with overrides applied. */
export function getPresets(): EnginePreset[] {
  if (typeof window === "undefined") return ENV_PRESETS;
  const raw = readRaw();
  if (raw !== cachedRaw) {
    cachedRaw = raw;
    const overrides = parseOverrides(raw);
    cachedPresets = raw
      ? buildPresets({ ...ENV_SETTINGS, ...overrides })
      : ENV_PRESETS;
  }
  return cachedPresets;
}

// Default mode: the first engine with a URL configured at build time, else the
// first slot (shown greyed until its endpoint is set up in Settings).
export const DEFAULT_PRESET_ID = (
  ENV_PRESETS.find((p) => p.available) ?? ENV_PRESETS[0]
).id;

/** The active preset id (falls back to the default on SSR / bad storage). */
export function getActivePresetId(): string {
  if (typeof window === "undefined") return DEFAULT_PRESET_ID;
  try {
    const id = window.localStorage.getItem(LS_KEY);
    if (id && getPresets().some((p) => p.id === id)) return id;
  } catch {
    // storage blocked — fall through to default
  }
  return DEFAULT_PRESET_ID;
}

/**
 * The active preset — exactly the one the picker is showing, blocked or not.
 *
 * This deliberately does *not* substitute a working engine when the selected
 * one is unusable. Silently answering from a different engine than the header
 * names is the same failure that let the 30B "run" on the phone: you get an
 * answer, it looks fine, and the run is mislabelled. Callers check `available`
 * and refuse instead — see modelAdapter.resolvePreset.
 */
export function getActivePreset(): EnginePreset {
  const presets = getPresets();
  const id = getActivePresetId();
  return presets.find((x) => x.id === id) ?? presets[0];
}

/** The engine config the adapter should use right now. */
export function getEngine(): EngineConfig {
  const p = getActivePreset();
  return { baseUrl: p.baseUrl, model: p.model, apiKey: p.apiKey };
}

/** Switch modes. No-op for unknown/unavailable ids. */
export function setActivePreset(id: string): void {
  if (typeof window === "undefined") return;
  const p = getPresets().find((x) => x.id === id);
  if (!p?.available) return;
  try {
    window.localStorage.setItem(LS_KEY, id);
    window.dispatchEvent(new CustomEvent(ENGINE_CHANGE_EVENT, { detail: id }));
  } catch {
    // storage blocked — nothing to persist
  }
}

/* -------------------------------------------------------------------------- */
/*  Auto-privacy                                                              */
/* -------------------------------------------------------------------------- */

/**
 * Auto-privacy = "fast by default, private when it matters": chats run on
 * Remote, but the moment a user message contains PII the chat is pinned to the
 * private engine *before* the request is built (see modelAdapter.ts). Off by
 * default — it changes routing behavior, so the user opts in via Settings.
 */
export function getAutoPrivacy(): boolean {
  if (typeof window === "undefined") return false;
  try {
    return window.localStorage.getItem(AUTO_PRIVACY_KEY) === "1";
  } catch {
    return false; // storage blocked — behave as off
  }
}

/**
 * Toggle auto-privacy. Turning it on also lands the picker on Remote — the
 * "resort to remote first" half of the feature — when Remote is configured
 * (setActivePreset no-ops otherwise).
 */
export function setAutoPrivacy(on: boolean): void {
  if (typeof window === "undefined") return;
  try {
    if (on) window.localStorage.setItem(AUTO_PRIVACY_KEY, "1");
    else window.localStorage.removeItem(AUTO_PRIVACY_KEY);
    window.dispatchEvent(new CustomEvent(PRIVACY_CHANGE_EVENT));
  } catch {
    // storage blocked — nothing to persist
  }
  if (on) setActivePreset("remote");
}

/**
 * The engine PII-bearing chats get pinned to: Split when usable, else
 * On-device — picking between the two private engines is only ever *more*
 * private, never less. Returns null when neither is usable, which now includes
 * "configured, but can't hold the selected model": callers must then refuse the
 * send rather than fall back to Remote, or the feature would leak exactly what
 * it exists to protect.
 */
export function getPrivateEngine(): EnginePreset | null {
  const presets = getPresets();
  return (
    presets.find((p) => p.id === "split" && p.available) ??
    presets.find((p) => p.id === "local" && p.available) ??
    null
  );
}

/* -------------------------------------------------------------------------- */
/*  Reachability                                                              */
/* -------------------------------------------------------------------------- */

export type Reach = "unknown" | "checking" | "up" | "down";

/**
 * Ask an engine for its /v1/models with a short timeout. Shared by the mode
 * picker's status dots and the Settings sheet's Test buttons.
 */
export async function probeEngine(
  baseUrl: string,
  apiKey = "",
  timeoutMs = 4000,
): Promise<Reach> {
  if (!baseUrl) return "down";
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(`${baseUrl.replace(/\/$/, "")}/models`, {
      headers: apiKey ? { Authorization: `Bearer ${apiKey}` } : undefined,
      signal: ctrl.signal,
    });
    return res.ok ? "up" : "down";
  } catch {
    return "down"; // network error / CORS / offline
  } finally {
    clearTimeout(timer);
  }
}

// Console helpers for tweaking without a UI: qmeshSetEngine("remote").
if (typeof window !== "undefined") {
  const w = window as unknown as Record<string, unknown>;
  w.qmeshSetEngine = setActivePreset;
  w.qmeshGetEngine = getEngine;
  w.qmeshPresets = getPresets;
  w.qmeshSettings = getSettings;
  w.qmeshAutoPrivacy = setAutoPrivacy;
}
