"use client";

import {
  ThreadPrimitive,
  MessagePrimitive,
  ComposerPrimitive,
} from "@assistant-ui/react";
import { MarkdownTextPrimitive } from "@assistant-ui/react-markdown";
import type { TextMessagePartComponent } from "@assistant-ui/react";
import { ArrowUp, Square } from "lucide-react";
import { cn } from "@/lib/cn";

// MarkdownTextPrimitive reads the text part from context, so it ignores the
// text-part props MessagePrimitive.Parts passes to a Text component.
const MarkdownText: TextMessagePartComponent = () => <MarkdownTextPrimitive />;

const SUGGESTIONS = [
  "Explain how on-device inference works",
  "Write a haiku about offline apps",
  "What can you do without a network?",
];

/** ChatGPT-style message list + composer for the active thread. */
export function Thread() {
  return (
    <ThreadPrimitive.Root className="flex h-full flex-col bg-background">
      <ThreadPrimitive.Viewport
        autoScroll
        className="flex-1 overflow-y-auto overscroll-contain px-4 pt-4"
      >
        <ThreadPrimitive.Empty>
          <EmptyState />
        </ThreadPrimitive.Empty>

        <div className="mx-auto flex w-full max-w-2xl flex-col gap-4 pb-4">
          <ThreadPrimitive.Messages
            components={{
              UserMessage,
              AssistantMessage,
            }}
          />
        </div>
      </ThreadPrimitive.Viewport>

      <Composer />
    </ThreadPrimitive.Root>
  );
}

function EmptyState() {
  return (
    <div className="mx-auto flex h-full max-w-2xl flex-col items-center justify-center gap-6 text-center">
      <div>
        <h2 className="text-xl font-semibold text-foreground">
          On-device chat
        </h2>
        <p className="mt-1 text-sm text-zinc-500">
          Runs and stores everything locally. Works offline.
        </p>
      </div>
      <div className="flex w-full flex-col gap-2">
        {SUGGESTIONS.map((s) => (
          <ThreadPrimitive.Suggestion
            key={s}
            prompt={s}
            send={false}
            className="rounded-2xl border border-zinc-200 px-4 py-3 text-left text-sm text-zinc-700 transition-colors hover:bg-zinc-50"
          >
            {s}
          </ThreadPrimitive.Suggestion>
        ))}
      </div>
    </div>
  );
}

function UserMessage() {
  return (
    <MessagePrimitive.Root className="flex justify-end">
      <div className="max-w-[85%] rounded-3xl rounded-br-md bg-foreground px-4 py-2.5 text-background">
        <MessagePrimitive.Parts components={{ Text: MarkdownText }} />
      </div>
    </MessagePrimitive.Root>
  );
}

function AssistantMessage() {
  return (
    <MessagePrimitive.Root className="flex justify-start">
      <div
        className={cn(
          "max-w-[85%] rounded-3xl rounded-bl-md bg-zinc-100 px-4 py-2.5 text-foreground",
          // prose-ish spacing for markdown output
          "[&_p]:my-1 [&_pre]:my-2 [&_pre]:overflow-x-auto [&_pre]:rounded-lg [&_pre]:bg-black/80 [&_pre]:p-3 [&_pre]:text-xs [&_pre]:text-zinc-100 [&_code]:font-mono [&_ul]:my-1 [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:my-1 [&_ol]:list-decimal [&_ol]:pl-5",
        )}
      >
        <MessagePrimitive.Parts components={{ Text: MarkdownText }} />
      </div>
    </MessagePrimitive.Root>
  );
}

function Composer() {
  return (
    <div className="border-t border-zinc-200 bg-background px-4 py-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]">
      <ComposerPrimitive.Root className="mx-auto flex w-full max-w-2xl items-end gap-2 rounded-3xl border border-zinc-300 bg-white px-3 py-2 focus-within:border-zinc-400">
        <ComposerPrimitive.Input
          autoFocus
          rows={1}
          placeholder="Message"
          className="max-h-32 flex-1 resize-none bg-transparent py-1.5 text-[16px] leading-6 text-foreground outline-none placeholder:text-zinc-400"
        />
        <ThreadPrimitive.If running={false}>
          <ComposerPrimitive.Send
            className="grid size-9 shrink-0 place-items-center rounded-full bg-foreground text-background transition-opacity disabled:opacity-30"
            aria-label="Send"
          >
            <ArrowUp className="size-5" />
          </ComposerPrimitive.Send>
        </ThreadPrimitive.If>
        <ThreadPrimitive.If running>
          <ComposerPrimitive.Cancel
            className="grid size-9 shrink-0 place-items-center rounded-full bg-foreground text-background"
            aria-label="Stop"
          >
            <Square className="size-4 fill-current" />
          </ComposerPrimitive.Cancel>
        </ThreadPrimitive.If>
      </ComposerPrimitive.Root>
    </div>
  );
}
