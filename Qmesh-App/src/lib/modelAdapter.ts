import type { ChatModelAdapter, ChatModelRunOptions } from "@assistant-ui/react";
import {
  getActivePreset,
  getAutoPrivacy,
  getPresets,
  getPrivateEngine,
  type EnginePreset,
} from "./config";
import { db } from "./db";
import { pinThreadEngine } from "./threads";
import { detectPii, describePii, piiLabels } from "./pii";
import { openaiRun } from "./openaiModel";

/** Newest user turn's text — the only content not yet sent to any engine. */
function lastUserText(messages: ChatModelRunOptions["messages"]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m.role !== "user") continue;
    return m.content
      .filter((p): p is { type: "text"; text: string } => p.type === "text")
      .map((p) => p.text)
      .join(" ")
      .trim();
  }
  return "";
}

/**
 * Decide which engine this run actually uses:
 *
 *  1. A thread pinned by auto-privacy always uses its pinned engine — the full
 *     history (sensitive turns included) replays on every request, so the pin
 *     outlives the message that caused it.
 *  2. Otherwise, with auto-privacy on and Remote active, a PII hit in the new
 *     user message pins the thread to the private engine — decided and
 *     persisted here, *before* any bytes leave the device.
 *  3. Otherwise the picker's choice applies as-is.
 *
 * When privacy is required but no private engine is configured, this throws
 * instead of falling back to Remote: a failed send is recoverable, a leak is
 * not. The error surfaces in the chat like any engine failure.
 */
async function resolvePreset(
  threadId: string,
  options: ChatModelRunOptions,
): Promise<EnginePreset> {
  const thread = await db.threads.get(threadId);

  if (thread?.pinnedEngine) {
    const pinned = getPresets().find((p) => p.id === thread.pinnedEngine);
    if (pinned?.available) return pinned;
    const fallback = getPrivateEngine();
    if (fallback) return fallback;
    throw new Error(
      "This chat is pinned to a private engine, but neither Split nor On-device is configured. Set one up in Settings, or unpin the chat from the privacy banner.",
    );
  }

  const active = getActivePreset();
  if (!getAutoPrivacy() || active.id !== "remote") return active;

  const matches = detectPii(lastUserText(options.messages));
  if (matches.length === 0) return active;

  const target = getPrivateEngine();
  if (!target) {
    throw new Error(
      `Message held back: it contains ${describePii(matches)} and auto-privacy is on, but no private engine (Split or On-device) is configured. Nothing was sent to Remote.`,
    );
  }
  await pinThreadEngine(threadId, target.id, piiLabels(matches));
  return target;
}

/**
 * The adapter the runtime is bound to, one per thread (the provider remounts
 * per thread, so the id can be captured here instead of relying on the
 * unstable_threadId run option). Engine choice happens at *run* time, so a
 * picker switch — or an auto-privacy pin — applies to the very next message
 * with no remount and no lost conversation.
 */
export function createModelAdapter(threadId: string): ChatModelAdapter {
  return {
    async *run(options) {
      const preset = await resolvePreset(threadId, options);
      yield* openaiRun(options, preset);
    },
  };
}
