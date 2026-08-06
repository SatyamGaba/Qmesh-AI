"use client";

import { useMemo } from "react";
import {
  AssistantRuntimeProvider,
  useLocalRuntime,
} from "@assistant-ui/react";
import { createModelAdapter } from "@/lib/modelAdapter";
import { createHistoryAdapter } from "@/lib/threads";

/**
 * Provides a LocalRuntime bound to one thread. Chat streams client-side from
 * the configured OpenAI-compatible engine and persists to Dexie through the
 * history adapter — no app server; the shell and history work offline.
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

  // The adapter is bound to this thread (auto-privacy pins are per-thread) but
  // still resolves the engine per-run (see modelAdapter), so switching modes in
  // the picker applies to the next message with no remount — the conversation
  // is preserved.
  const adapter = useMemo(() => createModelAdapter(threadId), [threadId]);
  const runtime = useLocalRuntime(adapter, {
    adapters: { history },
  });

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      {children}
    </AssistantRuntimeProvider>
  );
}
