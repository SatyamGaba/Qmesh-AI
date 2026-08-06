# Qmesh

A mobile-only, offline-first chat PWA — a ChatGPT-style UI where inference and
storage run **on the device**. Built as a hackathon prototype: the chat UI,
history, and offline persistence are complete, and chat streams from any
OpenAI-compatible engine — on-device, split across phone + laptop, or remote.

## Stack

- **Next.js 16** (App Router) + **React 19** + **TypeScript**
- **[assistant-ui](https://www.assistant-ui.com/)** — ChatGPT-style chat UI
  running fully client-side via `LocalRuntime` (no server chat endpoint, so it
  works offline)
- **[Dexie.js](https://dexie.org/)** — on-device IndexedDB for threads +
  messages; the history list is a reactive `liveQuery`
- **[serwist](https://serwist.pages.dev/)** — service worker / PWA so the app
  shell installs and loads with no network
- **Tailwind CSS v4** + **lucide-react** icons

## Run

```bash
npm run dev      # http://localhost:3000 (SW disabled in dev)
npm run build    # generates public/sw.js
npm run start    # production server — required to test PWA/offline
```

> Build/dev use `--webpack`. Next 16 defaults to Turbopack, which `@serwist/next`
> does not support yet.

To see the offline story: `npm run build && npm run start`, load the app once
(registers the SW), then stop the server and reload — the app, its history, and
chat all keep working.

## Where the model plugs in

`src/lib/openaiModel.ts` is the **only** place the app talks to a model: a
single `ChatModelAdapter` that streams from any OpenAI-compatible
`/v1/chat/completions` endpoint over SSE. Which engine it hits — on-device,
split, or remote — is resolved per message from `src/lib/config.ts`, so the
header picker repoints it at runtime with no rebuild.

## Layout

| Path | Role |
| --- | --- |
| `src/lib/db.ts` | Dexie database (threads + messages tables) |
| `src/lib/threads.ts` | Thread CRUD + the per-thread `ThreadHistoryAdapter` that persists to Dexie |
| `src/lib/openaiModel.ts` | **Inference seam** — OpenAI-compatible SSE `ChatModelAdapter` |
| `src/lib/config.ts` | Engine modes/presets + Settings overrides |
| `src/components/ChatRuntimeProvider.tsx` | Wires `useLocalRuntime` (model + history) per thread |
| `src/components/Thread.tsx` | Message list, bubbles, markdown, composer |
| `src/components/HistorySidebar.tsx` | Slide-in history drawer (live Dexie query) |
| `src/components/ChatApp.tsx` | Mobile shell: header, active thread, sidebar |
| `src/app/sw.ts` | Service worker source (serwist) |
