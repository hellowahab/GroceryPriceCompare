import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grocery_price_compare/src/local_db.dart';
import 'package:grocery_price_compare/src/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _manifest = {
  'schema_version': 1,
  'generated_at': '2026-08-16T00:00:00Z',
  'date': '2026-08-16',
  'stores': {
    'al_jadeed': {
      'offers': 1,
      'with_price': 1,
      'changed': 0,
      'new': 0,
      'file': 'products/al_jadeed.json',
    }
  },
  'files': {
    'index_sqlite_bytes': 10,
    'deltas_dir': 'deltas/2026-08-16/',
  },
};

const _product = {
  'offer_id': 1,
  'store_code': 'al_jadeed',
  'ext_product_id': 'p1',
  'name': 'Olper Milk 1L',
  'in_stock': 1,
  'price': 240,
  'base_price': 260,
  'discount_price': null,
};

final _handlers = <String, Object>{
  '/manifest.json': _manifest,
  '/products/al_jadeed.json': [_product],
  '/deltas/2026-08-15/al_jadeed.json': [
    {'offer_id': 1, 'old_price': 260, 'new_price': 250, 'in_stock': 1},
  ],
  '/deltas/2026-08-16/al_jadeed.json': [
    {'offer_id': 1, 'old_price': 250, 'new_price': 240, 'in_stock': 1},
  ],
};

LocalDb _freshDb() {
  final dir = Directory.systemTemp.createTempSync('gpc_sync_');
  return LocalDb(
      pathOverride: '${dir.path}${Platform.pathSeparator}gpc_local.db');
}

SyncService _svc(LocalDb db) {
  final client = MockClient((req) async {
    final body = _handlers[req.url.path];
    if (body == null) return http.Response('not found', 404);
    return http.Response(
        jsonEncode(body), 200, headers: {'content-type': 'application/json'});
  });
  return SyncService(baseUrl: 'https://example.com', db: db, client: client);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('first sync seeds history from products', () async {
    final db = _freshDb();
    await db.open();
    final result = await _svc(db).syncAll();

    expect(result.firstSync, isTrue);
    expect(result.offersAdded, 1);
    expect(await db.getMeta('last_synced_date'), '2026-08-16');

    final history = await db.priceHistory(1);
    expect(history, hasLength(1));
    expect(history.first['collected_at'], '2026-08-16');
    expect(await db.allOffers(), hasLength(1));
  });

  test('subsequent sync applies deltas and records drops', () async {
    final db = _freshDb();
    await db.open();
    await db.addWatchItem('Olper Milk 1L');
    await db.setMeta('last_synced_date', '2026-08-14');

    final result = await _svc(db).syncAll();

    expect(result.firstSync, isFalse);
    expect(result.priceChanges, 2);
    expect(await db.getMeta('last_synced_date'), '2026-08-16');

    final offers = await db.allOffers();
    expect(offers.first.price, 240);

    final history = await db.priceHistory(1);
    expect(history, hasLength(2));

    expect(await db.unreadAlertCount(), 2);
    final alerts = await db.unreadAlerts();
    expect(alerts.first['old_price'], 250);
    expect(alerts.first['new_price'], 240);
  });

  test('missing delta day is tolerated', () async {
    final db = _freshDb();
    await db.open();
    await db.setMeta('last_synced_date', '2026-08-16');
    final result = await _svc(db).syncAll();
    expect(result.firstSync, isFalse);
    expect(await db.getMeta('last_synced_date'), '2026-08-16');
  });
}
