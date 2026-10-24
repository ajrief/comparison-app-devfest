// NutriCompare — scan product barcodes and compare nutrition facts.
//
// How it works
// ------------
// A barcode (EAN-13 / UPC-A / ...) is only an ID number. It carries no
// nutrition data. The app reads the number with the camera, then looks the
// product up online in Open Food Facts (free, crowd-sourced database).
//
// Setup
// -----
//   flutter pub add http mobile_scanner
//   Android: add <uses-permission android:name="android.permission.INTERNET"/>
//            to android/app/src/main/AndroidManifest.xml (needed in release builds)
//   iOS:     add NSCameraUsageDescription to ios/Runner/Info.plist
//
// Reviews (THIS IS THE EDIT I MADE)
// -------
// Open Food Facts has no reviews, and there is no free, open review source.
// Reviews sit behind the `ReviewProvider` interface. The default provider
// returns nothing, and the Reviews tab says so. Plug in a licensed review
// API there if you have one.
//
// Design principle: the app NEVER scores or ranks products. It shows facts
// and differences, and the user decides.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

void main() => runApp(const NutriCompareApp());

// ─────────────────────────────────────────────────────────────────────────────
// App shell
// ─────────────────────────────────────────────────────────────────────────────

class NutriCompareApp extends StatelessWidget {
  const NutriCompareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NutriCompare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2E7D6B),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

enum Metric { calories, sugar, fat, sodium }

extension MetricInfo on Metric {
  String get label => switch (this) {
        Metric.calories => 'Calories',
        Metric.sugar => 'Sugar',
        Metric.fat => 'Fat',
        Metric.sodium => 'Sodium',
      };

  String get unit => switch (this) {
        Metric.calories => 'kcal',
        Metric.sugar => 'g',
        Metric.fat => 'g',
        Metric.sodium => 'mg',
      };

  IconData get icon => switch (this) {
        Metric.calories => Icons.local_fire_department_outlined,
        Metric.sugar => Icons.cookie_outlined,
        Metric.fat => Icons.opacity_outlined,
        Metric.sodium => Icons.grain,
      };

  /// General daily reference amounts (adult, 2,000 kcal diet). Shown only as
  /// context, never as a verdict.
  double get dailyReference => switch (this) {
        Metric.calories => 2000,
        Metric.sugar => 50,
        Metric.fat => 78,
        Metric.sodium => 2300,
      };
}

class Nutrition {
  /// Values per 100 g. Null = not available in the database.
  final double? calories, sugar, fat, sodium;
  final double? servingGrams;

  const Nutrition({
    this.calories,
    this.sugar,
    this.fat,
    this.sodium,
    this.servingGrams,
  });

  double? per100(Metric m) => switch (m) {
        Metric.calories => calories,
        Metric.sugar => sugar,
        Metric.fat => fat,
        Metric.sodium => sodium,
      };

  double? value(Metric m, {required bool perServing}) {
    final v = per100(m);
    if (v == null) return null;
    if (!perServing) return v;
    final s = servingGrams;
    return s == null ? null : v * s / 100;
  }
}

class Review {
  final int stars;
  final String title;
  final String body;
  final int helpful;
  final List<String> themes;

  const Review({
    required this.stars,
    required this.title,
    required this.body,
    required this.helpful,
    required this.themes,
  });
}

class Product {
  final String barcode, name, brand, category;
  final String? imageUrl, ingredients;
  final Nutrition nutrition;
  Color color = Colors.teal;
  double? avgRating;
  int? ratingCount;
  List<Review> reviews = [];

  Product({
    required this.barcode,
    required this.name,
    required this.brand,
    required this.category,
    required this.nutrition,
    this.imageUrl,
    this.ingredients,
  });

  String get id => barcode;
}

const _palette = [
  Color(0xFFE0A526),
  Color(0xFF3F6FD1),
  Color(0xFFD9692B),
  Color(0xFF6BAA75),
  Color(0xFF8D5A3B),
  Color(0xFF9B59B6),
];

// ─────────────────────────────────────────────────────────────────────────────
// Product lookup (Open Food Facts)
// ─────────────────────────────────────────────────────────────────────────────

class LookupException implements Exception {
  final String message;
  LookupException(this.message);
  @override
  String toString() => message;
}

class OpenFoodFactsService {
  static const _fields =
      'code,product_name,brands,categories,image_front_small_url,ingredients_text,'
      'nutriments,serving_quantity';

  /// Returns null when the barcode is not in the database.
  Future<Product?> lookup(String barcode) async {
    final uri = Uri.https(
        'world.openfoodfacts.org', '/api/v2/product/$barcode.json', {'fields': _fields});
    final http.Response res;
    try {
      res = await http
          .get(uri, headers: {'User-Agent': 'NutriCompare/1.0 (flutter app)'})
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw LookupException('The lookup timed out. Check your connection.');
    } catch (_) {
      throw LookupException('Could not reach the product database. Are you online?');
    }
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw LookupException('Product database error (${res.statusCode}).');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (json['status'] != 1) return null;
    final p = json['product'] as Map<String, dynamic>;
    final n = (p['nutriments'] as Map<String, dynamic>?) ?? {};

    double? num_(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v');

    double? kcal = num_(n['energy-kcal_100g']);
    kcal ??= num_(n['energy_100g']) == null ? null : num_(n['energy_100g'])! / 4.184;

    // Sodium is reported in grams; fall back to salt (sodium = salt / 2.5).
    double? sodiumMg;
    final sodiumG = num_(n['sodium_100g']);
    final saltG = num_(n['salt_100g']);
    if (sodiumG != null) {
      sodiumMg = sodiumG * 1000;
    } else if (saltG != null) {
      sodiumMg = saltG * 400;
    }

    String clean(dynamic v) => (v as String?)?.trim() ?? '';
    final name = clean(p['product_name']);
    final cats = clean(p['categories']);

    return Product(
      barcode: barcode,
      name: name.isEmpty ? 'Unnamed product ($barcode)' : name,
      brand: clean(p['brands']).split(',').first.trim(),
      category: cats.isEmpty ? 'Food' : cats.split(',').last.trim(),
      imageUrl: p['image_front_small_url'] as String?,
      ingredients: clean(p['ingredients_text']).isEmpty ? null : clean(p['ingredients_text']),
      nutrition: Nutrition(
        calories: kcal,
        sugar: num_(n['sugars_100g']),
        fat: num_(n['fat_100g']),
        sodium: sodiumMg,
        servingGrams: num_(p['serving_quantity']),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reviews (plug in a licensed source here)
// ─────────────────────────────────────────────────────────────────────────────

abstract class ReviewProvider {
  Future<List<Review>> reviewsFor(Product p);
}

class NoReviewProvider implements ReviewProvider {
  @override
  Future<List<Review>> reviewsFor(Product p) async => const [];
}

class ThemeStat {
  final String theme;
  final int count;
  final double share;
  const ThemeStat(this.theme, this.count, this.share);
}

class ReviewAnalyzer {
  /// Critical = 3 stars or fewer.
  static List<Review> critical(Product p) =>
      p.reviews.where((r) => r.stars <= 3).toList();

  static List<Review> helpful(Product p, {String? theme}) {
    final list = critical(p)
        .where((r) => theme == null || r.themes.contains(theme))
        .toList()
      ..sort((a, b) => b.helpful.compareTo(a.helpful));
    return list;
  }

  static List<ThemeStat> themes(Product p) {
    final crit = critical(p);
    final counts = <String, int>{};
    for (final r in crit) {
      for (final t in r.themes) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    return counts.entries
        .map((e) => ThemeStat(e.key, e.value, e.value / crit.length))
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));
  }

  static double share(Product p, String theme) {
    final crit = critical(p);
    if (crit.isEmpty) return 0;
    return crit.where((r) => r.themes.contains(theme)).length / crit.length;
  }

  static List<String> allThemes(List<Product> ps) {
    final counts = <String, int>{};
    for (final p in ps) {
      for (final s in themes(p)) {
        counts[s.theme] = (counts[s.theme] ?? 0) + s.count;
      }
    }
    return counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  }

  static String summary(Product p) {
    final t = themes(p);
    final n = critical(p).length;
    if (t.isEmpty) return 'No recurring complaints found.';
    final base =
        'Among $n critical reviews, "${t.first.theme}" comes up most (${t.first.count}).';
    if (t.length > 1 && t[1].count > 1) {
      return '$base "${t[1].theme}" is also mentioned repeatedly (${t[1].count}).';
    }
    return base;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

String fmt(double? v) {
  if (v == null) return '–';
  if (v >= 100) return v.round().toString();
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

class Stars extends StatelessWidget {
  final int count;
  const Stars(this.count, {super.key});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 5; i++)
            Icon(i < count ? Icons.star : Icons.star_border,
                size: 16, color: Colors.amber.shade700),
        ],
      );
}

class ProductThumb extends StatelessWidget {
  final Product product;
  final double size;
  const ProductThumb(this.product, {super.key, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final url = product.imageUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: size,
        height: size,
        color: product.color.withValues(alpha: 0.2),
        child: url == null
            ? Icon(Icons.shopping_bag_outlined, color: product.color)
            : Image.network(url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Icon(Icons.shopping_bag_outlined, color: product.color)),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Barcode scanner screen
// ─────────────────────────────────────────────────────────────────────────────

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _controller = MobileScannerController(
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
    ],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final code = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (code == null || code.isEmpty) return;
    _done = true;
    Navigator.of(context).pop(code);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan a barcode'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            tooltip: 'Toggle torch',
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: Container(
              width: 280,
              height: 160,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 48,
            child: Text(
              'Line up the barcode inside the frame',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Home: scan / add products
// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _off = OpenFoodFactsService();
  final ReviewProvider _reviews = NoReviewProvider();
  final List<Product> _items = [];
  bool _busy = false;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (code != null) await _addBarcode(code);
  }

  Future<void> _enterManually() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter barcode'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. 5449000000996'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Look up')),
        ],
      ),
    );
    if (code != null && code.isNotEmpty) await _addBarcode(code);
  }

  Future<void> _addBarcode(String code) async {
    if (_items.any((p) => p.barcode == code)) {
      _toast('That product is already added.');
      return;
    }
    setState(() => _busy = true);
    try {
      final p = await _off.lookup(code);
      if (!mounted) return;
      if (p == null) {
        _toast('Barcode $code was not found in Open Food Facts.');
      } else {
        p.color = _palette[_items.length % _palette.length];
        try {
          p.reviews = await _reviews.reviewsFor(p);
        } catch (_) {
          // Reviews are optional; nutrition still works without them.
        }
        if (!mounted) return;
        setState(() => _items.add(p));
      }
    } on LookupException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remove(Product p) => setState(() => _items.remove(p));

  void _openCompare() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CompareScreen(products: List.of(_items)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canCompare = _items.length >= 2 && !_busy;
    return Scaffold(
      appBar: AppBar(
        title: const Text('NutriCompare', style: TextStyle(fontWeight: FontWeight.w700)),
        centerTitle: false,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: canCompare ? _openCompare : null,
        icon: const Icon(Icons.compare_arrows),
        label: Text(_items.length >= 2
            ? 'Compare ${_items.length} products'
            : 'Scan at least 2 products'),
        backgroundColor: canCompare ? cs.primary : cs.surfaceContainerHighest,
        foregroundColor: canCompare ? cs.onPrimary : cs.onSurfaceVariant,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          Text('Compare what you\'re about to buy',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Scan each product\'s barcode. We look up its nutrition facts and '
            'show them side by side — you decide.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan barcode'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _enterManually,
                  icon: const Icon(Icons.keyboard_outlined),
                  label: const Text('Type number'),
                ),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 14),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Looking up product…', style: TextStyle(fontWeight: FontWeight.w600)),
                    SizedBox(height: 10),
                    LinearProgressIndicator(),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Column(
                children: [
                  Icon(Icons.shopping_basket_outlined,
                      size: 56, color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
                  const SizedBox(height: 10),
                  Text('No products yet', style: TextStyle(color: cs.onSurfaceVariant)),
                ],
              ),
            )
          else ...[
            Text('Scanned products (${_items.length})',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final p in _items)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: ProductThumb(p),
                  title: Text(p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      [if (p.brand.isNotEmpty) p.brand, p.category, p.barcode].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Remove',
                    onPressed: () => _remove(p),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
          Text(
            'Nutrition data: Open Food Facts (crowd-sourced, may be incomplete or out of date).',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compare screen
// ─────────────────────────────────────────────────────────────────────────────

class CompareScreen extends StatefulWidget {
  final List<Product> products;
  const CompareScreen({super.key, required this.products});

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  final Set<String> _hidden = {};
  bool _perServing = false;
  String? _themeFilter;

  List<Product> get _visible =>
      widget.products.where((p) => !_hidden.contains(p.id)).toList();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Comparing ${widget.products.length} products'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.bar_chart), text: 'Nutrition'),
            Tab(icon: Icon(Icons.report_gmailerrorred_outlined), text: 'Critical reviews'),
          ]),
        ),
        body: TabBarView(children: [
          _buildNutritionTab(context),
          _buildReviewsTab(context),
        ]),
      ),
    );
  }

  Widget _buildNutritionTab(BuildContext context) {
    final visible = _visible;
    final missingServing = visible.any((p) => p.nutrition.servingGrams == null);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final p in widget.products)
              FilterChip(
                avatar: CircleAvatar(backgroundColor: p.color, radius: 6),
                label: Text(p.name, overflow: TextOverflow.ellipsis),
                selected: !_hidden.contains(p.id),
                selectedColor: p.color.withValues(alpha: 0.22),
                onSelected: (sel) => setState(() {
                  if (sel) {
                    _hidden.remove(p.id);
                  } else if (visible.length > 1) {
                    _hidden.add(p.id);
                  }
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Per 100 g')),
            ButtonSegment(value: true, label: Text('Per serving')),
          ],
          selected: {_perServing},
          onSelectionChanged: (s) => setState(() => _perServing = s.first),
        ),
        if (_perServing && missingServing)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Some products have no serving size in the database; they show "–" per serving.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 14),
        _GroupedOverview(products: visible, perServing: _perServing),
        const SizedBox(height: 12),
        for (final m in Metric.values)
          _MetricCard(metric: m, products: visible, perServing: _perServing),
        const SizedBox(height: 4),
        _SideBySideTable(products: visible, perServing: _perServing),
        const SizedBox(height: 12),
        _IngredientsCard(products: visible),
        const SizedBox(height: 12),
        const _NeutralityNote(),
      ],
    );
  }

  Widget _buildReviewsTab(BuildContext context) {
    final products = widget.products;
    final cs = Theme.of(context).colorScheme;
    final hasReviews = products.any((p) => p.reviews.isNotEmpty);

    if (!hasReviews) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.rate_review_outlined, color: cs.primary, size: 32),
                  const SizedBox(height: 10),
                  Text('No review source connected',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text(
                    'Open Food Facts covers nutrition, not customer reviews. '
                    'To show critical reviews, connect a licensed review source '
                    'through the ReviewProvider in the code.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _NeutralityNote(),
        ],
      );
    }

    final themes = ReviewAnalyzer.allThemes(products);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Recurring complaints across products',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          'Share of each product\'s critical reviews (3★ or lower) that mention the topic.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: _themeMatrix(products, themes.take(8).toList()),
          ),
        ),
        const SizedBox(height: 14),
        Text('Filter reviews by topic', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('All'),
                  selected: _themeFilter == null,
                  onSelected: (_) => setState(() => _themeFilter = null),
                ),
              ),
              for (final t in themes)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(t),
                    selected: _themeFilter == t,
                    onSelected: (sel) => setState(() => _themeFilter = sel ? t : null),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (final p in products) _ProductReviewCard(product: p, themeFilter: _themeFilter),
        const SizedBox(height: 4),
        const _NeutralityNote(),
      ],
    );
  }

  Widget _themeMatrix(List<Product> ps, List<String> themes) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const FixedColumnWidth(86),
        columnWidths: const {0: FixedColumnWidth(136)},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            const SizedBox(),
            for (final p in ps)
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(p.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall),
              ),
          ]),
          for (final t in themes)
            TableRow(children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                child: Text(t, style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              for (final p in ps)
                Builder(builder: (_) {
                  final s = ReviewAnalyzer.share(p, t);
                  return Container(
                    margin: const EdgeInsets.all(3),
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: s == 0
                          ? Colors.black.withValues(alpha: 0.03)
                          : p.color.withValues(alpha: 0.15 + s * 0.55),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(s == 0 ? '–' : '${(s * 100).round()}%',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  );
                }),
            ]),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Nutrition widgets
// ─────────────────────────────────────────────────────────────────────────────

double _maxOf(Iterable<double?> vs) => vs.whereType<double>().fold<double>(0, math.max);

class _GroupedOverview extends StatelessWidget {
  final List<Product> products;
  final bool perServing;
  const _GroupedOverview({required this.products, required this.perServing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Overview',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            Text('Columns are scaled within each nutrient.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [for (final m in Metric.values) Expanded(child: _group(context, m))],
            ),
          ],
        ),
      ),
    );
  }

  Widget _group(BuildContext context, Metric m) {
    final values = {
      for (final p in products) p.id: p.nutrition.value(m, perServing: perServing)
    };
    final maxV = _maxOf(values.values);
    final denom = maxV == 0 ? 1.0 : maxV;
    return Column(
      children: [
        SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final p in products)
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: (values[p.id] ?? 0) / denom),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (_, f, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(fmt(values[p.id]), style: const TextStyle(fontSize: 9)),
                      const SizedBox(height: 2),
                      Container(
                        width: 12,
                        height: math.max(3, 104 * f),
                        decoration: BoxDecoration(
                          color: values[p.id] == null
                              ? Colors.grey.withValues(alpha: 0.3)
                              : p.color,
                          borderRadius:
                              const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Icon(m.icon, size: 16),
        Text(m.label, style: Theme.of(context).textTheme.labelSmall),
        Text(m.unit,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.grey)),
      ],
    );
  }
}

class _MetricCard extends StatefulWidget {
  final Metric metric;
  final List<Product> products;
  final bool perServing;
  const _MetricCard(
      {required this.metric, required this.products, required this.perServing});

  @override
  State<_MetricCard> createState() => _MetricCardState();
}

class _MetricCardState extends State<_MetricCard> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final m = widget.metric;
    final cs = Theme.of(context).colorScheme;
    final values = {
      for (final p in widget.products)
        p.id: p.nutrition.value(m, perServing: widget.perServing)
    };
    final maxV = _maxOf(values.values);
    final denom = maxV == 0 ? 1.0 : maxV;
    final selected = widget.products.where((p) => p.id == _selected).toList();
    final selValue = selected.isEmpty ? null : values[selected.first.id];

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(m.icon, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Text(m.label,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(widget.perServing ? 'per serving' : 'per 100 g',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 10),
            for (final p in widget.products)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _selected = _selected == p.id ? null : p.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 104,
                        child: Text(p.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  _selected == p.id ? FontWeight.w700 : FontWeight.w500,
                            )),
                      ),
                      Expanded(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: (values[p.id] ?? 0) / denom),
                          duration: const Duration(milliseconds: 600),
                          curve: Curves.easeOutCubic,
                          builder: (_, f, _) => Stack(
                            alignment: Alignment.centerLeft,
                            children: [
                              Container(
                                height: 18,
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              if (values[p.id] != null)
                                FractionallySizedBox(
                                  widthFactor: f.clamp(0.02, 1.0),
                                  child: Container(
                                    height: 18,
                                    decoration: BoxDecoration(
                                      color: p.color,
                                      borderRadius: BorderRadius.circular(6),
                                      border: _selected == p.id
                                          ? Border.all(color: cs.onSurface, width: 1.5)
                                          : null,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 70,
                        child: Text(
                            values[p.id] == null ? 'n/a' : '${fmt(values[p.id])} ${m.unit}',
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: selected.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: selected.first.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        selValue == null
                            ? '${selected.first.name}: no ${m.label.toLowerCase()} data in the database.'
                            : '${selected.first.name}: ${fmt(selValue)} ${m.unit} '
                                '≈ ${(selValue / m.dailyReference * 100).round()}% of the '
                                '${fmt(m.dailyReference)} ${m.unit} general daily reference. '
                                'Individual needs vary.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SideBySideTable extends StatelessWidget {
  final List<Product> products;
  final bool perServing;
  const _SideBySideTable({required this.products, required this.perServing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Side by side',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                defaultColumnWidth: const FixedColumnWidth(94),
                columnWidths: const {0: FixedColumnWidth(92)},
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                border: TableBorder(
                  horizontalInside:
                      BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
                ),
                children: [
                  TableRow(children: [
                    const SizedBox(),
                    for (final p in products)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                        child: Text(p.name,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelSmall),
                      ),
                  ]),
                  for (final m in Metric.values)
                    TableRow(children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text('${m.label} (${m.unit})',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                      ),
                      for (final p in products)
                        Text(fmt(p.nutrition.value(m, perServing: perServing)),
                            textAlign: TextAlign.center),
                    ]),
                  TableRow(children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('Serving size',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    ),
                    for (final p in products)
                      Text(
                          p.nutrition.servingGrams == null
                              ? '–'
                              : '${fmt(p.nutrition.servingGrams)} g',
                          textAlign: TextAlign.center),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IngredientsCard extends StatelessWidget {
  final List<Product> products;
  const _IngredientsCard({required this.products});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ingredients',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final p in products)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      CircleAvatar(backgroundColor: p.color, radius: 5),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text(p.name,
                              style: const TextStyle(fontWeight: FontWeight.w600))),
                    ]),
                    const SizedBox(height: 2),
                    Text(p.ingredients ?? 'No ingredient list in the database.',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Review widgets
// ─────────────────────────────────────────────────────────────────────────────

class _ProductReviewCard extends StatelessWidget {
  final Product product;
  final String? themeFilter;
  const _ProductReviewCard({required this.product, required this.themeFilter});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stats = ReviewAnalyzer.themes(product);
    final reviews = ReviewAnalyzer.helpful(product, theme: themeFilter);
    final rating = product.avgRating == null
        ? ''
        : ' · ${product.avgRating}★ avg · ${product.ratingCount ?? 0} ratings';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ProductThumb(product, size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(product.name,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      Text('${product.brand}$rating',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (product.reviews.isEmpty)
              Text('No reviews available for this product.',
                  style: TextStyle(color: cs.onSurfaceVariant))
            else ...[
              Text(ReviewAnalyzer.summary(product)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: -4,
                children: [
                  for (final s in stats)
                    Chip(
                      label: Text('${s.theme} · ${s.count}'),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: themeFilter == s.theme
                          ? product.color.withValues(alpha: 0.35)
                          : product.color.withValues(alpha: 0.12),
                      side: BorderSide.none,
                    ),
                ],
              ),
              const Divider(height: 24),
              Text(
                themeFilter == null
                    ? 'Most helpful critical reviews'
                    : 'Most helpful reviews mentioning "$themeFilter"',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              if (reviews.isEmpty)
                Text('No critical reviews mention this topic.',
                    style: TextStyle(color: cs.onSurfaceVariant))
              else
                for (final r in reviews.take(3)) _ReviewTile(review: r, accent: product.color),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReviewTile extends StatelessWidget {
  final Review review;
  final Color accent;
  const _ReviewTile({required this.review, required this.accent});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: accent, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Stars(review.stars),
            const SizedBox(width: 8),
            Expanded(
              child: Text(review.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 4),
          Text(review.body),
          const SizedBox(height: 6),
          Text('👍 ${review.helpful} found this helpful',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _NeutralityNote extends StatelessWidget {
  const _NeutralityNote();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.balance, size: 20, color: cs.primary),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'No scores, no rankings. Which trade-offs matter depends on your needs — '
              'you decide what fits.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}