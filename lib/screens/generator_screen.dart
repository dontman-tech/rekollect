import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/app_user.dart';
import '../models/pickup_request.dart';
import '../services/dialer_service.dart';
import '../services/firestore_service.dart';
import '../services/nominatim_service.dart';
import '../widgets/eco_background.dart';
import '../widgets/glass_card.dart';
import '../widgets/section_label.dart';

class GeneratorScreen extends StatefulWidget {
  const GeneratorScreen({super.key, required this.user, required this.firestore});

  final AppUser user;
  final FirestoreService firestore;

  @override
  State<GeneratorScreen> createState() => _GeneratorScreenState();
}

class _GeneratorScreenState extends State<GeneratorScreen> {
  static String _friendly(Object error) => error is FirestoreServiceException
      ? error.message
      : 'Something went wrong — check your connection and try again.';
  final _locationController = TextEditingController();
  final _directionsController = TextEditingController();
  final _nominatim = const NominatimService();
  final LatLng _buea = const LatLng(4.1593, 9.2435);

  String _generatorType = 'individual';
  String _wasteType = 'Organic';
  LatLng? _selectedPoint;
  String? _message;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _generatorType = widget.user.generatorType ?? 'individual';
    _locationController.text = widget.user.generalLocation.isEmpty ? 'Buea, Cameroon' : widget.user.generalLocation;
  }

  @override
  void dispose() {
    _locationController.dispose();
    _directionsController.dispose();
    super.dispose();
  }

  Future<void> _findLocation() async {
    if (_locationController.text.trim().isEmpty) {
      setState(() => _message = 'Enter a pickup location in Buea.');
      return;
    }
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final point = await _nominatim.searchLocation(_locationController.text.trim());
      setState(() => _selectedPoint = point);
    } catch (error) {
      setState(() => _message = _friendly(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitRequest() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      var point = _selectedPoint;
      if (point == null) {
        point = await _nominatim.searchLocation(_locationController.text.trim());
        _selectedPoint = point;
      }
      await widget.firestore.createPickupRequest(
        generatorId: widget.user.uid,
        generatorType: _generatorType,
        wasteType: _wasteType,
        latitude: point.latitude,
        longitude: point.longitude,
        directionsLandmarks: _directionsController.text,
      );
      setState(() {
        _message = 'Pickup request submitted.';
        _directionsController.clear();
      });
    } catch (error) {
      setState(() => _message = _friendly(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signOut() => FirebaseAuth.instance.signOut();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: EcoBackground(
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: _Header(name: widget.user.name, onSignOut: _signOut),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                sliver: SliverToBoxAdapter(child: _requestForm(context)),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                sliver: SliverToBoxAdapter(
                  child: Text('My active pickup requests', style: Theme.of(context).textTheme.titleLarge),
                ),
              ),
              _activeRequests(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _requestForm(BuildContext context) {
    final point = _selectedPoint ?? _buea;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Request Pickup', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          const _PaymentDisclaimer(),
          const SizedBox(height: 18),
          const SectionLabel('Generator type'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _GlassChoice(label: 'Individual', value: 'individual', groupValue: _generatorType, onSelected: (value) => setState(() => _generatorType = value)),
              _GlassChoice(label: 'Household', value: 'household', groupValue: _generatorType, onSelected: (value) => setState(() => _generatorType = value)),
              _GlassChoice(label: 'Business', value: 'business', groupValue: _generatorType, onSelected: (value) => setState(() => _generatorType = value)),
            ],
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _wasteType,
            dropdownColor: const Color(0xFF064E3B),
            items: const [
              DropdownMenuItem(value: 'Organic', child: Text('Organic')),
              DropdownMenuItem(value: 'Plastic', child: Text('Plastic')),
              DropdownMenuItem(value: 'Electronic', child: Text('Electronic')),
            ],
            onChanged: (value) => setState(() => _wasteType = value ?? _wasteType),
            decoration: const InputDecoration(labelText: 'Waste type'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _locationController,
            decoration: const InputDecoration(labelText: 'Pickup location'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _directionsController,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Directions / Landmarks'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _loading ? null : _findLocation,
            icon: const Icon(Icons.map_outlined),
            label: const Text('Find location on OpenStreetMap'),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 210,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: FlutterMap(
                options: MapOptions(initialCenter: point, initialZoom: 13),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'ai.arena.rekollect',
                  ),
                  MarkerLayer(markers: [
                    Marker(
                      point: point,
                      width: 46,
                      height: 46,
                      child: const Icon(Icons.location_pin, color: Color(0xFF4ADE80), size: 42),
                    ),
                  ]),
                ],
              ),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, style: const TextStyle(color: Color(0xFF4ADE80), fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _loading ? null : _submitRequest,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: Text(_loading ? 'Please wait...' : 'Submit Pickup Request'),
          ),
        ],
      ),
    );
  }

  Widget _activeRequests() {
    return StreamBuilder<List<PickupRequest>>(
      stream: widget.firestore.streamMyRequests(widget.user.uid),
      builder: (context, snapshot) {
        final requests = (snapshot.data ?? const <PickupRequest>[])
            .where((request) => !request.isCompleted)
            .toList();
        if (requests.isEmpty) {
          return const SliverPadding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 30),
            sliver: SliverToBoxAdapter(
              child: GlassCard(child: Text('No active pickup requests yet.')),
            ),
          );
        }
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (index.isOdd) return const SizedBox(height: 12);
                final request = requests[index ~/ 2];
                return _GeneratorRequestCard(
                  request: request,
                  firestore: widget.firestore,
                );
              },
              childCount: requests.length * 2 - 1,
            ),
          ),
        );
      },
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
              Text('Generator dashboard', style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        IconButton(onPressed: onSignOut, icon: const Icon(Icons.logout)),
      ],
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

class _GeneratorRequestCard extends StatelessWidget {
  const _GeneratorRequestCard({required this.request, required this.firestore});

  final PickupRequest request;
  final FirestoreService firestore;

  @override
  Widget build(BuildContext context) {
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
          const SizedBox(height: 10),
          Text('${request.wasteType} waste', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
          if (request.directionsLandmarks != null) ...[
            const SizedBox(height: 6),
            Text(request.directionsLandmarks!),
          ],
          const SizedBox(height: 12),
          const _PaymentDisclaimer(),
          if (request.isClaimed && request.collectorId != null) ...[
            const SizedBox(height: 12),
            FutureBuilder<AppUser?>(
              future: firestore.getUser(request.collectorId!),
              builder: (context, snapshot) {
                final collector = snapshot.data;
                return FilledButton.icon(
                  onPressed: collector == null ? null : () => DialerService.openDialer(collector.phoneNumber),
                  icon: const Icon(Icons.call),
                  label: const Text('Call Collector'),
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF4ADE80), foregroundColor: const Color(0xFF064E3B)),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _TypeTag extends StatelessWidget {
  const _TypeTag({required this.type});

  final String type;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.25)),
      ),
      child: Text(type.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

class _GlassChoice extends StatelessWidget {
  const _GlassChoice({required this.label, required this.value, required this.groupValue, required this.onSelected});

  final String label;
  final String value;
  final String groupValue;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(value),
      selectedColor: const Color(0xFF4ADE80).withOpacity(0.35),
      backgroundColor: Colors.white.withOpacity(0.08),
      labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      side: BorderSide(color: Colors.white.withOpacity(0.25)),
    );
  }
}
