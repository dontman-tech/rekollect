import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Offline-tolerant collector actions. Collectors work in low-connectivity
/// zones; a failed claim/message/confirm is queued locally and retried with
/// backoff when the network returns, instead of dying with an error.
class OutboxService {
  OutboxService(this._firestoreDispatch);

  static const _storageKey = 'rekollect_outbox_v1';

  /// Dispatches one queued action. Throws on failure so the item stays queued.
  final Future<void> Function(String kind, Map<String, dynamic> payload) _firestoreDispatch;

  final _items = <Map<String, dynamic>>[];
  Timer? _retryTimer;
  bool _draining = false;
  final _controller = StreamController<int>.broadcast();
  Stream<int> get stream => _controller.stream;
  int get pendingCount => _items.length;

  Future<void> load() async {
    if (_items.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      final decoded = jsonDecode(raw) as List<dynamic>;
      _items
        ..clear()
        ..addAll(decoded.cast<Map<String, dynamic>>());
    }
    _controller.add(_items.length);
    if (_items.isNotEmpty) _scheduleRetry();
  }

  /// Queue an action; also attempts an immediate dispatch (a failure just
  /// leaves it queued for the retry loop).
  Future<void> enqueue(String kind, Map<String, dynamic> payload) async {
    final item = {
      'kind': kind,
      'payload': payload,
      'queued_at': DateTime.now().toIso8601String(),
      'attempts': 0,
    };
    _items.add(item);
    await _persist();
    _drain();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_items));
    _controller.add(_items.length);
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 30), _drain);
  }

  Future<void> _drain() async {
    if (_draining || _items.isEmpty) return;
    _draining = true;
    try {
      for (final item in List.of(_items)) {
        try {
          await _firestoreDispatch(item['kind'] as String, Map<String, dynamic>.from(item['payload'] as Map));
          _items.remove(item);
          await _persist();
        } on SocketException {
          break; // offline — keep everything queued, retry later
        } catch (_) {
          item['attempts'] = (item['attempts'] as int) + 1;
          if ((item['attempts'] as int) >= 8) {
            _items.remove(item); // poison message — drop after 8 tries
            await _persist();
          }
        }
      }
    } finally {
      _draining = false;
      if (_items.isNotEmpty) _scheduleRetry();
    }
  }

  void dispose() => _retryTimer?.cancel();
}
