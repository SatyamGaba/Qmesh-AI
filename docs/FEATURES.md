# QMesh — Features & Demo Talking Points

Demo-facing capabilities, each with the one-liner to *say*, what to *show*, and the
honest caveat so nothing surprises you live. Every claim here was measured on real
hardware (Galaxy S25 Ultra / Snapdragon 8 Elite + X Elite laptop) on 2026-08-04 — see
[`STATUS.md`](../STATUS.md) for the raw numbers.

---

## 1. Three inference modes, one app — switch live

**Say:** "Same chat, three engines: fully on the phone, on the laptop, or split across
both. Pick from the header — it switches on the next message."

**Show:** The mode picker dropdown. Send a message on **On-device** (radio can be off),
then switch to **Remote** and send again — same conversation, different hardware.

- **On-device** — llama.cpp running *on the phone* (Snapdragon 8 Elite CPU), ~10 tok/s
  decode. No network needed at all.
- **Remote** — engine on the laptop over Wi-Fi, ~37 tok/s decode.
- **Split** — phone + laptop share the model (in progress).

**Caveat:** Split mode isn't wired yet; it shows "not set up" (greyed). On-device and
Remote are live.

---

## 2. Live engine health at a glance

**Say:** "Each mode shows a live status dot — green means that engine is reachable right
now, so you know before you switch."

**Show:** Open the picker; the dots probe each engine's `/v1/models` on open. Kill the
laptop server and reopen — Remote goes red.

**Caveat:** The probe runs when the menu opens (not continuously), so a dot reflects the
moment you opened it.

---

## 3. Hot-swap hardware mid-conversation — no state lost

**Say:** "I can move a running conversation between the phone and the laptop and never
lose the thread — the full history follows."

**Show:** Have a multi-turn chat on Remote, switch to On-device, continue. The assistant
still has all prior context.

**Why it's safe:** The app re-sends the whole conversation each turn, so switching engines
never drops or corrupts anything.

**Caveat (worth pre-empting):** The engine you switch *to* recomputes the conversation from
scratch (its cache is separate) — so the **first** reply after a switch has a short "warm-up"
pause, proportional to conversation length. On the phone (slower prefill, ~50–90 tok/s) a
long-conversation switch is where you'll feel it. Switching *back* to an engine you used
before is nearly instant (see #4).

---

## 4. Warm resume — recent chats stay instant

**Say:** "Jump back to a conversation you were just in and it resumes instantly — no
re-reading the whole history."

**Show:** Bounce between two or three chats; after the first visit, each resumes with no
warm-up pause.

**Why:** Each engine keeps a per-conversation KV cache in memory and reuses the matching
prefix. Measured: returning to a prior conversation reused **79 of 99** / **22 of 23**
prompt tokens from cache — only the new message gets recomputed. This holds across "new
chat" too: starting a fresh conversation does **not** evict the previous ones.

**Caveat:** Each engine holds **up to 4** conversations warm at once (server slot limit). A
5th distinct conversation evicts the least-recently-used one — returning to *that* one pays
a one-time warm-up. Restarting the phone's engine (or a reboot) clears all warm caches. None
of this loses data — only affects how fast the *first* token comes back.

**Demo tip:** Keep it to ≤4 open conversations and switching stays snappy throughout.

---

## 5. Fully offline & private — everything stays on-device

**Say:** "On-device mode runs the model on the phone and stores every conversation locally.
Turn the radio off — it still works."

**Show:** On-device mode with airplane mode on; send a message, get a real answer. Reopen
the app — history is still there.

- Inference: llama.cpp on the phone, no server call leaves the device.
- Storage: conversations persist in the browser's IndexedDB on the phone.
- Privacy tiers by mode: On-device (radio can be off) → Split/Remote (stay on your LAN).

**Caveat:** Remote and Split use the local network (LAN only, not the internet) — private,
but not radio-off. Only On-device is truly network-free.

---

## 6. Installable, app-like (PWA)

**Say:** "It installs to the home screen like a native app — no app store."

**Show:** Chrome → "Add to Home Screen"; launches standalone.

**Caveat:** Offline caching / installability is a production-build feature (the service
worker is disabled in dev mode) — demo from a production build to show this.

---

## Quick reference — measured numbers (2026-08-04)

| Property | On-device (phone) | Remote (laptop) |
|---|---:|---:|
| Decode speed | ~10 tok/s (peaks at 6 threads) | ~37 tok/s |
| Prefill speed | ~50–92 tok/s | ~150–190 tok/s |
| Cold vs. warm resume | full prefill → cached prefix reused | same |
| Warm conversations held | up to 4 (server slots) | up to 4 |
| Network required | none (radio off) | LAN only |

Model: Qwen3-4B-Instruct-2507 Q4_0 (2.21 GiB) on both. Same llama.cpp `b10270` binary,
different hardware.
