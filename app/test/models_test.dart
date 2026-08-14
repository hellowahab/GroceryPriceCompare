import 'package:flutter_test/flutter_test.dart';
import 'package:grocery_price_compare/src/models.dart';

void main() {
  test('Offer.fromJson parses full row', () {
    final o = Offer.fromJson({
      'offer_id': 42,
      'store_code': 'metro',
      'ext_product_id': 'p-7',
      'name': 'Safeguard Soap 90g',
      'brand': 'Safeguard',
      'ean': '8964000000000',
      'in_stock': 1,
      'price': 145.5,
      'base_price': 160.0,
      'discount_price': null,
      'collected_at': '2026-08-14',
    });
    expect(o.offerId, 42);
    expect(o.storeCode, 'metro');
    expect(o.name, 'Safeguard Soap 90g');
    expect(o.inStock, isTrue);
    expect(o.price, 145.5);
    expect(o.effectiveDiscount, 14.5);
  });

  test('Offer.fromJson treats false and 0 as out of stock', () {
    expect(Offer.fromJson({'in_stock': 0}).inStock, isFalse);
    expect(Offer.fromJson({'in_stock': false}).inStock, isFalse);
    expect(Offer.fromJson({}).inStock, isTrue);
  });

  test('Offer.effectiveDiscount null when no discount', () {
    final o = Offer.fromJson({'price': 100, 'base_price': 90});
    expect(o.effectiveDiscount, isNull);
  });

  test('Manifest.fromJson parses stores and files', () {
    final m = Manifest.fromJson({
      'schema_version': 1,
      'generated_at': '2026-08-14T00:00:00Z',
      'date': '2026-08-14',
      'stores': {
        'al_jadeed': {
          'offers': 17020,
          'with_price': 15000,
          'changed': 3,
          'new': 1,
          'file': 'products/al_jadeed.json',
        }
      },
      'files': {
        'index_sqlite_bytes': 13300000,
        'deltas_dir': 'deltas/2026-08-14/',
      },
    });
    expect(m.date, DateTime(2026, 8, 14));
    expect(m.stores['al_jadeed']!.offers, 17020);
    expect(m.indexSqliteBytes, 13300000);
    expect(m.deltasDir, 'deltas/2026-08-14/');
  });

  test('WatchItem.copyWith', () {
    final w = WatchItem(
        id: 1, itemName: 'milk', qty: 2, createdAt: '2026-01-01');
    final w2 = w.copyWith(targetPrice: 250, enabled: false);
    expect(w2.targetPrice, 250);
    expect(w2.enabled, isFalse);
    expect(w2.itemName, 'milk');
    expect(w.qty, 2);
  });
}
