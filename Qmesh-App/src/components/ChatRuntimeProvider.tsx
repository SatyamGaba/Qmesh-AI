"use client";

import { useMemo } from "react";
import {
  AssistantRuntimeProvider,
  useLocalRuntime,
} from "@assistant-ui/react";
import { modelAdapter } from "@/lib/modelAdapter";
import { createHistoryAdapter } from "@/lib/threads";

/**
 * Provides a LocalRuntime bound to one thread. Chat runs 100% client-side
 * (mock model now, on-device NPU later) and persists to Dexie through the
 * history adapter — no server, works offline.
 *
 * The parent remounts this with `key={threadId}` so switching threads gets a
 * fresh runtime that loads that thread's saved messages.
 */
export function ChatRuntimeProvider({
  threadId,
  children,
}: {
  threadId: string;
  children: React.ReactNode;
}) {
  const history = useMemo(() => createHistoryAdapter(threadId), [threadId]);

  // The adapter dispatches to the active engine per-run (see modelAdapter),
  // so switching modes in the picker applies to the next message with no
  // remount — the conversation is preserved.
  const runtime = useLocalRuntime(modelAdapter, {
    adapters: { history },
  });

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      {children}
    </AssistantRuntimeProvider>
  );
}
