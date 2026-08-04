# Qmesh

A mobile-only, offline-first chat PWA — a ChatGPT-style UI where inference and
storage run **on the device**. Built as a hackathon prototype: the chat UI,
history, and offline persistence are complete; the model is a mock that streams
canned text, ready to be swapped for real local/split NPU inference.

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

`src/lib/mockModel.ts` is the **only** place the app talks to a model. It's a
single `ChatModelAdapter` that streams canned text today. To wire real
local/split NPU inference, replace the body of `run()`: feed `options.messages`
to your on-device runtime (WebNN / ONNX Runtime Web / a native bridge) and
`yield` partial text the same way. Nothing else in the app changes.

## Layout

| Path | Role |
| --- | --- |
| `src/lib/db.ts` | Dexie database (threads + messages tables) |
| `src/lib/threads.ts` | Thread CRUD + the per-thread `ThreadHistoryAdapter` that persists to Dexie |
| `src/lib/mockModel.ts` | **Inference seam** — mock `ChatModelAdapter` |
| `src/components/ChatRuntimeProvider.tsx` | Wires `useLocalRuntime` (model + history) per thread |
| `src/components/Thread.tsx` | Message list, bubbles, markdown, composer |
| `src/components/HistorySidebar.tsx` | Slide-in history drawer (live Dexie query) |
| `src/components/ChatApp.tsx` | Mobile shell: header, active thread, sidebar |
| `src/app/sw.ts` | Service worker source (serwist) |
