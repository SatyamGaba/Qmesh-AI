"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Check, ChevronDown } from "lucide-react";
import {
  ENV_SETTINGS,
  MODEL_OPTIONS,
  getPresets,
  getSettings,
  saveSettings,
  subscribeConfig,
} from "@/lib/config";
import { cn } from "@/lib/cn";

/**
 * The model id in force right now. Same subscription as the mode picker, so
 * changing the model in Settings updates this chip without a remount.
 */
function useModelId(): string {
  return useSyncExternalStore(
    subscribeConfig,
    () => getSettings().model,
    () => ENV_SETTINGS.model,
  );
}

/**
 * Header control for the model, sitting next to the mode picker so the two
 * halves of "what will answer my next message" are in one place — switching
 * models no longer means opening Settings.
 *
 * The model is a single global setting shared by every mode (see EngineSettings
 * in config.ts), which is exactly why it belongs beside the mode: picking one
 * the active engine cannot hold is what greys that mode out, and having both
 * controls adjacent makes that cause and effect visible.
 */
export function ModelPicker() {
  const [open, setOpen] = useState(false);
  const modelId = useModelId();
  const ref = useRef<HTMLDivElement>(null);

  // Close on outside click — mirrors ModePicker.
  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node))
        setOpen(false);
    };
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, [open]);

  const active = MODEL_OPTIONS.find((m) => m.id === modelId);

  function choose(id: string) {
    // saveSettings takes the whole shape and drops any field equal to its env
    // default, so round-tripping the other fields through it is a no-op.
    saveSettings({ ...getSettings(), model: id });
    setOpen(false);
  }

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        title={active ? `${active.label} — ${active.hint}` : modelId}
        className="flex items-center gap-1 rounded-full px-2 py-1 text-xs font-medium text-zinc-600 hover:bg-zinc-100"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="Model"
      >
        {/* An id matching no option is a hand-edited value; show it verbatim
            rather than pretending it is one of ours. */}
        {active?.short ?? modelId}
        <ChevronDown className="size-3 text-zinc-400" />
      </button>

      {open && (
        <div
          role="menu"
          className="absolute right-0 top-full z-30 mt-1 w-64 rounded-2xl border border-zinc-200 bg-white p-1.5 shadow-lg"
        >
          {MODEL_OPTIONS.map((m) => {
            // Which modes can serve this model, named rather than listed by id
            // — the same fact that greys a mode out once it is selected.
            const serves = getPresets()
              .filter((p) => (m.servedBy as readonly string[]).includes(p.id))
              .map((p) => p.label)
              .join(", ");
            return (
              <button
                key={m.id}
                role="menuitemradio"
                aria-checked={m.id === modelId}
                onClick={() => choose(m.id)}
                className="flex w-full items-start gap-2.5 rounded-xl px-2.5 py-2 text-left hover:bg-zinc-100"
              >
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-medium text-foreground">
                    {m.label}
                  </span>
                  <span className="block text-xs text-zinc-500">{m.hint}</span>
                  <span className="mt-0.5 block text-[10px] uppercase tracking-wide text-zinc-400">
                    Runs on: {serves}
                  </span>
                </span>
                {m.id === modelId && (
                  <Check
                    className={cn("mt-0.5 size-4 shrink-0 text-foreground")}
                  />
                )}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}
