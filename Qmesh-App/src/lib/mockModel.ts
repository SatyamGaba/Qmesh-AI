import type { ChatModelAdapter } from "@assistant-ui/react";

/**
 * ============================================================================
 *  ON-DEVICE INFERENCE SEAM
 * ============================================================================
 * This is the ONLY place the app talks to a "model". Today it streams a canned,
 * on-device mock so the whole UI + offline persistence works end-to-end with no
 * network and no LLM.
 *
 * To wire real local/split NPU inference later, replace the body of `run()`:
 * feed `options.messages` to your on-device runtime (WebNN / ONNX Runtime Web /
 * a native bridge) and yield partial text the same way. The rest of the app
 * never changes.
 * ============================================================================
 */

const CANNED = [
  "This is a fully on-device response — no network was used. ",
  "Your messages and history are stored locally on this phone via IndexedDB, ",
  "so the app keeps working with the network turned off. ",
  "When the NPU inference backend is wired in, it will stream here in exactly ",
  "the same way this mock does.",
];

function lastUserText(
  messages: ChatModelRunOptionsMessages,
): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m.role !== "user") continue;
    const text = m.content
      .filter((p): p is { type: "text"; text: string } => p.type === "text")
      .map((p) => p.text)
      .join(" ")
      .trim();
    if (text) return text;
  }
  return "";
}

type ChatModelRunOptionsMessages = Parameters<
  ChatModelAdapter["run"]
>[0]["messages"];

export const mockModelAdapter: ChatModelAdapter = {
  async *run({ messages, abortSignal }) {
    const asked = lastUserText(messages);
    const chunks = asked
      ? [`You said: "${asked}".\n\n`, ...CANNED]
      : [...CANNED];

    let text = "";
    for (const chunk of chunks) {
      // Stream word-by-word so it visibly types out, like a real model.
      for (const word of chunk.match(/\S+\s*/g) ?? [chunk]) {
        if (abortSignal.aborted) return;
        text += word;
        yield { content: [{ type: "text", text }] };
        await sleep(35);
      }
    }
  },
};

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    const t = setTimeout(resolve, ms);
    // Don't hang the run if the tab is torn down mid-stream.
    if (typeof t === "object" && "unref" in t) (t as { unref: () => void }).unref?.();
  });
}
