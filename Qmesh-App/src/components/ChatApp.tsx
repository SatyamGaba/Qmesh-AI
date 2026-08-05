"use client";

import { useEffect, useState } from "react";
import { Menu, PenSquare } from "lucide-react";
import { ChatRuntimeProvider } from "./ChatRuntimeProvider";
import { HistorySidebar } from "./HistorySidebar";
import { ModePicker } from "./ModePicker";
import { Thread } from "./Thread";
import { createThread } from "@/lib/threads";
import { db } from "@/lib/db";

/**
 * Top-level mobile chat shell: header, slide-in history, and the active thread.
 * Owns the current thread id; the runtime is keyed on it so switching threads
 * loads the right saved conversation.
 */
export function ChatApp() {
  const [threadId, setThreadId] = useState<string | null>(null);
  const [sidebarOpen, setSidebarOpen] = useState(false);

  // On first load, resume the most recent thread or create a fresh one.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const recent = await db.threads
        .orderBy("updatedAt")
        .reverse()
        .limit(1)
        .toArray();
      if (cancelled) return;
      if (recent[0]) {
        setThreadId(recent[0].id);
      } else {
        const t = await createThread(Date.now());
        if (!cancelled) setThreadId(t.id);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  async function handleNewChat() {
    const t = await createThread(Date.now());
    setThreadId(t.id);
    setSidebarOpen(false);
  }

  function handleSelect(id: string) {
    setThreadId(id);
    setSidebarOpen(false);
  }

  return (
    <div className="flex h-[100dvh] flex-col overflow-hidden bg-background">
      <header className="flex items-center justify-between border-b border-zinc-200 px-2 pb-2 pt-[max(0.5rem,env(safe-area-inset-top))] dark:border-zinc-800">
        <button
          onClick={() => setSidebarOpen(true)}
          aria-label="Open history"
          className="grid size-9 place-items-center rounded-full text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          <Menu className="size-5" />
        </button>
        <ModePicker />
        <button
          onClick={handleNewChat}
          aria-label="New chat"
          className="grid size-9 place-items-center rounded-full text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          <PenSquare className="size-5" />
        </button>
      </header>

      <main className="min-h-0 flex-1">
        {threadId ? (
          // key remounts the runtime per thread so history reloads correctly.
          <ChatRuntimeProvider key={threadId} threadId={threadId}>
            <Thread />
          </ChatRuntimeProvider>
        ) : (
          <div className="grid h-full place-items-center text-sm text-zinc-400">
            Loading…
          </div>
        )}
      </main>

      <HistorySidebar
        open={sidebarOpen}
        activeThreadId={threadId}
        onClose={() => setSidebarOpen(false)}
        onSelect={handleSelect}
        onNewChat={handleNewChat}
      />
    </div>
  );
}
