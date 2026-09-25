# Re-kollect

Flutter + Firebase MVP built directly from the attached PRD.

Implemented scope only:
- Firebase Phone Authentication onboarding for Generator and Collector roles.
- Firestore-backed `users`, `collectors`, and `requests` collections.
- Generator pickup request form with generator type, waste type, OpenStreetMap/Nominatim location lookup, map pin, directions/landmarks, and payment disclaimer.
- Collector dashboard with real-time request list, OpenStreetMap markers, generator-type tags/icons, claim, complete, and call-customer actions.
- Call buttons open the native dialer through Flutter platform channels.
- Firebase Cloud Messaging client setup for role topics.
- Plus Jakarta Sans and PRD-defined glassmorphism/eco-green UI.

## Firebase setup

Add your Firebase configuration before running:
- Android: place `google-services.json` in `android/app/` and set the Firebase values in `lib/firebase_options.dart`.
- iOS: place `GoogleService-Info.plist` in `ios/Runner/` and set the Firebase values in `lib/firebase_options.dart`.
- Enable Firebase Phone Authentication, Firestore, and Firebase Cloud Messaging.
- Whitelist hackathon test phone numbers/codes in the Firebase console.

## Run

```bash
flutter pub get
flutter run
```
# rekollect

## Production accountability systems

- **Location-log pickup confirmation** — collectors claim and complete with GPS; completion is only accepted within **50 m** of the job location. Every position write lands in an append-only `requests/{id}/location_log` subcollection as evidence.
- **Two-sided confirmation** — after completion, the generator confirms ("Was your trash collected?") or reports it was **not collected**, which opens a dispute and strikes the collector immediately.
- **Reliability score & strikes** — per-collector `completed_count` / `disputed_count` / `no_show_count` / `strikes` on the `collectors` doc; 3 strikes suspend claiming. Collectors see their own score strip.
- **Fallback dispatch** — the scheduled Cloud Function in `functions/` reverts claims older than 4 h back to `pending` (with a no-show strike) so trash never strands on a dead claim. Deploy: `firebase deploy --only functions`.
- **Admin dispute workflow** — admins (role `admin` on the `users` doc) see open disputes with the evidence (pickup distance, log entries) and resolve: collector at fault (strike stands) or collection verified (confirmation flips, strike refunded).
- **Route density mode (optional)** — a collector-side toggle that clusters pending jobs within 1.5 km into one ordered sweep (max 5 stops). Off by default.

Deploy rules and indexes after installing: `firebase deploy --only firestore:rules,firestore:indexes,functions`.

## Marketplace features (batch 2)

- **Scheduled pickups & weekly recurrence** — generators pick a date/time (or ship ASAP) and can mark a request "repeat every week"; a cloud function spawns the next week's request after each confirmation.
- **Minimal in-app chat** — a per-request message thread between the assigned collector and the generator ("on my way, 10 min"), rules-locked to the two participants.
- **Zone/coverage config** — collectors set the waste types they handle, their vehicle, and a coverage radius (0.5–25 km); jobs outside any of these never reach their board.
- **Waste-type routing** — Organic/Plastic/Electronic/Bulky/Hazardous. Hazardous only reaches collectors who opted in.
- **Vehicle capacity + quantity tagging** — generators declare a size band (~15/40/100/400 kg); collectors' vehicles carry 20 (bicycle) to 1000 (truck) kg. Jobs heavier than the collector's vehicle are hidden and rejected.
- **Offline-tolerant collector actions** — failed claims (and messages) queue locally and retry automatically when connectivity returns; the UI says "saved offline" instead of erroring.

Deploy: `firebase deploy --only firestore:rules,firestore:indexes,functions` (the recurrence + fallback dispatch functions live in `functions/`).
