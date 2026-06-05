part of 'comic_source.dart';

class CategoryData {
  /// The title is displayed in the tab bar.
  final String title;

  /// 当使用中文语言时, 英文的分类标签将在构建页面时被翻译为中文
  final List<BaseCategoryPart> categories;

  final bool enableRankingPage;

  final String key;

  final List<CategoryButtonData> buttons;

  /// Data class for building category page.
  const CategoryData({
    required this.title,
    required this.categories,
    required this.enableRankingPage,
    required this.key,
    this.buttons = const [],
  });
}

class CategoryButtonData {
  final String label;

  final void Function() onTap;

  const CategoryButtonData({required this.label, required this.onTap});
}

class CategoryItem {
  final String label;

  final PageJumpTarget target;

  const CategoryItem(this.label, this.target);
}

@visibleForTesting
List<CategoryItem> normalizeDynamicCategoryItems(
  Object? data,
  String sourceKey,
) {
  if (data is! Iterable) {
    return const [];
  }
  final res = <CategoryItem>[];
  for (final item in data) {
    final map = comicSourceMapOrNull(item);
    if (map == null) {
      continue;
    }
    final label = comicSourceNullableString(map['label']);
    if (label == null) {
      continue;
    }
    res.add(
      CategoryItem(label, PageJumpTarget.parse(sourceKey, map['target'])),
    );
  }
  return res;
}

@visibleForTesting
List<String> normalizeLegacyCategoryTags(Object? data) {
  if (data is! Iterable) {
    return const [];
  }
  return data
      .where((item) => item != null)
      .map((item) => item.toString())
      .where((item) => item.isNotEmpty)
      .toList();
}

@visibleForTesting
int normalizeCategoryRandomNumber(Object? value) {
  return comicSourceInt(value) ?? 1;
}

abstract class BaseCategoryPart {
  String get title;

  List<CategoryItem> get categories;

  bool get enableRandom;

  /// Data class for building a part of category page.
  const BaseCategoryPart();
}

class FixedCategoryPart extends BaseCategoryPart {
  @override
  final List<CategoryItem> categories;

  @override
  bool get enableRandom => false;

  @override
  final String title;

  /// A [BaseCategoryPart] that show fixed tags on category page.
  const FixedCategoryPart(this.title, this.categories);
}

@visibleForTesting
int randomCategoryStartBound({
  required int itemCount,
  required int randomNumber,
}) {
  if (itemCount <= 0 || randomNumber <= 0 || randomNumber >= itemCount) {
    return 0;
  }
  return itemCount - randomNumber + 1;
}

class RandomCategoryPart extends BaseCategoryPart {
  final List<CategoryItem> all;

  final int randomNumber;

  @override
  final String title;

  @override
  bool get enableRandom => true;

  List<CategoryItem> _categories() {
    if (randomNumber <= 0 || all.isEmpty) {
      return const [];
    }
    if (randomNumber >= all.length) {
      return all;
    }
    var start = math.Random().nextInt(
      randomCategoryStartBound(
        itemCount: all.length,
        randomNumber: randomNumber,
      ),
    );
    return all.sublist(start, start + randomNumber);
  }

  @override
  List<CategoryItem> get categories => _categories();

  /// A [BaseCategoryPart] that show a part of random tags on category page.
  const RandomCategoryPart(this.title, this.all, this.randomNumber);
}

class DynamicCategoryPart extends BaseCategoryPart {
  final JSAutoFreeFunction loader;

  final String sourceKey;

  @override
  List<CategoryItem> get categories {
    return normalizeDynamicCategoryItems(loader([]), sourceKey);
  }

  @override
  bool get enableRandom => false;

  @override
  final String title;

  /// A [BaseCategoryPart] that show dynamic tags on category page.
  const DynamicCategoryPart(this.title, this.loader, this.sourceKey);
}

CategoryData getCategoryDataWithKey(String key) {
  for (var source in ComicSource.all()) {
    if (source.categoryData?.key == key) {
      return source.categoryData!;
    }
  }
  throw "Unknown category key $key";
}
