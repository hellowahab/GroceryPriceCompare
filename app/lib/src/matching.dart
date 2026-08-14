import '../models.dart';

const Map<String, String> storeNames = {
  'al_jadeed': 'Al Jadeed',
  'bin_hashim': 'Bin Hashim',
  'chase_up': 'Chase Up',
  'metro': 'Metro',
};

String storeName(String code) => storeNames[code] ?? code;

List<String> nameTokens(String name) {
  final tokens = <String>{};
  final re = RegExp(r'[a-z0-9]+');
  for (final m in re.allMatches(name.toLowerCase())) {
    final t = m.group(0)!;
    if (t.length >= 2) tokens.add(t);
  }
  final list = tokens.toList()..sort();
  return list;
}

double jaccard(List<String> a, List<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final as = a.toSet();
  final bs = b.toSet();
  final inter = as.intersection(bs).length;
  final union = as.union(bs).length;
  return union == 0 ? 0 : inter / union;
}

List<Offer> matchOffersByName(String query, List<Offer> all,
    {double threshold = 0.45}) {
  final qt = nameTokens(query);
  if (qt.isEmpty) return const [];
  final scored = <({double score, Offer offer})>[];
  for (final offer in all) {
    final ot = nameTokens(offer.name);
    if (ot.isEmpty) continue;
    var s = jaccard(qt, ot);
    final exact = offer.name.toLowerCase() == query.toLowerCase();
    final containsAll = qt.every(ot.contains);
    if (exact) s = 1.0;
    else if (containsAll) s = s * 1.25;
    if (s >= threshold) scored.add((score: s, offer: offer));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  return scored.map((e) => e.offer).toList();
}

List<Offer> sortedByPrice(List<Offer> offers) {
  final list = List<Offer>.from(offers);
  list.sort((a, b) {
    final ap = a.price;
    final bp = b.price;
    if (ap == null && bp == null) return 0;
    if (ap == null) return 1;
    if (bp == null) return -1;
    return ap.compareTo(bp);
  });
  return list;
}
