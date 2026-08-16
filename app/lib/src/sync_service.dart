import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_db.dart';
import 'models.dart';

class SyncService {
  final String baseUrl;
  final LocalDb db;
  final http.Client _client;

  SyncService({required this.baseUrl, required this.db, http.Client? client})
      : _client = client ?? http.Client();

  Uri _url(String path) => Uri.parse('$baseUrl/$path');

  Future<Manifest> fetchManifest() async {
    final res = await _client.get(_url('manifest.json'));
    if (res.statusCode != 200) {
      throw Exception('manifest: HTTP ${res.statusCode}');
    }
    return Manifest.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<Offer>> fetchProducts(String storeCode) async {
    final res = await _client.get(_url('products/$storeCode.json'));
    if (res.statusCode != 200) {
      throw Exception('products/$storeCode: HTTP ${res.statusCode}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => Offer.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Map<String, dynamic>>?> fetchDeltas(String storeCode,
      DateTime date) async {
    final d = date.toIso8601String().substring(0, 10);
    final res = await _client.get(_url('deltas/$d/$storeCode.json'));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw Exception('deltas/$d/$storeCode: HTTP ${res.statusCode}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  Future<SyncResult> syncAll() async {
    final manifest = await fetchManifest();
    final lastSynced = await db.getMeta('last_synced_date');
    final firstSync = lastSynced == null;

    var added = 0;
    var changed = 0;

    for (final store in manifest.stores.values) {
      final offers = await fetchProducts(store.code);
      added += offers.length;
      await db.replaceOffers(store.code, offers,
          historyDate: firstSync ? manifest.date.toIso8601String().substring(0, 10) : null);

      if (!firstSync) {
        final since = DateTime.tryParse(lastSynced) ?? manifest.date;
        var day = since.add(const Duration(days: 1));
        while (!day.isAfter(manifest.date)) {
          final deltas = await fetchDeltas(store.code, day);
          if (deltas != null && deltas.isNotEmpty) {
            changed += deltas.length;
            final drops = await db.applyDeltas(store.code, deltas, day);
            if (drops.isNotEmpty) {
              await db.recordDrops(drops, day);
            }
          }
          day = day.add(const Duration(days: 1));
        }
      }
    }

    final today = manifest.date.toIso8601String().substring(0, 10);
    await db.setMeta('last_synced_date', today);
    return SyncResult(
      manifest: manifest,
      offersAdded: added,
      priceChanges: changed,
      firstSync: firstSync,
    );
  }

  Future<Manifest?> peekManifest() async {
    try {
      return await fetchManifest();
    } catch (_) {
      return null;
    }
  }
}

class SyncResult {
  final Manifest manifest;
  final int offersAdded;
  final int priceChanges;
  final bool firstSync;

  SyncResult({
    required this.manifest,
    required this.offersAdded,
    required this.priceChanges,
    required this.firstSync,
  });
}
