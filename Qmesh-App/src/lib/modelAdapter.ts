import type { ChatModelAdapter } from "@assistant-ui/react";
import { getEngine } from "./config";
import { mockModelAdapter } from "./mockModel";
import { openaiModelAdapter } from "./openaiModel";

/**
 * The single adapter the runtime is bound to. It reads the active engine at
 * *run* time (not mount time) and delegates to the right backend, so switching
 * modes in the picker takes effect on the very next message — no remount, no
 * lost conversation.
 */
export const modelAdapter: ChatModelAdapter = {
  run(options) {
    const engine = getEngine();
    const target =
      engine.mode === "openai" ? openaiModelAdapter : mockModelAdapter;
    return target.run(options);
  },
};
