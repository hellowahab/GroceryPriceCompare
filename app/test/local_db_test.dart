import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grocery_price_compare/src/local_db.dart';
import 'package:grocery_price_compare/src/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

LocalDb _freshDb() {
  final dir = Directory.systemTemp.createTempSync('gpc_test_');
  final path = '${dir.path}${Platform.pathSeparator}gpc_local.db';
  return LocalDb(pathOverride: path);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('watchlist add/update/delete round trip', () async {
    final db = _freshDb();
    await db.open();
    final id = await db.addWatchItem('Olper Milk 1L',
        qty: 2, targetPrice: 230);
    expect(id, isNonNegative);

    var items = await db.getWatchlist();
    expect(items.length, 1);
    expect(items.first.itemName, 'Olper Milk 1L');
    expect(items.first.qty, 2);
    expect(items.first.targetPrice, 230);

    await db.updateWatchItem(items.first.copyWith(qty: 3, targetPrice: 210));
    items = await db.getWatchlist();
    expect(items.first.qty, 3);
    expect(items.first.targetPrice, 210);

    await db.deleteWatchItem(items.first.id!);
    expect(await db.getWatchlist(), isEmpty);
  });

  test('replaceOffers seeds history only on first sync', () async {
    final db = _freshDb();
    await db.open();
    final offers = [
      Offer(
        offerId: 1,
        storeCode: 'al_jadeed',
        extProductId: 'p1',
        name: 'Olper Milk 1L',
        price: 260,
      ),
    ];
    await db.replaceOffers('al_jadeed', offers, historyDate: '2026-08-14');
    await db.replaceOffers('al_jadeed', offers);

    expect(await db.allOffers(), hasLength(1));
    final history = await db.priceHistory(1);
    expect(history, hasLength(1));
    expect(history.first['collected_at'], '2026-08-14');
  });

  test('applyDeltas updates price and reports drops', () async {
    final db = _freshDb();
    await db.open();
    await db.replaceOffers('al_jadeed', [
      Offer(
        offerId: 1,
        storeCode: 'al_jadeed',
        extProductId: 'p1',
        name: 'Olper Milk 1L',
        price: 260,
      ),
    ]);

    final drops = await db.applyDeltas('al_jadeed', [
      {
        'offer_id': 1,
        'old_price': 260,
        'new_price': 240,
        'in_stock': 1,
      }
    ], DateTime(2026, 8, 15));

    expect(drops, hasLength(1));
    expect(drops.first.oldPrice, 260);
    expect(drops.first.newPrice, 240);
    final offers = await db.allOffers();
    expect(offers.first.price, 240);
    final history = await db.priceHistory(1);
    expect(history.first['price'], 240);
  });

  test('recordDrops only alerts for matching watch item', () async {
    final db = _freshDb();
    await db.open();
    await db.addWatchItem('Olper Milk 1L');
    await db.addWatchItem('Chakki Atta 10kg');
    await db.replaceOffers('al_jadeed', [
      Offer(
        offerId: 1,
        storeCode: 'al_jadeed',
        extProductId: 'p1',
        name: 'Olper Milk 1L',
        price: 240,
      ),
    ]);

    await db.recordDrops([
      PriceDrop(offerId: 1, oldPrice: 260, newPrice: 240),
    ], DateTime(2026, 8, 15));

    expect(await db.unreadAlertCount(), 1);
    final alerts = await db.unreadAlerts();
    expect(alerts.first['item_name'], 'Olper Milk 1L');
    expect(alerts.first['offer_name'], 'Olper Milk 1L');

    await db.markAlertsSeen();
    expect(await db.unreadAlertCount(), 0);
  });

  test('watchlistWithBestPrice returns cheapest match', () async {
    final db = _freshDb();
    await db.open();
    await db.addWatchItem('Olper Milk 1L');
    await db.replaceOffers('al_jadeed', [
      Offer(
        offerId: 1,
        storeCode: 'al_jadeed',
        extProductId: 'p1',
        name: 'Olper Milk 1L',
        price: 260,
      ),
    ]);
    await db.replaceOffers('chase_up', [
      Offer(
        offerId: 2,
        storeCode: 'chase_up',
        extProductId: 'p2',
        name: 'Olper Milk 1L',
        price: 245,
      ),
    ]);

    final result = await db.watchlistWithBestPrice();
    expect(result, hasLength(1));
    expect(result.first.$2, 245);
  });
}

