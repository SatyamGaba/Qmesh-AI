"use client";

import { useEffect, useState } from "react";
import { Check, RotateCcw, X, Loader2, AlertCircle } from "lucide-react";
import {
  ENGINE_ENDPOINTS,
  ENV_SETTINGS,
  getSettings,
  normalizeBaseUrl,
  probeEngine,
  resetSettings,
  saveSettings,
  type EndpointId,
  type EngineSettings,
  type Reach,
} from "@/lib/config";
import { cn } from "@/lib/cn";

/**
 * Runtime engine settings. The env vars in `.env.local` are inlined at build
 * time — and baked into the APK for the Android shell — so they can't be edited
 * on the device. This sheet layers localStorage overrides on top of them, which
 * is what makes joining a different Wi-Fi/hotspot a retype instead of a rebuild.
 *
 * Each field starts on the value in force and shows a revert control once it
 * differs from the build-time default. Test probes /v1/models so a new address
 * can be confirmed before leaving the sheet.
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

  /** Canonicalize on blur so the user can see what their shorthand became. */
  function normalizeField(id: EndpointId) {
    setForm((f) => ({ ...f, [id]: normalizeBaseUrl(f[id], ENV_SETTINGS[id]) }));
  }

  async function test(id: EndpointId) {
    const url = normalizeBaseUrl(form[id], ENV_SETTINGS[id]);
    setForm((f) => ({ ...f, [id]: url }));
    setReach((r) => ({ ...r, [id]: "checking" }));
    const status = await probeEngine(url);
    setReach((r) => ({ ...r, [id]: status }));
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
  const persisted = typeof window === "undefined" ? ENV_SETTINGS : getSettings();
  const dirty = (["local", "split", "remote", "model"] as const).some(
    (k) => form[k] !== persisted[k],
  );

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
          <span className="text-sm font-semibold text-foreground">Settings</span>
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
            Engine endpoints
          </h2>
          <p className="mt-1 text-xs text-zinc-500">
            Address of each engine as seen from this device. Type just an IP and
            the port and <code className="text-[11px]">/v1</code> are filled in
            for you.
          </p>

          <div className="mt-4 space-y-5">
            {ENGINE_ENDPOINTS.map((e) => {
              const status = reach[e.id];
              const overridden = form[e.id] !== ENV_SETTINGS[e.id];
              return (
                <div key={e.id}>
                  <div className="flex items-baseline justify-between gap-2">
                    <label
                      htmlFor={`endpoint-${e.id}`}
                      className="text-sm font-medium text-foreground"
                    >
                      {e.label}
                    </label>
                    {overridden && (
                      <button
                        onClick={() => setField(e.id, ENV_SETTINGS[e.id])}
                        className="flex items-center gap-1 text-xs text-zinc-500 hover:text-foreground"
                      >
                        <RotateCcw className="size-3" />
                        Default
                      </button>
                    )}
                  </div>
                  <p className="text-xs text-zinc-500">{e.hint}</p>

                  <div className="mt-1.5 flex items-center gap-2">
                    <input
                      id={`endpoint-${e.id}`}
                      type="text"
                      inputMode="url"
                      autoCapitalize="none"
                      autoCorrect="off"
                      spellCheck={false}
                      value={form[e.id]}
                      onChange={(ev) => setField(e.id, ev.target.value)}
                      onBlur={() => normalizeField(e.id)}
                      placeholder={ENV_SETTINGS[e.id] || "http://192.168.1.50:8082/v1"}
                      className="min-w-0 flex-1 rounded-xl border border-zinc-200 bg-white px-3 py-2 font-mono text-xs text-foreground outline-none placeholder:text-zinc-300 focus:border-zinc-400"
                    />
                    <button
                      onClick={() => test(e.id)}
                      disabled={!form[e.id] || status === "checking"}
                      className="shrink-0 rounded-xl border border-zinc-200 px-3 py-2 text-xs font-medium text-foreground hover:bg-zinc-50 disabled:opacity-40"
                    >
                      Test
                    </button>
                  </div>

                  {status && status !== "unknown" && (
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
                  )}
                </div>
              );
            })}
          </div>

          <h2 className="mt-8 text-xs font-semibold uppercase tracking-wide text-zinc-400">
            Model
          </h2>
          <div className="mt-2">
            <div className="flex items-baseline justify-between gap-2">
              <label
                htmlFor="engine-model"
                className="text-sm font-medium text-foreground"
              >
                Model id
              </label>
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
            <p className="text-xs text-zinc-500">
              Sent with every request; must match the engine&apos;s /v1/models.
            </p>
            <input
              id="engine-model"
              type="text"
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              value={form.model}
              onChange={(ev) => setField("model", ev.target.value)}
              placeholder="qwen3-4b"
              className="mt-1.5 w-full rounded-xl border border-zinc-200 bg-white px-3 py-2 font-mono text-xs text-foreground outline-none placeholder:text-zinc-300 focus:border-zinc-400"
            />
          </div>

          <button
            onClick={handleResetAll}
            className="mt-8 text-xs text-zinc-500 underline underline-offset-2 hover:text-foreground"
          >
            Reset all to build defaults
          </button>
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
