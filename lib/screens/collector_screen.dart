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
import '../services/outbox_service.dart';
import '../services/geo.dart' as geo;
import '../services/route_service.dart';
import '../widgets/eco_background.dart';
import '../widgets/glass_card.dart';

class CollectorScreen extends StatefulWidget {
  const CollectorScreen({super.key, required this.user, required this.firestore, required this.outbox});

  final AppUser user;
  final FirestoreService firestore;
  final OutboxService outbox;

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
              // Job matching: a job reaches this collector only when its
              // waste type is one they handle, their vehicle can carry the
              // declared quantity, and it is inside their coverage zone.
              final visibleRequests = allRequests.where((request) {
                if (request.isClaimed && request.collectorId == widget.user.uid) return true;
                if (!request.isPending) return false;
                if (!widget.user.handlesWaste(request.wasteType)) return false;
                if (request.estimatedKg > widget.user.capacityKg) return false;
                final distanceKm = geo.distanceMeters(
                      widget.user.zoneCenterLat,
                      widget.user.zoneCenterLng,
                      request.latitude,
                      request.longitude,
                    ) / 1000;
                return distanceKm <= widget.user.zoneRadiusKm;
              }).toList();
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
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    sliver: SliverToBoxAdapter(
                      child: _CollectorProfileCard(user: widget.user, firestore: widget.firestore),
                    ),
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
    } on FirestoreServiceException catch (error) {
      // Offline-tolerant: queue the claim for automatic retry when
      // connectivity returns instead of dying with an error.
      await widget.outbox.enqueue('claim', {
        'request_id': widget.request.requestId,
        'collector_id': widget.collector.uid,
      });
      setState(() => _message = '${error.message} (saved offline — will retry when back online)');
      return;
    }
    try {
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
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _MiniTag(label: '~${request.estimatedKg} kg'),
              if (request.isRecurring) const _MiniTag(label: 'Weekly', highlight: true),
              if (request.scheduledAt != null) _MiniTag(label: 'For ${_fmt(request.scheduledAt!)}'),
            ],
          ),
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
          if (request.collectorId == widget.collector.uid) ...[
            const SizedBox(height: 12),
            _RequestChat(requestId: request.requestId, firestore: widget.firestore, me: widget.collector.uid),
          ],
        ],
      ),
    );
  }

  static String _fmt(Timestamp timestamp) {
    final d = timestamp.toDate();
    return '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

/// Minimal per-request chat between the collector and the generator.
class _RequestChat extends StatelessWidget {
  const _RequestChat({required this.requestId, required this.firestore, required this.me});

  final String requestId;
  final FirestoreService firestore;
  final String me;

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        collapsedIconColor: Colors.white70,
        iconColor: Colors.white70,
        title: const Text('Message customer', style: TextStyle(color: Colors.white70, fontSize: 13)),
        children: [
          SizedBox(
            height: 180,
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: firestore.streamMessages(requestId),
              builder: (context, snapshot) {
                final messages = snapshot.data ?? const <Map<String, dynamic>>[];
                if (messages.isEmpty) {
                  return const Text('No messages yet.', style: TextStyle(color: Colors.white38, fontSize: 12));
                }
                return ListView.builder(
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final mine = message['sender_id'] == me;
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        constraints: const BoxConstraints(maxWidth: 280),
                        decoration: BoxDecoration(
                          color: mine ? const Color(0xFF10B981).withOpacity(0.8) : Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(message['text'] as String? ?? '', style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(hintText: 'On my way, 10 min…'),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send, color: Color(0xFF4ADE80)),
                onPressed: () {
                  firestore.sendMessage(requestId: requestId, senderId: me, text: controller.text);
                  controller.clear();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The collector's specialization config: handled waste types, vehicle
/// (capacity), and coverage-zone radius. Jobs outside any of these never
/// appear on the board.
class _CollectorProfileCard extends StatefulWidget {
  const _CollectorProfileCard({required this.user, required this.firestore});

  final AppUser user;
  final FirestoreService firestore;

  @override
  State<_CollectorProfileCard> createState() => _CollectorProfileCardState();
}

class _CollectorProfileCardState extends State<_CollectorProfileCard> {
  late final List<String> _wasteTypes = List.of(widget.user.wasteTypes);
  late String _vehicle = widget.user.vehicleType ?? 'motorbike';
  late double _zoneKm = widget.user.zoneRadiusKm;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.firestore.updateCollectorProfile(
        uid: widget.user.uid,
        wasteTypes: _wasteTypes,
        vehicleType: _vehicle,
        zoneRadiusKm: _zoneKm,
        zoneLatitude: widget.user.zoneCenterLat,
        zoneLongitude: widget.user.zoneCenterLng,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What I collect', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Only jobs matching these settings reach your board.', style: TextStyle(color: Colors.white60, fontSize: 12)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final type in kAllWasteTypes)
                FilterChip(
                  label: Text(type),
                  selected: _wasteTypes.contains(type),
                  onSelected: (selected) => setState(() {
                    selected ? _wasteTypes.add(type) : _wasteTypes.remove(type);
                  }),
                  selectedColor: const Color(0xFF4ADE80).withOpacity(0.35),
                  backgroundColor: Colors.white.withOpacity(0.08),
                  labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
                  checkmarkColor: Colors.white,
                  side: BorderSide(color: Colors.white.withOpacity(0.25)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _vehicle,
            dropdownColor: const Color(0xFF064E3B),
            decoration: const InputDecoration(labelText: 'Vehicle type'),
            items: [
              for (final entry in kVehicleCapacities.entries)
                DropdownMenuItem(value: entry.key, child: Text('${entry.key} — up to ${entry.value} kg')),
            ],
            onChanged: (value) => setState(() => _vehicle = value ?? _vehicle),
          ),
          const SizedBox(height: 10),
          Text('Coverage zone: ${_zoneKm.toStringAsFixed(1)} km around my location', style: const TextStyle(color: Colors.white)),
          Slider(
            value: _zoneKm,
            min: 0.5,
            max: 25,
            divisions: 49,
            activeColor: const Color(0xFF4ADE80),
            onChanged: (value) => setState(() => _zoneKm = value),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white),
              child: Text(_saving ? 'Saving...' : 'Save my coverage'),
            ),
          ),
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

class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.label, this.highlight = false});

  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFFF59E0B).withOpacity(0.25) : Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}
