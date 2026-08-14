import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'matching.dart';
import 'models.dart';

class LocalDb {
  static const _dbName = 'gpc_local.db';
  static const _version = 1;
  final String? pathOverride;
  Database? _db;

  LocalDb({this.pathOverride});

  Future<Database> get db async => _db ??= await _open();

  Future<void> open() async {
    await db;
  }

  Future<Database> _open() async {
    final path = pathOverride ??
        p.join(await getDatabasesPath(), _dbName);
    return openDatabase(path, version: _version,
        onCreate: (db, _) async {
      await db.execute('''
        CREATE TABLE offers(
          id INTEGER PRIMARY KEY,
          store_code TEXT NOT NULL,
          ext_product_id TEXT NOT NULL,
          name TEXT NOT NULL,
          brand TEXT,
          ean TEXT,
          url TEXT,
          in_stock INTEGER NOT NULL DEFAULT 1,
          price REAL,
          base_price REAL,
          discount_price REAL,
          collected_at TEXT,
          UNIQUE(store_code, ext_product_id)
        )''');
      await db.execute('''
        CREATE TABLE price_history(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          offer_id INTEGER NOT NULL,
          price REAL,
          base_price REAL,
          discount_price REAL,
          collected_at TEXT NOT NULL
        )''');
      await db.execute('''
        CREATE INDEX idx_history_offer ON price_history(offer_id, id)''');
      await db.execute('''
        CREATE TABLE watchlist(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          item_name TEXT NOT NULL,
          qty REAL NOT NULL DEFAULT 1,
          target_price REAL,
          enabled INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL
        )''');
      await db.execute('''
        CREATE TABLE alerts(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          offer_id INTEGER NOT NULL,
          watch_id INTEGER,
          old_price REAL,
          new_price REAL,
          seen INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )''');
      await db.execute('''
        CREATE TABLE meta(
          key TEXT PRIMARY KEY,
          value TEXT
        )''');
    });
  }

  Future<String?> getMeta(String key) async {
    final rows = await (await db).query('meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) async {
    await (await db).insert('meta', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> replaceOffers(String storeCode, List<Offer> offers,
      {String? historyDate}) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete('offers', where: 'store_code = ?', whereArgs: [storeCode]);
      final existing = <String>{};
      if (historyDate != null) {
        final rows = await txn.query('price_history',
            columns: ['offer_id'], where: 'collected_at = ?',
            whereArgs: [historyDate]);
        for (final r in rows) {
          existing.add(r['offer_id'].toString());
        }
      }
      for (final o in offers) {
        await txn.insert('offers', {
          'id': o.offerId,
          'store_code': o.storeCode,
          'ext_product_id': o.extProductId,
          'name': o.name,
          'brand': o.brand,
          'ean': o.ean,
          'url': o.url,
          'in_stock': o.inStock ? 1 : 0,
          'price': o.price,
          'base_price': o.basePrice,
          'discount_price': o.discountPrice,
          'collected_at': o.collectedAt,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        if (historyDate != null && !existing.contains(o.offerId.toString())) {
          await txn.insert('price_history', {
            'offer_id': o.offerId,
            'price': o.price,
            'base_price': o.basePrice,
            'discount_price': o.discountPrice,
            'collected_at': historyDate,
          });
        }
      }
    });
  }

  Future<List<PriceDrop>> applyDeltas(String storeCode,
      List<Map<String, dynamic>> deltas, DateTime date) async {
    final dateStr = date.toIso8601String().substring(0, 10);
    final drops = <PriceDrop>[];
    final d = await db;
    await d.transaction((txn) async {
      for (final delta in deltas) {
        final offerId = (delta['offer_id'] as num?)?.toInt();
        final oldPrice = (delta['old_price'] as num?)?.toDouble();
        final newPrice = (delta['new_price'] as num?)?.toDouble();
        final inStock = delta['in_stock'];
        if (offerId == null) continue;
        if (inStock is num) {
          await txn.update('offers', {'in_stock': inStock == 0 ? 0 : 1},
              where: 'id = ?', whereArgs: [offerId]);
        }
        if (newPrice != null) {
          await txn.update('offers', {'price': newPrice},
              where: 'id = ?', whereArgs: [offerId]);
        }
        await txn.insert('price_history', {
          'offer_id': offerId,
          'price': newPrice,
          'collected_at': dateStr,
        });
        if (oldPrice != null &&
            newPrice != null &&
            oldPrice > newPrice &&
            oldPrice != newPrice) {
          drops.add(PriceDrop(
              offerId: offerId, oldPrice: oldPrice, newPrice: newPrice));
        }
      }
    });
    return drops;
  }

  Future<void> recordDrops(List<PriceDrop> drops, DateTime date) async {
    if (drops.isEmpty) return;
    final offers = await allOffers();
    final watchlist = await getWatchlist();
    final tokenizedOffers = <(List<String>, Offer)>[
      for (final o in offers) (nameTokens(o.name), o),
    ];
    final dropsByOffer = <int, PriceDrop>{
      for (final d in drops) d.offerId: d,
    };
    final dateStr = date.toIso8601String().substring(0, 10);
    final d = await db;
    await d.transaction((txn) async {
      for (final item in watchlist.where((w) => w.enabled)) {
        final qt = nameTokens(item.itemName);
        double best = 0;
        Offer? bestOffer;
        for (final (ot, o) in tokenizedOffers) {
          final s = _jaccard(qt, ot);
          if (s > best) {
            best = s;
            bestOffer = o;
          }
        }
        if (bestOffer == null || best < 0.5) continue;
        final drop = dropsByOffer[bestOffer.offerId];
        if (drop == null) continue;
        final existing = await txn.query('alerts',
            columns: ['id'],
            where: 'offer_id = ? AND watch_id = ? AND created_at = ?',
            whereArgs: [drop.offerId, item.id, dateStr]);
        if (existing.isEmpty) {
          await txn.insert('alerts', {
            'offer_id': drop.offerId,
            'watch_id': item.id,
            'old_price': drop.oldPrice,
            'new_price': drop.newPrice,
            'seen': 0,
            'created_at': dateStr,
          });
        }
      }
    });
  }

  Future<int> unreadAlertCount() async {
    final rows = await (await db).rawQuery(
        'SELECT COUNT(*) AS n FROM alerts WHERE seen = 0');
    return rows.first['n'] as int? ?? 0;
  }

  Future<List<Map<String, Object?>>> unreadAlerts() async {
    return (await db).rawQuery('''
      SELECT a.id, a.offer_id, a.watch_id, a.old_price, a.new_price,
             a.created_at, w.item_name, o.name AS offer_name, o.store_code
      FROM alerts a
      LEFT JOIN watchlist w ON w.id = a.watch_id
      LEFT JOIN offers o ON o.id = a.offer_id
      WHERE a.seen = 0
      ORDER BY a.created_at DESC
    ''');
  }

  Future<void> markAlertsSeen() async {
    await (await db).update('alerts', {'seen': 1});
  }

  Future<List<Offer>> allOffers() async {
    final rows = await (await db).query('offers', orderBy: 'name COLLATE NOCASE');
    return rows.map(_offerFromRow).toList();
  }

  Future<List<Offer>> searchOffers(String query, {String? storeCode}) async {
    final d = await db;
    final where = StringBuffer('name LIKE ?');
    final args = <Object?>['%$query%'];
    if (storeCode != null) {
      where.write(' AND store_code = ?');
      args.add(storeCode);
    }
    final rows = await d.query('offers',
        where: where.toString(), whereArgs: args,
        orderBy: 'name COLLATE NOCASE', limit: 200);
    return rows.map(_offerFromRow).toList();
  }

  Offer _offerFromRow(Map<String, Object?> r) {
    return Offer(
      offerId: r['id'] as int,
      storeCode: r['store_code'] as String,
      extProductId: r['ext_product_id'] as String,
      name: r['name'] as String,
      brand: r['brand'] as String?,
      ean: r['ean'] as String?,
      url: r['url'] as String?,
      inStock: (r['in_stock'] as int) == 1,
      price: (r['price'] as num?)?.toDouble(),
      basePrice: (r['base_price'] as num?)?.toDouble(),
      discountPrice: (r['discount_price'] as num?)?.toDouble(),
      collectedAt: r['collected_at'] as String?,
    );
  }

  Future<List<(Offer, double?)>> watchlistWithBestPrice() async {
    final offers = await allOffers();
    final tokenized = <(List<String>, Offer)>[
      for (final o in offers) (nameTokens(o.name), o),
    ];
    final items = await getWatchlist();
    final result = <(Offer, double?)>[];
    for (final item in items) {
      final qt = nameTokens(item.itemName);
      final scored = <(double, Offer)>[];
      for (final (ot, o) in tokenized) {
        scored.add((_jaccard(qt, ot), o));
      }
      scored.sort((a, b) => b.$1.compareTo(a.$1));
      final matches = scored.where((e) => e.$1 >= 0.45).map((e) => e.$2).toList();
      double? best;
      for (final o in matches) {
        if (o.price != null && (best == null || o.price! < best)) best = o.price!;
      }
      if (matches.isNotEmpty) {
        result.add((matches.first, best));
      }
    }
    return result;
  }

  double _jaccard(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final as = a.toSet();
    final bs = b.toSet();
    final inter = as.intersection(bs).length;
    final union = as.union(bs).length;
    return union == 0 ? 0 : inter / union;
  }

  Future<List<WatchItem>> getWatchlist() async {
    final rows = await (await db)
        .query('watchlist', orderBy: 'created_at DESC');
    return rows.map((r) => WatchItem(
      id: r['id'] as int,
      itemName: r['item_name'] as String,
      qty: (r['qty'] as num?)?.toDouble() ?? 1,
      targetPrice: (r['target_price'] as num?)?.toDouble(),
      enabled: (r['enabled'] as int) == 1,
      createdAt: r['created_at'] as String,
    )).toList();
  }

  Future<int> addWatchItem(String itemName, {double qty = 1, double? targetPrice}) async {
    return (await db).insert('watchlist', {
      'item_name': itemName,
      'qty': qty,
      'target_price': targetPrice,
      'enabled': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> updateWatchItem(WatchItem item) async {
    await (await db).update('watchlist', {
      'qty': item.qty,
      'target_price': item.targetPrice,
      'enabled': item.enabled ? 1 : 0,
    }, where: 'id = ?', whereArgs: [item.id]);
  }

  Future<void> deleteWatchItem(int id) async {
    await (await db).delete('watchlist', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, Object?>>> priceHistory(int offerId, {int limit = 30}) async {
    final rows = await (await db).query('price_history',
        where: 'offer_id = ?', whereArgs: [offerId],
        orderBy: 'id DESC', limit: limit);
    return rows;
  }
}
