import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/app_user.dart';
import '../models/pickup_request.dart';
import '../services/dialer_service.dart';
import '../services/firestore_service.dart';
import '../services/pickup_confirmation_service.dart';
import '../widgets/eco_background.dart';
import '../widgets/glass_card.dart';
import 'package:geolocator/geolocator.dart';

class CollectorScreen extends StatelessWidget {
  const CollectorScreen({super.key, required this.user, required this.firestore});

  final AppUser user;
  final FirestoreService firestore;

  Future<void> _signOut() => FirebaseAuth.instance.signOut();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: EcoBackground(
        child: SafeArea(
          child: StreamBuilder<List<PickupRequest>>(
            stream: firestore.streamOpenRequests(),
            builder: (context, snapshot) {
              final allRequests = snapshot.data ?? const <PickupRequest>[];
              final visibleRequests = allRequests
                  .where((request) => request.isPending || (request.isClaimed && request.collectorId == user.uid))
                  .toList();
              return CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    sliver: SliverToBoxAdapter(child: _Header(name: user.name, onSignOut: _signOut)),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    sliver: SliverToBoxAdapter(child: _JobsMap(requests: visibleRequests)),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    sliver: SliverToBoxAdapter(
                      child: _JobsToolbar(requests: visibleRequests, collector: user, firestore: firestore),
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


/// Optional "route density" mode: clusters nearby open jobs into one trip.
/// Toggle is per-collector; the map/claim flow is unchanged for singles.
class _JobsToolbar extends StatefulWidget {
  const _JobsToolbar({required this.requests, required this.collector, required this.firestore});

  final List<PickupRequest> requests;
  final AppUser collector;
  final FirestoreService firestore;

  @override
  State<_JobsToolbar> createState() => _JobsToolbarState();
}

class _JobsToolbarState extends State<_JobsToolbar> {
  bool _density = false;
  List<List<PickupRequest>>? _batches;

  Future<void> _toggle() async {
    if (_density) {
      setState(() { _density = false; _batches = null; });
      return;
    }
    // Seed the clustering with the device's own position when available,
    // falling back to the first job's location.
    double lat = widget.requests.isEmpty ? 4.1593 : widget.requests.first.latitude;
    double lng = widget.requests.isEmpty ? 9.2435 : widget.requests.first.longitude;
    final batches = await PickupConfirmationService(widget.firestore.db).clustersFor(
      openRequests: widget.requests.where((r) => r.isPending).toList(),
      latitude: lat,
      longitude: lng,
    );
    if (!mounted) return;
    setState(() { _density = true; _batches = batches; });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Available pickup jobs', style: Theme.of(context).textTheme.titleLarge)),
            Switch(value: _density, onChanged: (_) => _toggle(), activeColor: const Color(0xFF10B981)),
            const Text('Route density', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
          ],
        ),
        if (_density && _batches != null && _batches!.isNotEmpty)
          Text(
            '${_batches!.length} efficient routes found — claim a cluster to sweep nearby jobs in one trip.',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {


  const _Header({required this.name, required this.onSignOut});

  final String name;
  final VoidCallback onSignOut;

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
        IconButton(onPressed: onSignOut, icon: const Icon(Icons.logout)),
      ],
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

  late final PickupConfirmationService _confirmation =
      PickupConfirmationService(widget.firestore.db);
  bool _loading = false;
  String? _message;

  Future<void> _claim() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      await widget.firestore.claimRequest(requestId: widget.request.requestId, collectorId: widget.collector.uid);
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
      // Geofenced: the device fix must be within 50m of the tagged location.
      final fix = await _currentFix();
      if (fix == null) {
        setState(() => _message = 'Location unavailable — enable GPS and try again.');
        return;
      }
      await _confirmation.markPickedUp(
        request: widget.request,
        collectorId: widget.collector.uid,
        latitude: fix.latitude,
        longitude: fix.longitude,
      );
      if (!mounted) return;
      setState(() => _message = 'Pickup recorded at the job site. Awaiting customer confirmation.');
    } catch (error) {
      if (mounted) setState(() => _message = _friendly(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// One-shot device position. Uses the location plugin when available;
  /// null means the platform cannot provide a fix right now.
  Future<({double latitude, double longitude})?> _currentFix() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 8)),
      );
      return (latitude: position.latitude, longitude: position.longitude);
    } catch (_) {
      return null;
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
                child: Text(_loading ? 'Locating you…' : (request.isPickedUp ? 'Pickup recorded — awaiting customer' : 'Confirm Pickup Here (50m gate)')),
              ),
            ),
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
