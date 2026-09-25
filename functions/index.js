// Fallback dispatch: no claimed request may silently strand trash. A claim
// older than 4 hours reverts to `pending` (back in the open pool), the
// collector is logged a no-show strike, and at 3 strikes the collector is
// suspended from claiming. Deployed with `firebase deploy --only functions`.
const functions = require("firebase-functions");
const admin = require("firebase-admin");

admin.initializeApp();

const CLAIM_TIMEOUT_MS = 4 * 60 * 60 * 1000;
const MAX_STRIKES = 3;

exports.fallbackDispatch = functions.pubsub
  .schedule("every 5 minutes")
  .timeZone("Africa/Douala")
  .onRun(async (context) => {
    const db = admin.firestore();
    const cutoff = admin.firestore.Timestamp.fromMillis(Date.now() - CLAIM_TIMEOUT_MS);
    const stale = await db
      .collection("requests")
      .where("status", "==", "claimed")
      .where("claimed_at", "<", cutoff)
      .get();

    let reverted = 0;
    for (const doc of stale.docs) {
      const collectorId = doc.get("collector_id") || "";
      const batch = db.batch();
      batch.update(doc.ref, {
        status: "pending",
        collector_id: admin.firestore.FieldValue.delete(),
        claimed_at: admin.firestore.FieldValue.delete(),
        fallback_reverted: true,
        fallback_reverted_at: admin.firestore.FieldValue.serverTimestamp(),
      });
      if (collectorId) {
        const collectorRef = db.collection("collectors").doc(collectorId);
        batch.create(collectorRef, { strikes: 1, no_show_count: 1 });
        // create() fails if the doc exists; fall back to an increment below.
        batch.set(
          collectorRef,
          {
            no_show_count: admin.firestore.FieldValue.increment(1),
            strikes: admin.firestore.FieldValue.increment(1),
            updated_at: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
      await batch.commit().catch(async () => {
        // batch failed (e.g. create() collision) — apply the increments alone.
        await doc.ref.update({
          status: "pending",
          collector_id: admin.firestore.FieldValue.delete(),
          claimed_at: admin.firestore.FieldValue.delete(),
          fallback_reverted: true,
          fallback_reverted_at: admin.firestore.FieldValue.serverTimestamp(),
        });
        if (collectorId) {
          await db
            .collection("collectors")
            .doc(collectorId)
            .set(
              {
                no_show_count: admin.firestore.FieldValue.increment(1),
                strikes: admin.firestore.FieldValue.increment(1),
                updated_at: admin.firestore.FieldValue.serverTimestamp(),
              },
              { merge: true },
            );
        }
      });
      if (collectorId) {
        await db.collection("strikes").add({
          collector_id: collectorId,
          kind: "claim_timeout",
          request_id: doc.id,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      reverted += 1;
    }

    // Suspension sweep: any collector at the strike cap loses claim rights.
    const atCap = await db
      .collection("collectors")
      .where("strikes", ">=", MAX_STRIKES)
      .get();
    for (const doc of atCap.docs) {
      if (!doc.get("suspended")) {
        await doc.ref.set({ suspended: true, updated_at: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
      }
    }

    functions.logger.info("fallbackDispatch", { reverted, suspendedSweep: atCap.size });
    return null;
  });
