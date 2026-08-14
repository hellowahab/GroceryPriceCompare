import 'package:flutter_test/flutter_test.dart';
import 'package:grocery_price_compare/src/matching.dart';
import 'package:grocery_price_compare/src/models.dart';

Offer _offer(int id, String name, {double? price, String store = 'al_jadeed'}) {
  return Offer(
    offerId: id,
    storeCode: store,
    extProductId: '$id',
    name: name,
    price: price,
  );
}

void main() {
  test('storeName maps known codes', () {
    expect(storeName('al_jadeed'), 'Al Jadeed');
    expect(storeName('metro'), 'Metro');
    expect(storeName('unknown_store'), 'unknown_store');
  });

  test('nameTokens lowercases, tokenizes, sorts', () {
    final t = nameTokens('Chakki Atta 5kg');
    expect(t, containsAll(['chakki', 'atta', '5kg']));
    expect(t, isNot(contains('1')));
    final t2 = nameTokens('B');
    expect(t2, isEmpty);
  });

  test('jaccard identical vs disjoint', () {
    expect(jaccard(nameTokens('olper milk'), nameTokens('olper milk')), 1.0);
    expect(jaccard(nameTokens('olper milk'), nameTokens('chakki atta')), 0.0);
    expect(jaccard([], []), 0.0);
  });

  test('matchOffersByName finds best match by tokens', () {
    final offers = [
      _offer(1, 'Olper Milk 1L', price: 260),
      _offer(2, 'Nestle Milkpak 1L', price: 240),
      _offer(3, 'Olper Cream 200ml', price: 180),
    ];
    final matches = matchOffersByName('olper milk', offers);
    expect(matches.first.name, 'Olper Milk 1L');
    expect(matches.length, 1);
  });

  test('exact name match ranks first', () {
    final offers = [
      _offer(1, 'Lays Masala 50g', price: 60),
      _offer(2, 'Lays Masala 50g', price: 55, store: 'chase_up'),
    ];
    final matches = matchOffersByName('lays masala 50g', offers);
    expect(matches.length, 2);
    expect(matches.first.price, 55);
  });

  test('sortedByPrice puts cheapest first, nulls last', () {
    final sorted = sortedByPrice([
      _offer(1, 'a', price: null),
      _offer(2, 'b', price: 100),
      _offer(3, 'c', price: 50),
    ]);
    expect(sorted.map((o) => o.offerId).toList(), [3, 2, 1]);
  });
}
