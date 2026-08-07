"use client";

import { useEffect, useState } from "react";
import { Menu, PenSquare, Settings } from "lucide-react";
import { ChatRuntimeProvider } from "./ChatRuntimeProvider";
import { HistorySidebar } from "./HistorySidebar";
import { ModePicker } from "./ModePicker";
import { ModelPicker } from "./ModelPicker";
import { PrivacyBanner } from "./PrivacyBanner";
import { SettingsSheet } from "./SettingsSheet";
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
  const [settingsOpen, setSettingsOpen] = useState(false);

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
      {/* Three columns rather than justify-between: the outer 1fr tracks keep
          the picker centered now that the right side carries two buttons. */}
      <header className="grid grid-cols-[1fr_auto_1fr] items-center border-b border-zinc-200 px-2 pb-2 pt-[max(0.5rem,env(safe-area-inset-top))]">
        <button
          onClick={() => setSidebarOpen(true)}
          aria-label="Open history"
          className="grid size-9 place-items-center justify-self-start rounded-full text-zinc-600 hover:bg-zinc-100"
        >
          <Menu className="size-5" />
        </button>

        {/* Mode and model side by side: together they decide what answers the
            next message, and a model the active mode can't hold is what greys
            that mode out — so the cause sits next to the effect. */}
        <div className="flex min-w-0 items-center gap-0.5">
          <ModePicker threadId={threadId} />
          <ModelPicker />
        </div>

        <div className="flex items-center justify-self-end">
          <button
            onClick={() => setSettingsOpen(true)}
            aria-label="Settings"
            className="grid size-9 place-items-center rounded-full text-zinc-600 hover:bg-zinc-100"
          >
            <Settings className="size-5" />
          </button>
          <button
            onClick={handleNewChat}
            aria-label="New chat"
            className="grid size-9 place-items-center rounded-full text-zinc-600 hover:bg-zinc-100"
          >
            <PenSquare className="size-5" />
          </button>
        </div>
      </header>

      <main className="flex min-h-0 flex-1 flex-col">
        {threadId ? (
          // keys remount the runtime (and reset banner state) per thread so
          // history and pin status reload correctly.
          <>
            <PrivacyBanner key={`banner-${threadId}`} threadId={threadId} />
            <div className="min-h-0 flex-1">
              <ChatRuntimeProvider key={threadId} threadId={threadId}>
                <Thread />
              </ChatRuntimeProvider>
            </div>
          </>
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

      <SettingsSheet
        open={settingsOpen}
        onClose={() => setSettingsOpen(false)}
      />
    </div>
  );
}
