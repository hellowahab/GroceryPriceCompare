class ManifestStoreInfo {
  final String code;
  final int offers;
  final int withPrice;
  final int changed;
  final int newOffers;
  final String file;

  ManifestStoreInfo({
    required this.code,
    required this.offers,
    required this.withPrice,
    required this.changed,
    required this.newOffers,
    required this.file,
  });

  factory ManifestStoreInfo.fromJson(String code, Map<String, dynamic> j) {
    return ManifestStoreInfo(
      code: code,
      offers: (j['offers'] as num?)?.toInt() ?? 0,
      withPrice: (j['with_price'] as num?)?.toInt() ?? 0,
      changed: (j['changed'] as num?)?.toInt() ?? 0,
      newOffers: (j['new'] as num?)?.toInt() ?? 0,
      file: j['file'] as String? ?? '',
    );
  }
}

class Manifest {
  final int schemaVersion;
  final String generatedAt;
  final DateTime date;
  final Map<String, ManifestStoreInfo> stores;
  final int indexSqliteBytes;
  final String deltasDir;

  Manifest({
    required this.schemaVersion,
    required this.generatedAt,
    required this.date,
    required this.stores,
    required this.indexSqliteBytes,
    required this.deltasDir,
  });

  factory Manifest.fromJson(Map<String, dynamic> j) {
    final stores = <String, ManifestStoreInfo>{};
    final raw = j['stores'] as Map<String, dynamic>? ?? {};
    raw.forEach((code, v) {
      stores[code] = ManifestStoreInfo.fromJson(code, v as Map<String, dynamic>);
    });
    final files = j['files'] as Map<String, dynamic>? ?? {};
    return Manifest(
      schemaVersion: (j['schema_version'] as num?)?.toInt() ?? 0,
      generatedAt: j['generated_at'] as String? ?? '',
      date: DateTime.tryParse(j['date'] as String? ?? '') ?? DateTime(1970),
      stores: stores,
      indexSqliteBytes: (files['index_sqlite_bytes'] as num?)?.toInt() ?? 0,
      deltasDir: files['deltas_dir'] as String? ?? '',
    );
  }
}

class Offer {
  final int offerId;
  final String storeCode;
  final String extProductId;
  final String name;
  final String? brand;
  final String? ean;
  final String? slug;
  final String? url;
  final bool inStock;
  final double? price;
  final double? basePrice;
  final double? discountPrice;
  final String? collectedAt;

  Offer({
    required this.offerId,
    required this.storeCode,
    required this.extProductId,
    required this.name,
    this.brand,
    this.ean,
    this.slug,
    this.url,
    this.inStock = true,
    this.price,
    this.basePrice,
    this.discountPrice,
    this.collectedAt,
  });

  factory Offer.fromJson(Map<String, dynamic> j) {
    return Offer(
      offerId: (j['offer_id'] as num?)?.toInt() ?? 0,
      storeCode: j['store_code'] as String? ?? '',
      extProductId: j['ext_product_id']?.toString() ?? '',
      name: j['name'] as String? ?? '',
      brand: j['brand'] as String?,
      ean: j['ean'] as String?,
      slug: j['slug'] as String?,
      url: j['url'] as String?,
      inStock: j['in_stock'] == 1 || j['in_stock'] == true,
      price: (j['price'] as num?)?.toDouble(),
      basePrice: (j['base_price'] as num?)?.toDouble(),
      discountPrice: (j['discount_price'] as num?)?.toDouble(),
      collectedAt: j['collected_at'] as String?,
    );
  }

  double? get effectiveDiscount =>
      (basePrice != null && price != null && basePrice! > price!)
          ? basePrice! - price!
          : null;
}

class PriceDrop {
  final int offerId;
  final double? oldPrice;
  final double? newPrice;

  PriceDrop({required this.offerId, this.oldPrice, this.newPrice});
}

class WatchItem {
  final int? id;
  final String itemName;
  final double qty;
  final double? targetPrice;
  final bool enabled;
  final String createdAt;

  WatchItem({
    this.id,
    required this.itemName,
    this.qty = 1,
    this.targetPrice,
    this.enabled = true,
    required this.createdAt,
  });

  WatchItem copyWith({double? qty, double? targetPrice, bool? enabled}) {
    return WatchItem(
      id: id,
      itemName: itemName,
      qty: qty ?? this.qty,
      targetPrice: targetPrice ?? this.targetPrice,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
    );
  }
}
