// NutriCompare — AI-powered nutrition & critical-review comparison (prototype)
//
// Runs with the plain Flutter SDK (no extra packages) so it works as a live
// demo immediately:  flutter create nutri_compare && replace lib/main.dart
//
// DEMO vs. PRODUCTION
// -------------------
// Everything that would hit the network sits behind `RecognitionService`
// (photo -> products) and the `Catalog` (product -> nutrition + reviews).
// The demo implementation simulates the pipeline against a built-in sample
// catalog (fictional brands) so the presentation is fast and reliable.
//
// To go live, swap in:
//   1. Photo capture:      `image_picker` (camera / gallery, multiple images)
//   2. Product detection:  a vision model call (e.g. Claude vision) that
//                          returns product names/brands + bounding boxes for
//                          every item in the photo; fall back to barcode scan
//   3. Nutrition data:     Open Food Facts API (free, barcode/name lookup)
//   4. Reviews:            retailer review APIs / licensed review data, then
//                          an LLM pass to tag themes and summarise complaints
//
// Design principle: the app NEVER scores or ranks products. It shows facts,
// differences and recurring concerns, and the user decides.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

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

  /// General daily reference amounts (adult, 2,000 kcal diet). Individual
  /// needs differ — shown only as context, never as a verdict.
  double get dailyReference => switch (this) {
        Metric.calories => 2000,
        Metric.sugar => 50,
        Metric.fat => 78,
        Metric.sodium => 2300,
      };
}

class Nutrition {
  /// Values per 100 g.
  final double calories, sugar, fat, sodium;
  final double servingGrams;

  const Nutrition({
    required this.calories,
    required this.sugar,
    required this.fat,
    required this.sodium,
    required this.servingGrams,
  });

  double per100(Metric m) => switch (m) {
        Metric.calories => calories,
        Metric.sugar => sugar,
        Metric.fat => fat,
        Metric.sodium => sodium,
      };

  double value(Metric m, {required bool perServing}) =>
      perServing ? per100(m) * servingGrams / 100 : per100(m);
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
  final String id, name, brand, category, emoji;
  final Color color;
  final Nutrition nutrition;
  final double avgRating;
  final int ratingCount;
  final List<Review> reviews;

  const Product({
    required this.id,
    required this.name,
    required this.brand,
    required this.category,
    required this.emoji,
    required this.color,
    required this.nutrition,
    required this.avgRating,
    required this.ratingCount,
    required this.reviews,
  });
}

class Detection {
  final Product product;
  final double confidence;

  /// Normalised bounding box (0..1) inside the source photo.
  final Rect box;

  const Detection(this.product, this.confidence, this.box);
}

// ─────────────────────────────────────────────────────────────────────────────
// Review analysis (theme counts, helpful-first ordering, cross-product matrix)
// ─────────────────────────────────────────────────────────────────────────────

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

  /// Most helpful critical reviews first, optionally filtered by theme.
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
    final stats = counts.entries
        .map((e) => ThemeStat(e.key, e.value, e.value / crit.length))
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return stats;
  }

  static double share(Product p, String theme) {
    final crit = critical(p);
    if (crit.isEmpty) return 0;
    return crit.where((r) => r.themes.contains(theme)).length / crit.length;
  }

  /// Themes across all products, most common overall first.
  static List<String> allThemes(List<Product> ps) {
    final counts = <String, int>{};
    for (final p in ps) {
      for (final s in themes(p)) {
        counts[s.theme] = (counts[s.theme] ?? 0) + s.count;
      }
    }
    final keys = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return keys;
  }

  static String summary(Product p) {
    final t = themes(p);
    final n = critical(p).length;
    if (t.isEmpty) return 'No recurring complaints found.';
    final first = t.first;
    final base =
        'Among $n critical reviews, "${first.theme}" comes up most (${first.count}).';
    if (t.length > 1 && t[1].count > 1) {
      return '$base "${t[1].theme}" is also mentioned repeatedly (${t[1].count}).';
    }
    return base;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Recognition service (demo implementation — swap for a real vision pipeline)
// ─────────────────────────────────────────────────────────────────────────────

abstract class RecognitionService {
  /// One photo containing several products.
  Future<List<Detection>> recognizeShelf({required void Function(String) onStage});

  /// One photo of a single product. Returns null if nothing new is available.
  Future<Detection?> recognizeSingle({
    required Set<String> exclude,
    required void Function(String) onStage,
  });
}

class DemoRecognitionService implements RecognitionService {
  int _shelfRun = 0;

  static const _shelves = [
    ['granola', 'spread', 'protein'],
    ['protein', 'chips', 'yogurt'],
    ['granola', 'chips', 'yogurt'],
  ];

  static const _boxes = [
    Rect.fromLTWH(0.05, 0.18, 0.26, 0.62),
    Rect.fromLTWH(0.37, 0.18, 0.26, 0.62),
    Rect.fromLTWH(0.69, 0.18, 0.26, 0.62),
  ];

  Future<void> _stages(List<String> stages, void Function(String) cb) async {
    for (final s in stages) {
      cb(s);
      await Future.delayed(const Duration(milliseconds: 650));
    }
  }

  @override
  Future<List<Detection>> recognizeShelf(
      {required void Function(String) onStage}) async {
    await _stages([
      'Analysing photo…',
      'Detecting products…',
      'Matching labels & barcodes…',
      'Fetching nutrition facts…',
      'Searching critical reviews…',
    ], onStage);
    final ids = _shelves[_shelfRun++ % _shelves.length];
    final rng = math.Random(_shelfRun);
    return [
      for (var i = 0; i < ids.length; i++)
        Detection(Catalog.byId(ids[i]), 0.90 + rng.nextDouble() * 0.08, _boxes[i]),
    ];
  }

  @override
  Future<Detection?> recognizeSingle({
    required Set<String> exclude,
    required void Function(String) onStage,
  }) async {
    await _stages([
      'Reading product photo…',
      'Matching product…',
      'Fetching nutrition & reviews…',
    ], onStage);
    final remaining =
        Catalog.all.where((p) => !exclude.contains(p.id)).toList();
    if (remaining.isEmpty) return null;
    return Detection(remaining.first, 0.95, const Rect.fromLTWH(0.2, 0.1, 0.6, 0.8));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sample catalog (fictional brands, illustrative data)
// ─────────────────────────────────────────────────────────────────────────────

class Catalog {
  static Product byId(String id) => all.firstWhere((p) => p.id == id);

  static final List<Product> all = [
    const Product(
      id: 'granola',
      name: 'Oat & Honey Bar',
      brand: 'Harvest Crumb',
      category: 'Snack bar',
      emoji: '🌾',
      color: Color(0xFFE0A526),
      nutrition: Nutrition(calories: 430, sugar: 24, fat: 14, sodium: 180, servingGrams: 40),
      avgRating: 4.1,
      ratingCount: 3820,
      reviews: [
        Review(stars: 2, title: 'Way sweeter than it looks', body: 'Tastes like candy, not oats. Could not finish a whole bar.', helpful: 142, themes: ['Too sweet']),
        Review(stars: 2, title: 'Smaller than it used to be', body: 'The bar seems noticeably smaller and the price went up.', helpful: 121, themes: ['Price', 'Smaller portions']),
        Review(stars: 3, title: 'Falls apart in my bag', body: 'Crumbles everywhere unless you eat it very carefully.', helpful: 87, themes: ['Texture', 'Packaging']),
        Review(stars: 1, title: 'Sticks to your teeth', body: 'Very sticky and sugary, not a good option before a meeting.', helpful: 64, themes: ['Texture', 'Too sweet']),
        Review(stars: 3, title: 'Not filling', body: 'I was hungry again within an hour.', helpful: 51, themes: ['Not filling']),
        Review(stars: 5, title: 'Great on hikes', body: 'Tasty and easy to carry.', helpful: 30, themes: []),
      ],
    ),
    const Product(
      id: 'spread',
      name: 'Cocoa Hazelnut Spread',
      brand: 'Velvet Nut Co.',
      category: 'Spread',
      emoji: '🍫',
      color: Color(0xFF8D5A3B),
      nutrition: Nutrition(calories: 540, sugar: 56, fat: 31, sodium: 40, servingGrams: 15),
      avgRating: 4.5,
      ratingCount: 9210,
      reviews: [
        Review(stars: 2, title: 'Mostly sugar', body: 'Sugar is the first ingredient. It is dessert, not breakfast.', helpful: 210, themes: ['Too sweet', 'Ingredient concerns']),
        Review(stars: 1, title: 'Oil separates', body: 'A layer of oil on top every time, and the bottom is hard.', helpful: 96, themes: ['Texture']),
        Review(stars: 3, title: 'Jar is half empty', body: 'Thick glass and a deep jar make it look like more than it is.', helpful: 73, themes: ['Packaging', 'Price']),
        Review(stars: 3, title: 'Expensive for the amount', body: 'Gets used up quickly and costs a lot per spoonful.', helpful: 66, themes: ['Price']),
        Review(stars: 2, title: 'Odd aftertaste', body: 'The flavour changed from the older recipe, a bit artificial now.', helpful: 58, themes: ['Artificial aftertaste']),
        Review(stars: 5, title: 'Love it', body: 'Perfect on toast.', helpful: 12, themes: []),
      ],
    ),
    const Product(
      id: 'protein',
      name: 'Protein Crunch Bar',
      brand: 'PeakFuel',
      category: 'Snack bar',
      emoji: '💪',
      color: Color(0xFF3F6FD1),
      nutrition: Nutrition(calories: 370, sugar: 6, fat: 12, sodium: 290, servingGrams: 60),
      avgRating: 3.9,
      ratingCount: 5470,
      reviews: [
        Review(stars: 2, title: 'Chalky and dry', body: 'Powdery texture, needs a lot of water to get it down.', helpful: 188, themes: ['Texture', 'Artificial aftertaste']),
        Review(stars: 2, title: 'Upset my stomach', body: 'Bloating after eating two. Probably the sugar alcohols.', helpful: 134, themes: ['Digestive issues']),
        Review(stars: 3, title: 'Sweetener aftertaste', body: 'Lingering artificial sweetness, plus a little gas.', helpful: 101, themes: ['Artificial aftertaste', 'Digestive issues']),
        Review(stars: 3, title: 'Very hard to chew', body: 'Gets rock hard in cold weather.', helpful: 92, themes: ['Texture']),
        Review(stars: 1, title: 'Pricey for a snack', body: 'The cost per bar adds up quickly.', helpful: 77, themes: ['Price']),
        Review(stars: 4, title: 'Good post-workout', body: 'Does what it says.', helpful: 25, themes: []),
      ],
    ),
    const Product(
      id: 'chips',
      name: 'Salted Kettle Chips',
      brand: 'Crisp & Co.',
      category: 'Chips',
      emoji: '🥔',
      color: Color(0xFFD9692B),
      nutrition: Nutrition(calories: 520, sugar: 1, fat: 33, sodium: 620, servingGrams: 28),
      avgRating: 4.3,
      ratingCount: 12040,
      reviews: [
        Review(stars: 2, title: 'Salt overload', body: 'Intensely salty, I was thirsty for hours.', helpful: 175, themes: ['Too salty']),
        Review(stars: 3, title: 'Bag is mostly air', body: 'Half-full bag for the price, and the chips are small.', helpful: 140, themes: ['Packaging', 'Price', 'Smaller portions']),
        Review(stars: 3, title: 'Mostly crumbs', body: 'The bottom third of the bag was dust.', helpful: 112, themes: ['Packaging', 'Texture']),
        Review(stars: 2, title: 'Greasy', body: 'Oil on my fingers and on the bag.', helpful: 90, themes: ['Greasy']),
        Review(stars: 2, title: 'Batches vary', body: 'Some bags are perfect, others taste stale.', helpful: 48, themes: ['Quality inconsistency']),
        Review(stars: 5, title: 'Super crunchy', body: 'Best kettle chips I have tried.', helpful: 40, themes: []),
      ],
    ),
    const Product(
      id: 'yogurt',
      name: 'Creamy Greek Yogurt',
      brand: 'Meadowlane',
      category: 'Dairy',
      emoji: '🥛',
      color: Color(0xFF6BAA75),
      nutrition: Nutrition(calories: 97, sugar: 4, fat: 5, sodium: 36, servingGrams: 150),
      avgRating: 4.2,
      ratingCount: 2760,
      reviews: [
        Review(stars: 3, title: 'Quite sour', body: 'More tangy than other brands, needs a sweetener.', helpful: 83, themes: ['Too sour']),
        Review(stars: 2, title: 'Watery', body: 'Liquid on top and thinner than expected for Greek yogurt.', helpful: 120, themes: ['Texture']),
        Review(stars: 2, title: 'Price per cup', body: 'More expensive than comparable tubs.', helpful: 69, themes: ['Price']),
        Review(stars: 3, title: 'Short shelf life', body: 'Expiry date arrives fast, one tub was off early.', helpful: 57, themes: ['Quality inconsistency']),
        Review(stars: 3, title: 'Tub cracks', body: 'The plastic lid cracked in two of four tubs.', helpful: 44, themes: ['Packaging']),
        Review(stars: 5, title: 'Creamy and mild', body: 'Great with fruit.', helpful: 19, themes: []),
      ],
    ),
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

String fmt(double v) {
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

// ─────────────────────────────────────────────────────────────────────────────
// Home: capture / recognise products
// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final RecognitionService _service = DemoRecognitionService();
  final List<Detection> _items = [];
  List<Detection> _shelf = [];
  bool _busy = false;
  String _stage = '';

  void _addIfNew(Detection d) {
    if (!_items.any((e) => e.product.id == d.product.id)) _items.add(d);
  }

  Future<void> _scanShelf() async {
    setState(() {
      _busy = true;
      _stage = 'Preparing photo…';
    });
    final result = await _service.recognizeShelf(onStage: (s) {
      if (mounted) setState(() => _stage = s);
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      _shelf = result;
      for (final d in result) {
        _addIfNew(d);
      }
    });
  }

  Future<void> _addSingle() async {
    setState(() {
      _busy = true;
      _stage = 'Preparing photo…';
    });
    final d = await _service.recognizeSingle(
      exclude: _items.map((e) => e.product.id).toSet(),
      onStage: (s) {
        if (mounted) setState(() => _stage = s);
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (d != null) _addIfNew(d);
    });
    if (d == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All demo products are already added.')),
      );
    }
  }

  void _remove(Detection d) => setState(() {
        _items.remove(d);
        _shelf = _shelf.where((e) => e.product.id != d.product.id).toList();
      });

  void _openCompare() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CompareScreen(products: _items.map((e) => e.product).toList()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('NutriCompare', style: TextStyle(fontWeight: FontWeight.w700)),
        centerTitle: false,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _items.length >= 2 && !_busy ? _openCompare : null,
        icon: const Icon(Icons.compare_arrows),
        label: Text(_items.length >= 2
            ? 'Compare ${_items.length} products'
            : 'Add at least 2 products'),
        backgroundColor: _items.length >= 2 ? cs.primary : cs.surfaceContainerHighest,
        foregroundColor: _items.length >= 2 ? cs.onPrimary : cs.onSurfaceVariant,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          Text('Compare what you\'re about to buy',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Photograph several products at once, or add them one by one. '
            'We show nutrition and what critical reviewers say — you decide.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _scanShelf,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Photo of several'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _addSingle,
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: const Text('Add one product'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _busy
                ? Card(
                    key: const ValueKey('busy'),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_stage, style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 10),
                          const LinearProgressIndicator(),
                        ],
                      ),
                    ),
                  )
                : _shelf.isNotEmpty
                    ? ShelfPreview(key: const ValueKey('shelf'), detections: _shelf)
                    : const SizedBox.shrink(key: ValueKey('none')),
          ),
          const SizedBox(height: 16),
          if (_items.isEmpty)
            _EmptyState(color: cs.onSurfaceVariant)
          else ...[
            Text('Recognised products (${_items.length})',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final d in _items)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: d.product.color.withValues(alpha: 0.2),
                    child: Text(d.product.emoji, style: const TextStyle(fontSize: 22)),
                  ),
                  title: Text(d.product.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      '${d.product.brand} · ${d.product.category} · ${(d.confidence * 100).round()}% match'),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Remove',
                    onPressed: () => _remove(d),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
          Text(
            'Demo mode: products, nutrition and reviews come from a built-in sample catalog.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final Color color;
  const _EmptyState({required this.color});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Column(
          children: [
            Icon(Icons.shopping_basket_outlined, size: 56, color: color.withValues(alpha: 0.6)),
            const SizedBox(height: 10),
            Text('No products yet', style: TextStyle(color: color)),
          ],
        ),
      );
}

/// Simulated "photo" with detection boxes drawn over each recognised product.
class ShelfPreview extends StatelessWidget {
  final List<Detection> detections;
  const ShelfPreview({super.key, required this.detections});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: LayoutBuilder(builder: (context, c) {
          return Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFEFE7DA), Color(0xFFD9CBB4)],
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: c.maxHeight * 0.16,
                  child: Container(height: 8, color: const Color(0xFF9C8566)),
                ),
                for (final d in detections)
                  Positioned.fromRect(
                    rect: Rect.fromLTWH(
                      d.box.left * c.maxWidth,
                      d.box.top * c.maxHeight,
                      d.box.width * c.maxWidth,
                      d.box.height * c.maxHeight,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: d.product.color, width: 2.5),
                        borderRadius: BorderRadius.circular(10),
                        color: d.product.color.withValues(alpha: 0.12),
                      ),
                      child: Stack(
                        children: [
                          Center(child: Text(d.product.emoji, style: const TextStyle(fontSize: 38))),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: d.product.color,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
                              ),
                              child: Text(
                                d.product.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        }),
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

  // ── Nutrition tab ──────────────────────────────────────────────────────────

  Widget _buildNutritionTab(BuildContext context) {
    final visible = _visible;
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
                label: Text('${p.emoji} ${p.name}'),
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
        const SizedBox(height: 14),
        _GroupedOverview(products: visible, perServing: _perServing),
        const SizedBox(height: 12),
        for (final m in Metric.values)
          _MetricCard(metric: m, products: visible, perServing: _perServing),
        const SizedBox(height: 4),
        _SideBySideTable(products: visible, perServing: _perServing),
        const SizedBox(height: 12),
        const _NeutralityNote(),
      ],
    );
  }

  // ── Reviews tab ────────────────────────────────────────────────────────────

  Widget _buildReviewsTab(BuildContext context) {
    final products = widget.products;
    final themes = ReviewAnalyzer.allThemes(products);
    final cs = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Recurring complaints across products',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          'Share of each product\'s critical reviews (3★ or lower) that mention the topic.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: _themeMatrix(products, themes.take(8).toList()),
          ),
        ),
        const SizedBox(height: 14),
        Text('Filter reviews by topic',
            style: Theme.of(context).textTheme.labelLarge),
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
                child: Column(
                  children: [
                    Text(p.emoji, style: const TextStyle(fontSize: 22)),
                    Text(p.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
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

/// Grouped column chart: one group per nutrient, one column per product.
/// Columns are scaled within each nutrient so differences are easy to see.
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
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            Text('Columns are scaled within each nutrient.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final m in Metric.values)
                  Expanded(child: _group(context, m)),
              ],
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
    final maxV = values.values.fold<double>(0, math.max);
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
                  tween: Tween(begin: 0, end: values[p.id]! / denom),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (_, f, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(fmt(values[p.id]!), style: const TextStyle(fontSize: 9)),
                      const SizedBox(height: 2),
                      Container(
                        width: 12,
                        height: math.max(3, 104 * f),
                        decoration: BoxDecoration(
                          color: p.color,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
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
        Text(m.unit, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.grey)),
      ],
    );
  }
}

/// Horizontal bar chart for one nutrient. Tap a bar for context.
class _MetricCard extends StatefulWidget {
  final Metric metric;
  final List<Product> products;
  final bool perServing;
  const _MetricCard({required this.metric, required this.products, required this.perServing});

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
    final maxV = values.values.fold<double>(0, math.max);
    final denom = maxV == 0 ? 1.0 : maxV;
    final selected = widget.products.where((p) => p.id == _selected).toList();

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
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(widget.perServing ? 'per serving' : 'per 100 g',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
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
                        child: Text('${p.emoji} ${p.name}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: _selected == p.id ? FontWeight.w700 : FontWeight.w500,
                            )),
                      ),
                      Expanded(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: values[p.id]! / denom),
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
                        child: Text('${fmt(values[p.id]!)} ${m.unit}',
                            textAlign: TextAlign.end,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
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
                        '${selected.first.name}: ${fmt(values[selected.first.id]!)} ${m.unit} '
                        '≈ ${(values[selected.first.id]! / m.dailyReference * 100).round()}% of the '
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
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                defaultColumnWidth: const FixedColumnWidth(94),
                columnWidths: const {0: FixedColumnWidth(92)},
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                border: TableBorder(
                  horizontalInside: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
                ),
                children: [
                  TableRow(children: [
                    const SizedBox(),
                    for (final p in products)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(children: [
                          Text(p.emoji, style: const TextStyle(fontSize: 22)),
                          Text(p.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.labelSmall),
                        ]),
                      ),
                  ]),
                  for (final m in Metric.values)
                    TableRow(children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text('${m.label} (${m.unit})',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
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
                      Text('${fmt(p.nutrition.servingGrams)} g', textAlign: TextAlign.center),
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

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: product.color.withValues(alpha: 0.2),
                  child: Text(product.emoji, style: const TextStyle(fontSize: 20)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(product.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      Text(
                        '${product.brand} · ${product.avgRating}★ avg · ${product.ratingCount} ratings',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
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