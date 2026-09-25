import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/firestore_service.dart';
import '../widgets/eco_background.dart';
import '../widgets/glass_card.dart';

/// Admin dispute workflow: every "not collected" report lands here with the
/// evidence trail (pickup distance, location-log entries) inlined, and the
/// admin resolves it one tap — collector at fault (strike stands, request
/// stays disputed) or collection verified (request flips to confirmed, the
/// strike is refunded).
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key, required this.user, required this.firestore});

  final AppUser user;
  final FirestoreService firestore;

  Future<void> _signOut() => FirebaseAuth.instance.signOut();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: EcoBackground(
        child: SafeArea(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: firestore.streamOpenDisputes(),
            builder: (context, snapshot) {
              final disputes = snapshot.data ?? const <Map<String, dynamic>>[];
              return CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Hello, ${user.name}', style: Theme.of(context).textTheme.titleLarge),
                                Text('Admin console — ${disputes.length} open dispute(s)',
                                    style: Theme.of(context).textTheme.bodyMedium),
                              ],
                            ),
                          ),
                          IconButton(onPressed: _signOut, icon: const Icon(Icons.logout)),
                        ],
                      ),
                    ),
                  ),
                  if (disputes.isEmpty)
                    const SliverPadding(
                      padding: EdgeInsets.fromLTRB(20, 0, 20, 30),
                      sliver: SliverToBoxAdapter(child: GlassCard(child: Text('No open disputes. All clear.'))),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => index.isOdd
                              ? const SizedBox(height: 12)
                              : _DisputeCard(dispute: disputes[index ~/ 2], firestore: firestore),
                          childCount: disputes.length * 2 - 1,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DisputeCard extends StatelessWidget {
  const _DisputeCard({required this.dispute, required this.firestore});

  final Map<String, dynamic> dispute;
  final FirestoreService firestore;

  static String _friendly(Object error) => error is FirestoreServiceException
      ? error.message
      : 'Something went wrong — try again.';

  @override
  Widget build(BuildContext context) {
    final requestId = dispute['request_id'] as String? ?? '';
    final reason = dispute['reason'] as String? ?? '';
    return GlassCard(
      child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: firestore.db.collection('requests').doc(requestId).get(),
        builder: (context, requestSnapshot) {
          final requestData = requestSnapshot.data?.data() ?? const <String, dynamic>{};
          final distance = (requestData['pickup_distance_meters'] as num?)?.round();
          final logCount = (requestData['location_log_count'] as num?)?.toInt() ?? 0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Request $requestId',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(reason, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 8),
              Text(
                'Evidence: pickup logged ${distance == null ? 'without coordinates' : '$distance m from the job point'} · $logCount location-log entries',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        try {
                          await firestore.resolveDispute(
                            disputeId: dispute['id'] as String,
                            collectorAtFault: true,
                          );
                        } catch (error) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendly(error))));
                        }
                      },
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444), foregroundColor: Colors.white),
                      child: const Text('Collector at fault'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        try {
                          await firestore.resolveDispute(
                            disputeId: dispute['id'] as String,
                            collectorAtFault: false,
                          );
                        } catch (error) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendly(error))));
                        }
                      },
                      style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF4ADE80)),
                      child: const Text('Collection verified'),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
