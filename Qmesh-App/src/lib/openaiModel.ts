import type {
  ChatModelRunOptions,
  ChatModelRunResult,
} from "@assistant-ui/react";
import type { EngineConfig } from "./config";

/**
 * ============================================================================
 *  REAL INFERENCE ADAPTER — OpenAI-compatible /v1/chat/completions (SSE)
 * ============================================================================
 * Streams from any OpenAI-compatible engine (llama-server today; the split /
 * all_remote / all_local modes later, all behind the same wire format — see
 * ARCHITECTURE_PLAN §3). The target engine is resolved per-run by
 * modelAdapter.ts (picker choice, or auto-privacy's override) and passed in,
 * so it can be repointed at runtime with no rebuild.
 *
 * assistant-ui's ChatModelAdapter.run yields CUMULATIVE snapshots: each yield
 * carries the full text so far, not a delta — so we accumulate and re-yield.
 */

type RunMessages = ChatModelRunOptions["messages"];

/** Flatten one assistant-ui message's parts into a single text string. */
function partsToText(content: RunMessages[number]["content"]): string {
  return content
    .filter((p): p is { type: "text"; text: string } => p.type === "text")
    .map((p) => p.text)
    .join("\n");
}

/** Convert assistant-ui thread messages to OpenAI chat messages. */
function toOpenAiMessages(
  messages: RunMessages,
): Array<{ role: "user" | "assistant" | "system"; content: string }> {
  const out: Array<{
    role: "user" | "assistant" | "system";
    content: string;
  }> = [];
  for (const m of messages) {
    if (m.role !== "user" && m.role !== "assistant" && m.role !== "system") {
      continue; // skip tool/other roles this prototype doesn't produce
    }
    const text = partsToText(m.content);
    // Keep empty assistant turns out of the payload; keep empty user turns rare.
    if (!text && m.role === "assistant") continue;
    out.push({ role: m.role, content: text });
  }
  return out;
}

/**
 * Parse a Server-Sent Events byte stream into successive `data:` payload
 * strings. Handles chunk boundaries splitting mid-event by buffering until a
 * blank-line event terminator is seen.
 */
async function* sseEvents(
  body: ReadableStream<Uint8Array>,
  abortSignal: AbortSignal,
): AsyncGenerator<string> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    while (true) {
      if (abortSignal.aborted) return;
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      // Events are separated by a blank line (\n\n). Emit complete ones.
      let sep: number;
      while ((sep = buffer.indexOf("\n\n")) !== -1) {
        const rawEvent = buffer.slice(0, sep);
        buffer = buffer.slice(sep + 2);
        // An event may have multiple `data:` lines; concatenate their values.
        const data = rawEvent
          .split("\n")
          .filter((l) => l.startsWith("data:"))
          .map((l) => l.slice(5).trimStart())
          .join("\n");
        if (data) yield data;
      }
    }
  } finally {
    // Ensure the network stream is released if the consumer stops early.
    reader.cancel().catch(() => {});
  }
}

export async function* openaiRun(
  { messages, abortSignal }: ChatModelRunOptions,
  cfg: EngineConfig,
): AsyncGenerator<ChatModelRunResult, void> {
  if (!cfg.baseUrl) {
    throw new Error(
      "No engine base URL configured. Set NEXT_PUBLIC_ENGINE_BASE_URL or call qmeshSetEngine(...).",
    );
  }

  const url = `${cfg.baseUrl.replace(/\/$/, "")}/chat/completions`;
  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(cfg.apiKey ? { Authorization: `Bearer ${cfg.apiKey}` } : {}),
      },
      body: JSON.stringify({
        model: cfg.model,
        stream: true,
        messages: toOpenAiMessages(messages),
      }),
      signal: abortSignal,
    });
  } catch (err) {
    // Network-level failure (engine down, DNS, CORS block, offline).
    throw new Error(
      `Can't reach the inference engine at ${cfg.baseUrl}. Is it running and on the same network? (${(err as Error).message})`,
    );
  }

  if (!res.ok || !res.body) {
    const detail = await res.text().catch(() => "");
    throw new Error(
      `Engine returned ${res.status} ${res.statusText}${detail ? `: ${detail.slice(0, 300)}` : ""}`,
    );
  }

  let text = "";
  for await (const data of sseEvents(res.body, abortSignal)) {
    if (data === "[DONE]") break;
    let parsed: unknown;
    try {
      parsed = JSON.parse(data);
    } catch {
      continue; // ignore keepalive pings / non-JSON lines
    }
    const delta = (
      parsed as {
        choices?: Array<{ delta?: { content?: string | null } }>;
      }
    ).choices?.[0]?.delta?.content;
    if (delta) {
      text += delta;
      yield { content: [{ type: "text", text }] };
    }
  }

  // Emit a final snapshot even if the stream produced nothing, so the UI
  // doesn't hang on an empty assistant turn.
  if (!text) {
    yield { content: [{ type: "text", text: "" }] };
  }
}
