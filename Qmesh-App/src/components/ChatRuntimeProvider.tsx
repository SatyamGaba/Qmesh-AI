"use client";

import { useMemo } from "react";
import {
  AssistantRuntimeProvider,
  useLocalRuntime,
} from "@assistant-ui/react";
import { mockModelAdapter } from "@/lib/mockModel";
import { openaiModelAdapter } from "@/lib/openaiModel";
import { getEngine } from "@/lib/config";
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

  // Pick the adapter from config: real OpenAI-compatible engine when one is
  // configured, else the on-device mock (the always-available offline floor).
  const adapter = useMemo(
    () => (getEngine().mode === "openai" ? openaiModelAdapter : mockModelAdapter),
    [],
  );

  const runtime = useLocalRuntime(adapter, {
    adapters: { history },
  });

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      {children}
    </AssistantRuntimeProvider>
  );
}
