"use client";

import { useState } from "react";
import { useLiveQuery } from "dexie-react-hooks";
import { ShieldCheck, TriangleAlert } from "lucide-react";
import { db } from "@/lib/db";
import { unpinThreadEngine } from "@/lib/threads";
import { getPresets } from "@/lib/config";

/**
 * Shown above the thread the moment auto-privacy pins it to a private engine
 * (the pin is written to Dexie before the request is sent, so useLiveQuery
 * makes this appear as the message goes out — it doubles as the "switched"
 * toast and the persistent pinned badge).
 *
 * Undo is deliberately two-step: the whole history — sensitive turns included —
 * replays to whatever engine is active on the next message, so going back to
 * Remote is a disclosure decision, not a cosmetic one. Mount with
 * `key={threadId}` so the confirm state resets when switching threads.
 */
export function PrivacyBanner({ threadId }: { threadId: string }) {
  const thread = useLiveQuery(() => db.threads.get(threadId), [threadId]);
  const [confirming, setConfirming] = useState(false);

  if (!thread?.pinnedEngine) return null;

  const engineLabel =
    getPresets().find((p) => p.id === thread.pinnedEngine)?.label ??
    thread.pinnedEngine;
  const kinds = thread.pinnedFor?.length
    ? formatList(thread.pinnedFor)
    : "sensitive info";

  if (confirming) {
    return (
      <div className="border-b border-amber-200 bg-amber-50 px-4 py-2.5">
        <div className="mx-auto flex w-full max-w-2xl items-start gap-2.5">
          <TriangleAlert className="mt-0.5 size-4 shrink-0 text-amber-600" />
          <div className="min-w-0 flex-1">
            <p className="text-xs text-amber-900">
              This chat contains {kinds}. If you switch back, your next message
              sends the whole conversation — those details included — to the
              Remote engine.
            </p>
            <div className="mt-1.5 flex gap-2">
              <button
                onClick={() => setConfirming(false)}
                className="rounded-lg bg-amber-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-amber-700"
              >
                Keep private
              </button>
              <button
                onClick={() => {
                  void unpinThreadEngine(threadId);
                  setConfirming(false);
                }}
                className="rounded-lg border border-amber-300 px-2.5 py-1 text-xs font-medium text-amber-800 hover:bg-amber-100"
              >
                Use Remote anyway
              </button>
            </div>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="border-b border-emerald-200 bg-emerald-50 px-4 py-2">
      <div className="mx-auto flex w-full max-w-2xl items-center gap-2.5">
        <ShieldCheck className="size-4 shrink-0 text-emerald-600" />
        <p className="min-w-0 flex-1 text-xs text-emerald-900">
          Private mode — {kinds} detected. This chat now runs on{" "}
          <span className="font-semibold">{engineLabel}</span> and stays there.
        </p>
        <button
          onClick={() => setConfirming(true)}
          className="shrink-0 text-xs font-medium text-emerald-700 underline underline-offset-2 hover:text-emerald-900"
        >
          Undo
        </button>
      </div>
    </div>
  );
}

/** "a, b and c" from stored PII labels. */
function formatList(items: string[]): string {
  if (items.length <= 1) return items[0] ?? "";
  return `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`;
}
