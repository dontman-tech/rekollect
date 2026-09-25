# Re-kollect — Post-Deployment Guide

Run these steps **in order** after `git clone` + Firebase project setup. Each
step is safe to re-run; nothing here is destructive to data.

> Assumes: Node 18+, Firebase CLI (`npm i -g firebase-tools`), logged in
> (`firebase login`), a Firebase project created, and its web config in
> `lib/firebase_options.dart`.

---

## 1. Deploy the backend

```bash
cd <repo-root>
firebase use <your-project-id>        # select your project
firebase deploy --only firestore:rules,firestore:indexes,functions
```

- `firestore:rules` — activates the security rules (owner-only writes,
  transactional status transitions, append-only location log, admin-only
  dispute resolution, participant-locked chat). **Until this runs, the
  database is effectively open to any authenticated client.**
- `firestore:indexes` — composite indexes for the scoped queries (pending
  jobs, per-user streams, dispute queue, chat threads).
- `functions` — deploys both cloud functions:
  - `revertStaleClaims` (every 5 min): reverts claims older than 4h back to
    pending, applies a no-show strike, re-notifies collectors.
  - `spawnRecurringRequests`: after each confirmed pickup on a recurring
    request, creates next week's request (idempotent via `spawned_from`).

Verify: `firebase functions:log` lists both functions; Firestore → Rules tab
shows the new ruleset.

## 2. Seed the first admin

Admins are marked on the user document (`role: "admin"`):

1. Sign up in the app as the account that should be admin (or a dedicated
   ops account).
2. Firebase console → Firestore → `users` collection → find that user's doc.
3. Set `role` to `"admin"`.

The admin console (disputes, reports, stats) appears on that account's next
app open.

## 3. Enable the services the app calls

In the Firebase console:

- **Authentication** → enable Email/Password.
- **Firestore** → confirm production mode and your region (region is fixed at
  creation; changing it later requires data migration).
- **Cloud Messaging** → nothing to configure, but confirm FCM token
  registration works on a real Android device (a device registers its token
  the first time the app opens).
- **Blaze plan** — required for Cloud Functions (both scheduled/spawn ones).

## 4. Smoke-test the core loop on real devices

Two devices (or device + emulator), real installs:

1. **Generator flow**: sign up → profile → new request (waste type, quantity
   band, schedule) → appears in the collector pool.
2. **Collector flow**: sign up → profile config (waste types, vehicle +
   capacity, coverage radius) → claim a job inside the 50m geofence → confirm
   pickup → verify the GPS log entry exists.
3. **Confirmation loop**: generator confirms "Collected ✓" → job closes.
   Then let a pickup be reported "not collected" → verify a dispute + strike
   were created.
4. **Recurring**: create a weekly recurring request → confirm one pickup →
   verify next week's request was auto-created.
5. **Chat**: on a claimed request, message both ways → renders for both.
6. **Offline path**: airplane mode on the collector device → attempt claim →
   "saved offline" message → network back → claim retries and lands.

## 5. Verify the accountability safeguards

- Attempt to claim while >50m from the job's coordinates → app refuses with
  the distance message.
- Suspend a test collector (3 strikes, or manually set `strikes: 3` on their
  user doc) → claims blocked.
- From a non-admin account, attempt to edit another user's doc via the REST
  API → rules must reject.

## 6. Ongoing operations

| Cadence | Action |
|---|---|
| Daily | Admin console: open disputes, twice-failed jobs |
| Weekly | Review new collectors' reliability scores before more volume |
| On dispute | Admin console → review evidence (distance logs, chat) → resolve (collector-favor refunds the strike) |
| Rule changes | Edit rules **in this repo** then `firebase deploy --only firestore:rules` — never console-only, or repo and production drift |
| Function changes | Edit `functions/index.js` then `firebase deploy --only functions` |

## 7. Known limits (by design, for launch)

- No in-app payments — earnings tracked as job counts, not money.
- Hazardous-waste routing exists; physical hazardous-waste handling is an
  operational responsibility — consider a dedicated collector cohort.
- Recurrence spawns only after a confirmed pickup; a skipped week spawns
  nothing (deliberate).
- Offline outbox covers claims; completions need connectivity for the GPS
  check (by design — never fake a location).

---

*Error during any step: check `firebase functions:log` and the Rules
Playground (Firestore console) before filing an issue.*
