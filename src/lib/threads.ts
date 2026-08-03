import { db, type Thread } from "./db";
import type {
  ThreadHistoryAdapter,
  ExportedMessageRepository,
  ExportedMessageRepositoryItem,
} from "@assistant-ui/react";

// Small id helper — crypto.randomUUID is available in modern browsers.
export function newId(): string {
  return crypto.randomUUID();
}

/** Create an empty thread and return it. */
export async function createThread(now: number): Promise<Thread> {
  const thread: Thread = {
    id: newId(),
    title: "New chat",
    createdAt: now,
    updatedAt: now,
  };
  await db.threads.add(thread);
  return thread;
}

/** Delete a thread and every message inside it. */
export async function deleteThread(threadId: string): Promise<void> {
  await db.transaction("rw", db.threads, db.messages, async () => {
    await db.messages.where("threadId").equals(threadId).delete();
    await db.threads.delete(threadId);
  });
}

/** Rename a thread (used to derive a title from the first user message). */
export async function renameThread(
  threadId: string,
  title: string,
): Promise<void> {
  await db.threads.update(threadId, { title });
}

function firstText(item: ExportedMessageRepositoryItem): string | null {
  const parts = item.message.content;
  for (const part of parts) {
    if (part.type === "text" && part.text.trim()) return part.text.trim();
  }
  return null;
}

/**
 * Build a ThreadHistoryAdapter bound to one thread. assistant-ui's LocalRuntime
 * calls `load()` once when the thread mounts and `append()` after every user
 * and assistant message — so this is the whole persistence story for a chat.
 */
export function createHistoryAdapter(threadId: string): ThreadHistoryAdapter {
  return {
    async load(): Promise<ExportedMessageRepository> {
      const rows = await db.messages
        .where("threadId")
        .equals(threadId)
        .sortBy("seq");
      return {
        messages: rows.map((r) => ({
          message: r.message,
          parentId: r.parentId,
          ...(r.runConfig !== undefined && { runConfig: r.runConfig }),
        })),
      };
    },

    async append(item: ExportedMessageRepositoryItem): Promise<void> {
      await db.transaction("rw", db.threads, db.messages, async () => {
        // Upsert on (threadId, message.id) so re-appends (e.g. tool results)
        // overwrite rather than duplicate.
        const existing = await db.messages
          .where("[threadId+id]")
          .equals([threadId, item.message.id])
          .first();
        const row = {
          threadId,
          id: item.message.id,
          parentId: item.parentId,
          message: item.message,
          ...(item.runConfig !== undefined && { runConfig: item.runConfig }),
        };
        if (existing?.seq !== undefined) {
          await db.messages.update(existing.seq, row);
        } else {
          await db.messages.add(row);
        }

        // Keep the history list fresh, and title the thread from its first
        // user message if it's still the default.
        const patch: Partial<Thread> = { updatedAt: Date.now() };
        if (item.message.role === "user") {
          const thread = await db.threads.get(threadId);
          if (thread && thread.title === "New chat") {
            const text = firstText(item);
            if (text) patch.title = text.slice(0, 60);
          }
        }
        await db.threads.update(threadId, patch);
      });
    },

    async update(item: ExportedMessageRepositoryItem): Promise<void> {
      // Same upsert path — update is only called for messages paused for tool
      // approval, which this prototype doesn't use, but the adapter honors it.
      await this.append(item);
    },
  };
}
