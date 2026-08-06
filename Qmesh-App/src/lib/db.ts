import Dexie, { type Table } from "dexie";
import type {
  ThreadMessage,
  ExportedMessageRepositoryItem,
} from "@assistant-ui/react";

// RunConfig isn't re-exported by name from the react package; derive it.
type RunConfig = ExportedMessageRepositoryItem["runConfig"];

/**
 * A conversation shown in the history list. Metadata only — the messages
 * themselves live in the `messages` table, keyed by threadId.
 */
export interface Thread {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  /**
   * When set, every run in this thread uses this engine preset id instead of
   * the global picker choice. Written by auto-privacy on a PII hit: the full
   * history replays to the engine on every turn, so once sensitive text enters
   * a thread it must not travel to a less-private engine unless the user
   * explicitly unpins (PrivacyBanner's confirmed Undo).
   *
   * Optional non-indexed fields, so no Dexie schema version bump is needed.
   */
  pinnedEngine?: string;
  /** Why it was pinned — detected PII labels ("an email address"), for the UI. */
  pinnedFor?: string[];
}

/**
 * One persisted message. Mirrors assistant-ui's ExportedMessageRepositoryItem
 * ({ message, parentId, runConfig }) plus the threadId it belongs to and a
 * monotonic `seq` so we can restore order on load.
 */
export interface StoredMessage {
  seq?: number;
  threadId: string;
  id: string;
  parentId: string | null;
  message: ThreadMessage;
  runConfig?: RunConfig;
}

/**
 * The entire app database lives on-device in IndexedDB. Nothing is ever sent
 * off the phone — this is what makes the app work fully offline.
 */
class QmeshDB extends Dexie {
  threads!: Table<Thread, string>;
  messages!: Table<StoredMessage, number>;

  constructor() {
    super("qmesh");
    this.version(1).stores({
      // `id` is the primary key; `updatedAt` indexed for the history list order.
      threads: "id, updatedAt",
      // auto-increment `seq` primary key; indexes for per-thread lookup + upsert.
      messages: "++seq, threadId, id, [threadId+id]",
    });
  }
}

export const db = new QmeshDB();
