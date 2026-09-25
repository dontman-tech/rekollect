import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/app_user.dart';
import '../models/pickup_request.dart';
import '../services/dialer_service.dart';
import '../services/firestore_service.dart';
import '../services/location_service.dart';
import '../services/route_service.dart';
import '../widgets/eco_background.dart';
import '../widgets/glass_card.dart';

class CollectorScreen extends StatefulWidget {
  const CollectorScreen({super.key, required this.user, required this.firestore});

  final AppUser user;
  final FirestoreService firestore;

  @override
  State<CollectorScreen> createState() => _CollectorScreenState();
}

class _CollectorScreenState extends State<CollectorScreen> {
  /// Route density mode is OPTIONAL: off by default, the collector just sees
  /// the normal job list. On, nearby pending jobs are clustered and ordered
  /// into a short sweep route.
  bool _routeMode = false;
  final _location = const LocationService();
  final _planner = const RoutePlanner();

  Future<void> _signOut() => FirebaseAuth.instance.signOut();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: EcoBackground(
        child: SafeArea(
          child: StreamBuilder<List<PickupRequest>>(
            stream: widget.firestore.streamOpenRequests(),
            builder: (context, snapshot) {
              final allRequests = snapshot.data ?? const <PickupRequest>[];
              final visibleRequests = allRequests
                  .where((request) => request.isPending || (request.isClaimed && request.collectorId == widget.user.uid))
                  .toList();
              return CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: _Header(
                        name: widget.user.name,
                        onSignOut: _signOut,
                        routeMode: _routeMode,
                        onRouteModeChanged: (value) => setState(() => _routeMode = value),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    sliver: SliverToBoxAdapter(child: _ReliabilityStrip(uid: widget.user.uid, firestore: widget.firestore)),
                  ),
                  if (_routeMode)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      sliver: SliverToBoxAdapter(
                        child: FutureBuilder<Position>(
                          future: _location.getCurrentPosition(),
                          builder: (context, positionSnapshot) {
                            final position = positionSnapshot.data;
                            if (position == null) {
                              return const GlassCard(
                                child: Text('Turn on location to plan a density route.'),
                              );
                            }
                            final route = _planner.plan(
                              openRequests: allRequests.where((request) => request.isPending).toList(),
                              collectorLatitude: position.latitude,
                              collectorLongitude: position.longitude,
                            );
                            return _RouteCard(route: route, firestore: widget.firestore, collector: widget.user);
                          },
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    sliver: SliverToBoxAdapter(child: _JobsMap(requests: visibleRequests)),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    sliver: SliverToBoxAdapter(
                      child: Text('Available pickup jobs', style: Theme.of(context).textTheme.titleLarge),
                    ),
                  ),
                  if (visibleRequests.isEmpty)
                    const SliverPadding(
                      padding: EdgeInsets.fromLTRB(20, 0, 20, 30),
                      sliver: SliverToBoxAdapter(child: GlassCard(child: Text('No available pickup jobs yet.'))),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            if (index.isOdd) return const SizedBox(height: 12);
                            final request = visibleRequests[index ~/ 2];
                            return _CollectorJobCard(
                              request: request,
                              firestore: firestore,
                              collector: user,
                            );
                          },
                          childCount: visibleRequests.length * 2 - 1,
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

/// The collector's own accountability record: reliability score and strikes.
class _ReliabilityStrip extends StatelessWidget {
  const _ReliabilityStrip({required this.uid, required this.firestore});

  final String uid;
  final FirestoreService firestore;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.streamCollectorRecord(uid),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() ?? const <String, dynamic>{};
        final completed = (data['completed_count'] as num?)?.toInt() ?? 0;
        final disputed = (data['disputed_count'] as num?)?.toInt() ?? 0;
        final strikes = (data['strikes'] as num?)?.toInt() ?? 0;
        final suspended = data['suspended'] as bool? ?? false;
        final total = completed + disputed;
        final score = total == 0 ? null : (completed / total * 100).round();
        return GlassCard(
          child: Row(
            children: [
              const Icon(Icons.verified_outlined, color: Color(0xFF4ADE80)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  score == null
                      ? 'Reliability: no completed pickups yet'
                      : 'Reliability: $score% ($completed completed, $disputed disputed) · Strikes: $strikes/3',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
              if (suspended)
                const Text('SUSPENDED', style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.w800)),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.onSignOut,
    required this.routeMode,
    required this.onRouteModeChanged,
  });

  final String name;
  final VoidCallback onSignOut;
  final bool routeMode;
  final ValueChanged<bool> onRouteModeChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Hello, $name', style: Theme.of(context).textTheme.titleLarge),
              Text('Collector dashboard', style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        Tooltip(
          message: 'Route density mode: cluster nearby jobs into one sweep',
          child: Switch(
            value: routeMode,
            onChanged: onRouteModeChanged,
            activeColor: const Color(0xFF10B981),
          ),
        ),
        IconButton(onPressed: onSignOut, icon: const Icon(Icons.logout)),
      ],
    );
  }
}

/// Route density mode card: nearby pending jobs ordered as one sweep, each
/// stop claimable inline. Jobs beyond the planning radius are counted, not
/// hidden — the collector still knows they exist.
class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.route, required this.firestore, required this.collector});

  final PlannedRoute route;
  final FirestoreService firestore;
  final AppUser collector;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Density route (optional sweep)',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('${route.stops.length} nearby stops · ${route.skipped.length} jobs beyond 1.5 km',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 10),
          if (route.stops.isEmpty)
            const Text('No pending jobs within 1.5 km.', style: TextStyle(color: Colors.white70))
          else
            ...route.stops.asMap().entries.map((entry) {
              final stop = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Text('${entry.key + 1}.',
                        style: const TextStyle(color: Color(0xFF4ADE80), fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${stop.request.wasteType} · ${stop.distanceMeters.round()} m',
                        style: const TextStyle(color: Colors.white),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        try {
                          final position = await const LocationService().getCurrentPosition();
                          await firestore.claimRequest(
                            requestId: stop.request.requestId,
                            collectorId: collector.uid,
                          );
                          await firestore.logLocationEvent(
                            requestId: stop.request.requestId,
                            actorId: collector.uid,
                            event: 'claimed',
                            latitude: position.latitude,
                            longitude: position.longitude,
                            accuracyMeters: position.accuracy,
                          );
                        } catch (_) {
                          // claim races are surfaced on the job card itself
                        }
                      },
                      child: const Text('Claim'),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _JobsMap extends StatelessWidget {
  const _JobsMap({required this.requests});

  final List<PickupRequest> requests;
  static const _buea = LatLng(4.1593, 9.2435);

  @override
  Widget build(BuildContext context) {
    final center = requests.isEmpty ? _buea : LatLng(requests.first.latitude, requests.first.longitude);
    return GlassCard(
      padding: const EdgeInsets.all(10),
      child: SizedBox(
        height: 260,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: FlutterMap(
            options: MapOptions(initialCenter: center, initialZoom: 13),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'ai.arena.rekollect',
              ),
              MarkerLayer(
                markers: requests
                    .map(
                      (request) => Marker(
                        point: LatLng(request.latitude, request.longitude),
                        width: 54,
                        height: 54,
                        child: _MapPin(type: request.generatorType, claimed: request.isClaimed),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MapPin extends StatelessWidget {
  const _MapPin({required this.type, required this.claimed});

  final String type;
  final bool claimed;

  @override
  Widget build(BuildContext context) {
    final icon = switch (type) {
      'household' => Icons.home_rounded,
      'business' => Icons.store_rounded,
      _ => Icons.person_rounded,
    };
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: claimed ? const Color(0xFF2ECC71) : const Color(0xFF4ADE80),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Icon(icon, color: const Color(0xFF064E3B)),
    );
  }
}

class _CollectorJobCard extends StatefulWidget {
  const _CollectorJobCard({required this.request, required this.firestore, required this.collector});

  final PickupRequest request;
  final FirestoreService firestore;
  final AppUser collector;

  @override
  State<_CollectorJobCard> createState() => _CollectorJobCardState();
}

class _CollectorJobCardState extends State<_CollectorJobCard> {
  static String _friendly(Object error) => error is FirestoreServiceException
      ? error.message
      : 'Something went wrong — check your connection and try again.';
  bool _loading = false;
  String? _message;
  final _location = const LocationService();

  Future<void> _claim() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      await widget.firestore.claimRequest(requestId: widget.request.requestId, collectorId: widget.collector.uid);
      // Breadcrumb the claim into the location log — dispute evidence starts
      // here, not only at completion.
      try {
        final position = await _location.getCurrentPosition();
        await widget.firestore.logLocationEvent(
          requestId: widget.request.requestId,
          actorId: widget.collector.uid,
          event: 'claimed',
          latitude: position.latitude,
          longitude: position.longitude,
          accuracyMeters: position.accuracy,
        );
      } catch (_) {
        // Location logging is evidence, not a claim requirement — a denied
        // permission here must not block claiming; completion still requires GPS.
      }
    } catch (error) {
      setState(() => _message = _friendly(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _complete() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final position = await _location.getCurrentPosition();
      // Log the arrival position, then attempt the geofenced completion.
      await widget.firestore.logLocationEvent(
        requestId: widget.request.requestId,
        actorId: widget.collector.uid,
        event: 'completion_attempt',
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
      );
      await widget.firestore.completeRequest(
        requestId: widget.request.requestId,
        collectorId: widget.collector.uid,
        collectorLatitude: position.latitude,
        collectorLongitude: position.longitude,
        accuracyMeters: position.accuracy,
      );
      setState(() => _message = 'Marked complete — waiting for the customer to confirm collection.');
    } catch (error) {
      setState(() => _message = _friendly(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final canComplete = request.isClaimed && request.collectorId == widget.collector.uid;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TypeTag(type: request.generatorType),
              const Spacer(),
              Text(request.status.toUpperCase(), style: const TextStyle(color: Color(0xFF4ADE80), fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          Text('${request.wasteType} waste pickup', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('Coordinates: ${request.latitude.toStringAsFixed(5)}, ${request.longitude.toStringAsFixed(5)}'),
          if (request.directionsLandmarks != null) ...[
            const SizedBox(height: 6),
            Text('Directions / Landmarks: ${request.directionsLandmarks}'),
          ],
          const SizedBox(height: 12),
          const _PaymentDisclaimer(),
          const SizedBox(height: 12),
          FutureBuilder<AppUser?>(
            future: widget.firestore.getUser(request.generatorId),
            builder: (context, snapshot) {
              final generator = snapshot.data;
              return Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: generator == null ? null : () => DialerService.openDialer(generator.phoneNumber),
                      icon: const Icon(Icons.call),
                      label: const Text('Call Customer'),
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF4ADE80), foregroundColor: const Color(0xFF064E3B)),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          if (request.isPending)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _loading ? null : _claim,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white),
                child: Text(_loading ? 'Please wait...' : 'Claim Job'),
              ),
            ),
          if (canComplete)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _loading ? null : _complete,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white),
                child: Text(_loading ? 'Please wait...' : 'Mark Complete'),
              ),
            ),
          if (canComplete) ...[
            const SizedBox(height: 6),
            const Text(
              'You must be within 50 m of the pickup point to mark complete. The customer then confirms collection.',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 8),
            Text(_message!, style: const TextStyle(color: Color(0xFF4ADE80), fontWeight: FontWeight.w700)),
          ],
        ],
      ),
    );
  }
}

class _PaymentDisclaimer extends StatelessWidget {
  const _PaymentDisclaimer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF4ADE80).withOpacity(0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.25)),
      ),
      child: const Text(
        'All payments are to be agreed upon by the collector and provider independently outside of this platform.',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _TypeTag extends StatelessWidget {
  const _TypeTag({required this.type});

  final String type;

  @override
  Widget build(BuildContext context) {
    final icon = switch (type) {
      'household' => Icons.home_rounded,
      'business' => Icons.store_rounded,
      _ => Icons.person_rounded,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.white),
          const SizedBox(width: 6),
          Text(type.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
        ],
      ),
    );
  }
}
