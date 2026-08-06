"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Check, ChevronDown } from "lucide-react";
import {
  ENV_PRESETS,
  getActivePresetId,
  getPresets,
  probeEngine,
  setActivePreset,
  subscribeConfig,
  type EnginePreset,
  type Reach,
} from "@/lib/config";
import { cn } from "@/lib/cn";

/**
 * Subscribe to the persisted active-mode id via useSyncExternalStore, so the
 * picker reflects changes from the console helper or another tab, and reads
 * cleanly on the client after SSR (server snapshot = first preset).
 */
function useActivePresetId(): string {
  return useSyncExternalStore(
    subscribeConfig,
    () => getActivePresetId(),
    () => ENV_PRESETS[0].id,
  );
}

/**
 * The presets with any Settings overrides applied. Same subscription, so saving
 * a new endpoint URL flips that mode from greyed to selectable immediately.
 * getPresets() caches its array, which keeps the snapshot reference stable.
 */
function usePresets(): EnginePreset[] {
  return useSyncExternalStore(subscribeConfig, getPresets, () => ENV_PRESETS);
}

/** Probe an engine's /v1/models with a short timeout. mock is always "up". */
async function probe(p: EnginePreset): Promise<Reach> {
  if (p.mode === "mock") return "up";
  if (!p.available) return "down";
  return probeEngine(p.baseUrl, p.apiKey);
}

const DOT: Record<Reach, string> = {
  up: "bg-green-500",
  down: "bg-red-500",
  checking: "bg-amber-400 animate-pulse",
  unknown: "bg-zinc-300",
};

/**
 * Header control that shows the active engine mode and lets you switch between
 * mock / on-device / split / remote. Each mode carries a live reachability dot
 * so you can see whether its engine is up before selecting it. Switching takes
 * effect on the next message (the adapter dispatches per-run).
 */
export function ModePicker() {
  const [open, setOpen] = useState(false);
  const activeId = useActivePresetId();
  const presets = usePresets();
  const [reach, setReach] = useState<Record<string, Reach>>({});
  const ref = useRef<HTMLDivElement>(null);

  // Probe reachability whenever the menu opens — or whenever an endpoint is
  // edited in Settings, since the old verdict no longer describes the new URL.
  // The "checking" marker is set inside the async task (not synchronously in
  // the effect body) so opening the menu doesn't trigger a cascading render.
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      setReach((r) => {
        const next = { ...r };
        for (const p of presets) if (p.mode !== "mock") next[p.id] = "checking";
        return next;
      });
      await Promise.all(
        presets.map(async (p) => {
          const status = await probe(p);
          if (!cancelled) setReach((r) => ({ ...r, [p.id]: status }));
        }),
      );
    })();
    return () => {
      cancelled = true;
    };
  }, [open, presets]);

  // Close on outside click.
  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, [open]);

  const active = presets.find((p) => p.id === activeId) ?? presets[0];

  function choose(p: EnginePreset) {
    if (!p.available && p.mode !== "mock") return;
    setActivePreset(p.id); // fires ENGINE_CHANGE_EVENT → useActivePresetId updates
    setOpen(false);
  }

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-1.5 rounded-full px-2.5 py-1 text-sm font-semibold text-foreground hover:bg-zinc-100"
        aria-haspopup="menu"
        aria-expanded={open}
      >
        <span
          className={cn("size-1.5 rounded-full", DOT[reach[active.id] ?? "unknown"])}
        />
        Qmesh
        <span className="text-xs font-normal text-zinc-500">· {active.label}</span>
        <ChevronDown className="size-3.5 text-zinc-400" />
      </button>

      {open && (
        <div
          role="menu"
          className="absolute left-1/2 top-full z-30 mt-1 w-64 -translate-x-1/2 rounded-2xl border border-zinc-200 bg-white p-1.5 shadow-lg"
        >
          {presets.map((p) => {
            const disabled = !p.available && p.mode !== "mock";
            return (
              <button
                key={p.id}
                role="menuitemradio"
                aria-checked={p.id === activeId}
                disabled={disabled}
                onClick={() => choose(p)}
                className={cn(
                  "flex w-full items-start gap-2.5 rounded-xl px-2.5 py-2 text-left",
                  disabled
                    ? "cursor-not-allowed opacity-40"
                    : "hover:bg-zinc-100",
                )}
              >
                <span
                  className={cn(
                    "mt-1.5 size-1.5 shrink-0 rounded-full",
                    DOT[reach[p.id] ?? (p.mode === "mock" ? "up" : "unknown")],
                  )}
                />
                <span className="min-w-0 flex-1">
                  <span className="flex items-center gap-1.5">
                    <span className="text-sm font-medium text-foreground">
                      {p.label}
                    </span>
                    {disabled && (
                      <span className="text-[10px] uppercase tracking-wide text-zinc-400">
                        not set up
                      </span>
                    )}
                  </span>
                  <span className="block text-xs text-zinc-500">{p.hint}</span>
                </span>
                {p.id === activeId && (
                  <Check className="mt-0.5 size-4 shrink-0 text-foreground" />
                )}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}
