"use client";

import { useEffect, useState, useSyncExternalStore } from "react";
import {
  Check,
  ChevronDown,
  RotateCcw,
  X,
  Loader2,
  AlertCircle,
  ShieldCheck,
} from "lucide-react";
import {
  DEFAULT_PRESET_ID,
  ENGINE_ENDPOINTS,
  ENV_PRESETS,
  ENV_SETTINGS,
  MODEL_OPTIONS,
  getActivePresetId,
  getAutoPrivacy,
  getPresets,
  getSettings,
  modeCanServe,
  normalizeBaseUrl,
  probeEngine,
  resetSettings,
  saveSettings,
  setAutoPrivacy,
  subscribeConfig,
  type EndpointId,
  type EngineSettings,
  type Reach,
} from "@/lib/config";
import { cn } from "@/lib/cn";

const BY_ID = Object.fromEntries(ENGINE_ENDPOINTS.map((e) => [e.id, e])) as {
  [K in EndpointId]: (typeof ENGINE_ENDPOINTS)[number];
};

/** Reachability line under a field — the result of the last Test press. */
function ReachNote({ status }: { status: Reach | undefined }) {
  if (!status || status === "unknown") return null;
  return (
    <p
      className={cn(
        "mt-1.5 flex items-center gap-1.5 text-xs",
        status === "up" && "text-green-600",
        status === "down" && "text-red-600",
        status === "checking" && "text-zinc-500",
      )}
    >
      {status === "checking" && (
        <>
          <Loader2 className="size-3 animate-spin" />
          Checking…
        </>
      )}
      {status === "up" && (
        <>
          <Check className="size-3" />
          Reachable
        </>
      )}
      {status === "down" && (
        <>
          <AlertCircle className="size-3" />
          No response — is the engine running on this network?
        </>
      )}
    </p>
  );
}

/**
 * The auto-privacy switch. Applies immediately (like the mode picker), not on
 * Save — it toggles behavior, not an endpoint draft. Turning it on also lands
 * the picker on Remote: fast by default, private the moment PII shows up.
 */
function AutoPrivacyToggle() {
  const on = useSyncExternalStore(subscribeConfig, getAutoPrivacy, () => false);
  const presets = useSyncExternalStore(
    subscribeConfig,
    getPresets,
    () => ENV_PRESETS,
  );
  const privateEngine =
    presets.find((p) => p.id === "split" && p.available) ??
    presets.find((p) => p.id === "local" && p.available) ??
    null;

  return (
    <div>
      <div className="flex items-center justify-between gap-3">
        <label
          htmlFor="auto-privacy"
          className="flex items-center gap-1.5 text-sm font-medium text-foreground"
        >
          <ShieldCheck className="size-4 text-emerald-600" />
          Auto-privacy mode
        </label>
        <button
          id="auto-privacy"
          role="switch"
          aria-checked={on}
          onClick={() => setAutoPrivacy(!on)}
          className={cn(
            "relative h-6 w-11 shrink-0 rounded-full transition-colors",
            on ? "bg-emerald-500" : "bg-zinc-300",
          )}
        >
          <span
            className={cn(
              "absolute left-0.5 top-0.5 size-5 rounded-full bg-white shadow transition-transform",
              on && "translate-x-5",
            )}
          />
        </button>
      </div>
      <p className="mt-1 text-xs text-zinc-500">
        Chats use the fast Remote engine, but the moment a message contains
        personal info — an email, phone, card or ID number, address — the chat
        switches to {privateEngine ? privateEngine.label : "a private engine"}{" "}
        before anything is sent, and stays there.
      </p>
      {on && !privateEngine && (
        <p className="mt-1.5 flex items-center gap-1.5 text-xs text-red-600">
          <AlertCircle className="size-3 shrink-0" />
          No private engine is set up — messages with personal info will be held
          back until Split or On-device is configured.
        </p>
      )}
    </div>
  );
}

const INPUT_CLASS =
  "min-w-0 flex-1 rounded-xl border border-zinc-200 bg-white px-3 py-2 font-mono text-xs text-foreground outline-none placeholder:text-zinc-300 focus:border-zinc-400";
const TEST_CLASS =
  "shrink-0 rounded-xl border border-zinc-200 px-3 py-2 text-xs font-medium text-foreground hover:bg-zinc-50 disabled:opacity-40";
const SELECT_CLASS =
  "w-full appearance-none rounded-xl border border-zinc-200 bg-white px-3 py-2 pr-9 text-sm text-foreground outline-none focus:border-zinc-400";

/**
 * The model dropdown. A native `<select>` on purpose — inside the APK's WebView
 * it gets Android's own wheel picker, which beats anything reimplemented here.
 * The visible label is the section heading, so the control carries an sr-only
 * one rather than repeating the word.
 *
 * Values come from `MODEL_OPTIONS`, but a value stored by an older build (or a
 * hand-edited override) is added back as a "custom" entry: without it the select
 * would fall back to its first option and Save would silently change the model.
 *
 * Picking a model the active mode can't hold is legal — the 30B is for Split and
 * Remote — but it strands that mode, so the clash is called out here, where it
 * is caused, rather than only as a refused send later.
 */
function ModelField({
  value,
  onChange,
}: {
  value: string;
  onChange: (value: string) => void;
}) {
  const known = MODEL_OPTIONS.some((m) => m.id === value);
  const hint = MODEL_OPTIONS.find((m) => m.id === value)?.hint;
  const activeId = useSyncExternalStore(
    subscribeConfig,
    getActivePresetId,
    () => DEFAULT_PRESET_ID,
  );
  const activeLabel = ENGINE_ENDPOINTS.find((e) => e.id === activeId)?.label;
  const strandsActive = !modeCanServe(activeId, value);
  return (
    <div>
      <label htmlFor="engine-model" className="sr-only">
        Model
      </label>
      <div className="relative">
        <select
          id="engine-model"
          value={value}
          onChange={(ev) => onChange(ev.target.value)}
          className={SELECT_CLASS}
        >
          {!known && value && <option value={value}>{value} (custom)</option>}
          {MODEL_OPTIONS.map((m) => (
            <option key={m.id} value={m.id}>
              {m.label}
            </option>
          ))}
        </select>
        <ChevronDown className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2 text-zinc-400" />
      </div>
      {hint && <p className="mt-1.5 text-xs text-zinc-500">{hint}</p>}
      {strandsActive && (
        <p className="mt-1.5 flex items-center gap-1.5 text-xs text-amber-700">
          <AlertCircle className="size-3 shrink-0" />
          {activeLabel} is the mode you have selected and it can&apos;t run this
          model — switch modes, or messages will be refused rather than answered
          somewhere else.
        </p>
      )}
    </div>
  );
}

/**
 * An editable endpoint row. Defined at module scope, not inside SettingsSheet —
 * a component declared in a render body gets a fresh identity each render, which
 * would remount the input and drop focus on every keystroke.
 */
function EndpointField({
  id,
  value,
  status,
  onChange,
  onBlur,
  onRevert,
  onTest,
  hideLabel = false,
}: {
  id: EndpointId;
  value: string;
  status: Reach | undefined;
  onChange: (value: string) => void;
  onBlur: () => void;
  onRevert: () => void;
  onTest: () => void;
  /** For a field whose section heading already names it — the visible label and
   *  hint would just repeat it, and the revert button moves up to that heading. */
  hideLabel?: boolean;
}) {
  const e = BY_ID[id];
  const overridden = value !== ENV_SETTINGS[id];
  return (
    <div>
      {hideLabel ? (
        <label htmlFor={`endpoint-${id}`} className="sr-only">
          {e.label}
        </label>
      ) : (
        <>
          <div className="flex items-baseline justify-between gap-2">
            <label
              htmlFor={`endpoint-${id}`}
              className="text-sm font-medium text-foreground"
            >
              {e.label}
            </label>
            {overridden && (
              <button
                onClick={onRevert}
                className="flex items-center gap-1 text-xs text-zinc-500 hover:text-foreground"
              >
                <RotateCcw className="size-3" />
                Default
              </button>
            )}
          </div>
          <p className="text-xs text-zinc-500">{e.hint}</p>
        </>
      )}
      <div className={cn("flex items-center gap-2", !hideLabel && "mt-1.5")}>
        <input
          id={`endpoint-${id}`}
          type="text"
          inputMode="url"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          value={value}
          onChange={(ev) => onChange(ev.target.value)}
          // Canonicalize on blur so the shorthand's result is visible.
          onBlur={onBlur}
          placeholder={ENV_SETTINGS[id] || "http://192.168.1.50:8082/v1"}
          className={INPUT_CLASS}
        />
        <button
          onClick={onTest}
          disabled={!value || status === "checking"}
          className={TEST_CLASS}
        >
          Test
        </button>
      </div>
      <ReachNote status={status} />
    </div>
  );
}

/**
 * Runtime engine settings. The env vars in `.env.local` are inlined at build
 * time — and baked into the APK for the Android shell — so they can't be edited
 * on the device. This sheet layers localStorage overrides on top of them, which
 * is what makes joining a different Wi-Fi/hotspot a retype instead of a rebuild.
 *
 * Model and the Remote address lead, because those are the two things that
 * actually change during a session — the model when you want a bigger one, the
 * address when you join a different Wi-Fi or hotspot. The rest sit under
 * Advanced: Split's port changes only if you launch the server on a different
 * one, and On-device is shown read-only because scripts/phone_split.sh
 * hardcodes both its port and the matching adb forward.
 */
export function SettingsSheet({
  open,
  onClose,
}: {
  open: boolean;
  onClose: () => void;
}) {
  const [form, setForm] = useState<EngineSettings>(ENV_SETTINGS);
  const [reach, setReach] = useState<Partial<Record<EndpointId, Reach>>>({});
  const [saved, setSaved] = useState(false);

  // Load the values in force each time the sheet opens, so it never shows a
  // stale draft from a previous visit (or an edit made in another tab). Done
  // during render rather than in an effect — the panel stays mounted for its
  // slide transition, so there's no remount to reinitialize state for.
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setForm(getSettings());
      setReach({});
      setSaved(false);
    }
  }

  // Escape closes, matching the scrim tap.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  function setField(key: keyof EngineSettings, value: string) {
    setForm((f) => ({ ...f, [key]: value }));
    setSaved(false);
  }

  async function test(id: EndpointId) {
    // Fixed endpoints aren't editable, so probe the value in force as-is.
    const url = BY_ID[id].fixed
      ? ENV_SETTINGS[id]
      : normalizeBaseUrl(form[id], ENV_SETTINGS[id]);
    if (!BY_ID[id].fixed) setForm((f) => ({ ...f, [id]: url }));
    setReach((r) => ({ ...r, [id]: "checking" }));
    const status = await probeEngine(url);
    setReach((r) => ({ ...r, [id]: status }));
  }

  /** Wires one editable endpoint row to this component's state. */
  function endpointProps(id: EndpointId) {
    return {
      id,
      value: form[id],
      status: reach[id],
      onChange: (v: string) => setField(id, v),
      onBlur: () =>
        setForm((f) => ({
          ...f,
          [id]: normalizeBaseUrl(f[id], ENV_SETTINGS[id]),
        })),
      onRevert: () => setField(id, ENV_SETTINGS[id]),
      onTest: () => test(id),
    };
  }

  function handleSave() {
    saveSettings(form);
    setForm(getSettings()); // reflect the normalized values back into the form
    setSaved(true);
  }

  function handleResetAll() {
    resetSettings();
    setForm(ENV_SETTINGS);
    setReach({});
    setSaved(false);
  }

  // Compare against what's actually persisted so the button can report "Saved"
  // until the next edit.
  const persisted =
    typeof window === "undefined" ? ENV_SETTINGS : getSettings();
  const dirty = (["local", "split", "remote", "model"] as const).some(
    (k) => form[k] !== persisted[k],
  );

  const local = BY_ID.local;

  return (
    <>
      {/* Scrim */}
      <div
        onClick={onClose}
        className={cn(
          "fixed inset-0 z-40 bg-black/40 transition-opacity",
          open ? "opacity-100" : "pointer-events-none opacity-0",
        )}
        aria-hidden={!open}
      />

      <aside
        role="dialog"
        aria-modal={open}
        aria-label="Settings"
        // Keeps the offscreen panel out of the tab order while closed.
        inert={!open}
        className={cn(
          "fixed inset-y-0 right-0 z-50 flex w-[92%] max-w-sm flex-col bg-background shadow-xl transition-transform",
          open ? "translate-x-0" : "translate-x-full",
        )}
      >
        <div className="flex items-center justify-between border-b border-zinc-200 px-4 pb-3 pt-[max(0.75rem,env(safe-area-inset-top))]">
          <span className="text-sm font-semibold text-foreground">
            Settings
          </span>
          <button
            onClick={onClose}
            aria-label="Close settings"
            className="grid size-8 place-items-center rounded-full text-zinc-500 hover:bg-zinc-100"
          >
            <X className="size-5" />
          </button>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto px-4 py-4">
          <h2 className="text-xs font-semibold uppercase tracking-wide text-zinc-400">
            Privacy
          </h2>
          <div className="mt-4">
            <AutoPrivacyToggle />
          </div>

          <div className="mt-8 flex items-baseline justify-between gap-2">
            <h2 className="text-xs font-semibold uppercase tracking-wide text-zinc-400">
              Model
            </h2>
            {form.model !== ENV_SETTINGS.model && (
              <button
                onClick={() => setField("model", ENV_SETTINGS.model)}
                className="flex items-center gap-1 text-xs text-zinc-500 hover:text-foreground"
              >
                <RotateCcw className="size-3" />
                Default
              </button>
            )}
          </div>
          <p className="mt-1 text-xs text-zinc-500">
            Sent with every request — it has to match what the engine has
            loaded.
          </p>

          <div className="mt-4">
            <ModelField
              value={form.model}
              onChange={(v) => setField("model", v)}
            />
          </div>

          <div className="mt-8 flex items-baseline justify-between gap-2">
            <h2 className="text-xs font-semibold uppercase tracking-wide text-zinc-400">
              Remote server address
            </h2>
            {form.remote !== ENV_SETTINGS.remote && (
              <button
                onClick={() => setField("remote", ENV_SETTINGS.remote)}
                className="flex items-center gap-1 text-xs text-zinc-500 hover:text-foreground"
              >
                <RotateCcw className="size-3" />
                Default
              </button>
            )}
          </div>
          <p className="mt-1 text-xs text-zinc-500">
            Type just the laptop&apos;s IP — the port and{" "}
            <code className="text-[11px]">/v1</code> are filled in for you.
          </p>

          <div className="mt-4">
            <EndpointField {...endpointProps("remote")} hideLabel />
          </div>

          <details className="group mt-8">
            <summary className="cursor-pointer list-none text-xs font-semibold uppercase tracking-wide text-zinc-400 hover:text-zinc-600">
              Advanced
              <span className="ml-1 font-normal normal-case tracking-normal text-zinc-400 group-open:hidden">
                — split &amp; on-device ports
              </span>
            </summary>

            <div className="mt-4 space-y-5">
              <EndpointField {...endpointProps("split")} />

              {/* Read-only: phone_split.sh hardcodes this port and its adb
                  forward, so nothing would answer on a different one. */}
              <div>
                <span className="text-sm font-medium text-foreground">
                  {local.label}
                </span>
                <p className="text-xs text-zinc-500">{local.hint}</p>
                <div className="mt-1.5 flex items-center gap-2">
                  <code className="min-w-0 flex-1 truncate rounded-xl border border-dashed border-zinc-200 bg-zinc-50 px-3 py-2 font-mono text-xs text-zinc-500">
                    {ENV_SETTINGS.local || "not configured"}
                  </code>
                  <button
                    onClick={() => test("local")}
                    disabled={!ENV_SETTINGS.local || reach.local === "checking"}
                    className={TEST_CLASS}
                  >
                    Test
                  </button>
                </div>
                <ReachNote status={reach.local} />
                <p className="mt-1.5 text-xs text-zinc-400">
                  Fixed — the phone always serves on this port.
                </p>
              </div>

              <button
                onClick={handleResetAll}
                className="text-xs text-zinc-500 underline underline-offset-2 hover:text-foreground"
              >
                Reset all to build defaults
              </button>
            </div>
          </details>
        </div>

        <div className="border-t border-zinc-200 px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-3">
          <button
            onClick={handleSave}
            className="w-full rounded-xl bg-foreground px-3 py-2.5 text-sm font-medium text-background hover:opacity-90"
          >
            {saved && !dirty ? "Saved" : "Save"}
          </button>
          <p className="mt-2 text-center text-xs text-zinc-400">
            Applies to your next message.
          </p>
        </div>
      </aside>
    </>
  );
}
