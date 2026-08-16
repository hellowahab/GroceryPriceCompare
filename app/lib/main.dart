import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/local_db.dart';
import 'src/matching.dart';
import 'src/models.dart';
import 'src/state.dart';
import 'src/sync_service.dart';

const _baseUrl = 'https://hellowahab.github.io/GroceryPriceCompare';

String _fmt(double? v) =>
    v == null ? '—' : 'Rs ${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2)}';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = LocalDb();
  await db.open();
  final state = AppState(
    db: db,
    sync: SyncService(baseUrl: _baseUrl, db: db),
  );
  state.init();
  runApp(GroceryPriceCompareApp(state: state));
}

class GroceryPriceCompareApp extends StatelessWidget {
  final AppState state;
  const GroceryPriceCompareApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        title: 'Grocery Price Compare',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
          useMaterial3: true,
        ),
        home: const HomeShell(),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grocery Price Compare'),
        actions: [
          if (state.unreadAlerts > 0)
            IconButton(
              tooltip: 'Price drop alerts',
              icon: Badge(
                label: Text('${state.unreadAlerts}'),
                child: const Icon(Icons.notifications),
              ),
              onPressed: () => _showAlerts(context),
            ),
          IconButton(
            tooltip: 'Sync now',
            onPressed: state.syncing ? null : () => state.syncNow(),
            icon: state.syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              state.syncStatus,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ),
      body: switch (_index) {
        0 => const WatchlistScreen(),
        1 => const CompareScreen(),
        _ => const BrowseScreen(),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.list_alt), label: 'Watchlist'),
          NavigationDestination(icon: Icon(Icons.compare), label: 'Compare'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Browse'),
        ],
      ),
    );
  }

  void _showAlerts(BuildContext context) {
    final state = context.read<AppState>();
    showDialog<void>(
      context: context,
      builder: (_) => AlertsDialog(state: state),
    );
  }
}

class AlertsDialog extends StatefulWidget {
  final AppState state;
  const AlertsDialog({super.key, required this.state});

  @override
  State<AlertsDialog> createState() => _AlertsDialogState();
}

class _AlertsDialogState extends State<AlertsDialog> {
  late Future<List<Map<String, Object?>>> _alerts;

  @override
  void initState() {
    super.initState();
    _alerts = widget.state.db.unreadAlerts();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Price drops'),
      content: SizedBox(
        width: 400,
        child: FutureBuilder(
          future: _alerts,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final rows = snapshot.data ?? [];
            if (rows.isEmpty) return const Text('No price drops.');
            return ListView.builder(
              shrinkWrap: true,
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final r = rows[i];
                final oldP = (r['old_price'] as num?)?.toDouble();
                final newP = (r['new_price'] as num?)?.toDouble();
                return ListTile(
                  dense: true,
                  title: Text(r['offer_name'] as String? ?? 'offer'),
                  subtitle: Text('${r['item_name']} · ${r['created_at']}'),
                  trailing: Text(
                    '${_fmt(oldP)} → ${_fmt(newP)}',
                    style: TextStyle(
                        color: Colors.green.shade700,
                        fontWeight: FontWeight.bold),
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.state.markAlertsSeen();
            Navigator.of(context).pop();
          },
          child: const Text('Mark all seen'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class WatchlistScreen extends StatelessWidget {
  const WatchlistScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.watchlist.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No items on your watchlist yet.'),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => _addItem(context),
              icon: const Icon(Icons.add),
              label: const Text('Add item'),
            ),
          ],
        ),
      );
    }
    return FutureBuilder<List<(Offer, double?)>>(
      future: state.db.watchlistWithBestPrice(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final best = snapshot.data ?? [];
        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: state.watchlist.length,
          itemBuilder: (context, i) {
            final item = state.watchlist[i];
            final pair = best.isEmpty || i >= best.length
                ? null
                : best[i];
            final offer = pair?.$1;
            final price = pair?.$2;
            final target = item.targetPrice;
            return Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.shopping_cart)),
                title: Text(item.itemName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  [
                    'qty ${item.qty}',
                    if (offer != null)
                      'best: ${offer.name} @ ${storeName(offer.storeCode)}',
                  ].join('\n'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(_fmt(price),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    if (target != null)
                      Text('target ${_fmt(target)}',
                          style: TextStyle(
                              fontSize: 12,
                              color: price != null && price <= target
                                  ? Colors.green
                                  : Colors.grey)),
                  ],
                ),
                onTap: () => _editItem(context, item),
                onLongPress: () => state.removeWatchItem(item.id!),
              ),
            );
          },
        );
      },
    );
  }

  void _addItem(BuildContext context) => _editItem(context, null);
}

class _ItemEditor extends StatefulWidget {
  final WatchItem? item;
  const _ItemEditor({this.item});

  @override
  State<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<_ItemEditor> {
  late final TextEditingController _name =
      TextEditingController(text: widget.item?.itemName ?? '');
  late final TextEditingController _qty =
      TextEditingController(text: (widget.item?.qty ?? 1).toString());
  late final TextEditingController _target =
      TextEditingController(text: widget.item?.targetPrice?.toString() ?? '');

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return AlertDialog(
      title: Text(widget.item == null ? 'Add to watchlist' : 'Edit item'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Item name'),
          ),
          TextField(
            controller: _qty,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Quantity'),
          ),
          TextField(
            controller: _target,
            keyboardType: TextInputType.number,
            decoration:
                const InputDecoration(labelText: 'Target price (optional)'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            final qty = double.tryParse(_qty.text) ?? 1;
            final target = double.tryParse(_target.text);
            if (widget.item == null) {
              state.addWatchItem(name, qty: qty, targetPrice: target);
            } else {
              state.updateWatchItem(WatchItem(
                id: widget.item!.id,
                itemName: name,
                qty: qty,
                targetPrice: target,
                enabled: widget.item!.enabled,
                createdAt: widget.item!.createdAt,
              ));
            }
            Navigator.of(context).pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

void _editItem(BuildContext context, WatchItem? item) {
  showDialog<void>(
    context: context,
    builder: (_) => _ItemEditor(item: item),
  );
}

class CompareScreen extends StatefulWidget {
  const CompareScreen({super.key});

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  final _controller = TextEditingController();
  List<Offer> _results = [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'e.g. ketchup, milk, chakki atta',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _results = []);
                      }),
            ),
            onChanged: (v) {
              final q = v.trim();
              setState(() => _results = q.isEmpty ? [] : state.compare(q));
            },
          ),
        ),
        Expanded(
          child: _results.isEmpty
              ? const Center(child: Text('Type a product name to compare.'))
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (context, i) =>
                      _OfferTile(offer: _results[i], rank: i + 1),
                ),
        ),
      ],
    );
  }
}

class _OfferTile extends StatelessWidget {
  final Offer offer;
  final int? rank;
  const _OfferTile({required this.offer, this.rank});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: rank != null
          ? CircleAvatar(child: Text('$rank'))
          : const Icon(Icons.storefront),
      title: Text(offer.name),
      subtitle: Text(
        [
          storeName(offer.storeCode),
          if (offer.basePrice != null && offer.basePrice! > 0)
            'disc ${_fmt(offer.basePrice! - offer.price!)}',
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(_fmt(offer.price),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      onTap: () {
        final item = WatchItem(
          id: null,
          itemName: offer.name,
          qty: 1,
          targetPrice: offer.price,
          enabled: true,
          createdAt: DateTime.now().toIso8601String(),
        );
        showDialog<void>(
          context: context,
          builder: (_) => _ItemEditor(item: item),
        );
      },
    );
  }
}

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  final _controller = TextEditingController();
  String? _store;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final stores = state.manifest?.stores.values.toList() ?? [];
    final results = state.search(_controller.text, storeCode: _store);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _controller,
            decoration: const InputDecoration(
              hintText: 'Search any product',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (stores.isNotEmpty)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: _store == null,
                  onSelected: (_) => setState(() => _store = null),
                ),
                for (final s in stores)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoiceChip(
                      label: Text(s.code),
                      selected: _store == s.code,
                      onSelected: (_) =>
                          setState(() => _store = s.code),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: results.isEmpty
              ? const Center(child: Text('No products.'))
              : ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, i) => _OfferTile(offer: results[i]),
                ),
        ),
      ],
    );
  }
}
