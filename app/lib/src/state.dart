import 'package:flutter/foundation.dart';

import 'local_db.dart';
import 'matching.dart';
import 'models.dart';
import 'sync_service.dart';

class AppState extends ChangeNotifier {
  final LocalDb db;
  final SyncService sync;

  List<WatchItem> watchlist = [];
  List<Offer> offers = [];
  Manifest? manifest;
  String syncStatus = 'not synced yet';
  bool syncing = false;
  String? error;
  SyncResult? lastSync;
  int unreadAlerts = 0;

  AppState({required this.db, required this.sync});

  Future<void> init() async {
    await loadLocal();
    notifyListeners();
    await syncNow();
  }

  Future<void> loadLocal() async {
    watchlist = await db.getWatchlist();
    offers = await db.allOffers();
    unreadAlerts = await db.unreadAlertCount();
    final last = await db.getMeta('last_synced_date');
    if (last != null && !syncing) {
      syncStatus = 'last sync: $last';
    }
  }

  Future<void> syncNow() async {
    if (syncing) return;
    syncing = true;
    error = null;
    syncStatus = 'syncing…';
    notifyListeners();
    try {
      lastSync = await sync.syncAll();
      manifest = lastSync!.manifest;
      syncStatus = 'synced ${manifest!.date.toIso8601String().substring(0, 10)}';
      await loadLocal();
    } catch (e) {
      error = e.toString();
      syncStatus = 'sync failed — offline data still works';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> addWatchItem(String itemName,
      {double qty = 1, double? targetPrice}) async {
    await db.addWatchItem(itemName, qty: qty, targetPrice: targetPrice);
    await loadLocal();
    notifyListeners();
  }

  Future<void> updateWatchItem(WatchItem item) async {
    await db.updateWatchItem(item);
    await loadLocal();
    notifyListeners();
  }

  Future<void> removeWatchItem(int id) async {
    await db.deleteWatchItem(id);
    await loadLocal();
    notifyListeners();
  }

  Future<void> markAlertsSeen() async {
    await db.markAlertsSeen();
    unreadAlerts = 0;
    notifyListeners();
  }

  List<Offer> compare(String query) =>
      sortedByPrice(matchOffersByName(query, offers));

  List<Offer> search(String query, {String? storeCode}) {
    final q = query.trim().toLowerCase();
    final list = offers.where((o) {
      final inStore = storeCode == null || o.storeCode == storeCode;
      return inStore && (q.isEmpty || o.name.toLowerCase().contains(q));
    }).toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }
}
