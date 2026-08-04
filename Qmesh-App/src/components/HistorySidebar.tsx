"use client";

import { useLiveQuery } from "dexie-react-hooks";
import { Plus, Trash2, X, MessageSquare } from "lucide-react";
import { db } from "@/lib/db";
import { deleteThread } from "@/lib/threads";
import { cn } from "@/lib/cn";

/**
 * Slide-in history drawer. The thread list is a live Dexie query, so it
 * re-renders the moment a message is saved or a thread is created/deleted.
 */
export function HistorySidebar({
  open,
  activeThreadId,
  onClose,
  onSelect,
  onNewChat,
}: {
  open: boolean;
  activeThreadId: string | null;
  onClose: () => void;
  onSelect: (id: string) => void;
  onNewChat: () => void;
}) {
  const threads = useLiveQuery(
    () => db.threads.orderBy("updatedAt").reverse().toArray(),
    [],
    [],
  );

  return (
    <>
      {/* Scrim */}
      <div
        onClick={onClose}
        className={cn(
          "fixed inset-0 z-20 bg-black/40 transition-opacity",
          open ? "opacity-100" : "pointer-events-none opacity-0",
        )}
        aria-hidden={!open}
      />

      <aside
        className={cn(
          "fixed inset-y-0 left-0 z-30 flex w-[85%] max-w-xs flex-col bg-background shadow-xl transition-transform",
          open ? "translate-x-0" : "-translate-x-full",
        )}
      >
        <div className="flex items-center justify-between px-4 pb-2 pt-[max(0.75rem,env(safe-area-inset-top))]">
          <span className="text-sm font-semibold text-foreground">History</span>
          <button
            onClick={onClose}
            aria-label="Close history"
            className="grid size-8 place-items-center rounded-full text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800"
          >
            <X className="size-5" />
          </button>
        </div>

        <div className="px-3 pb-2">
          <button
            onClick={onNewChat}
            className="flex w-full items-center gap-2 rounded-xl border border-zinc-200 px-3 py-2.5 text-sm font-medium text-foreground hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-900"
          >
            <Plus className="size-4" />
            New chat
          </button>
        </div>

        <nav className="flex-1 overflow-y-auto px-2 pb-4">
          {threads.length === 0 && (
            <p className="px-3 py-6 text-center text-sm text-zinc-400">
              No conversations yet.
            </p>
          )}
          {threads.map((t) => (
            <div
              key={t.id}
              className={cn(
                "group flex items-center gap-2 rounded-lg px-2 py-2",
                t.id === activeThreadId
                  ? "bg-zinc-100 dark:bg-zinc-800"
                  : "hover:bg-zinc-50 dark:hover:bg-zinc-900",
              )}
            >
              <button
                onClick={() => onSelect(t.id)}
                className="flex min-w-0 flex-1 items-center gap-2 text-left"
              >
                <MessageSquare className="size-4 shrink-0 text-zinc-400" />
                <span className="truncate text-sm text-foreground">
                  {t.title}
                </span>
              </button>
              <button
                onClick={async () => {
                  await deleteThread(t.id);
                  if (t.id === activeThreadId) onNewChat();
                }}
                aria-label="Delete conversation"
                className="grid size-7 shrink-0 place-items-center rounded-md text-zinc-400 opacity-0 hover:text-red-500 group-hover:opacity-100"
              >
                <Trash2 className="size-4" />
              </button>
            </div>
          ))}
        </nav>
      </aside>
    </>
  );
}
