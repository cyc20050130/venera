import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

@visibleForTesting
Uri? parseCookieSaveUri(String url) {
  if (_hasMalformedPercentEncoding(url)) {
    return null;
  }
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    return null;
  }
  return uri;
}

@visibleForTesting
List<Map<String, dynamic>>? decodeComicSourceListPayload(String? data) {
  if (data == null) {
    return null;
  }
  try {
    return parseComicSourceListPayload(jsonDecode(data));
  } catch (_) {
    return null;
  }
}

@visibleForTesting
List<Map<String, dynamic>>? parseComicSourceListPayload(Object? payload) {
  if (payload is! List) {
    return null;
  }
  final result = <Map<String, dynamic>>[];
  for (final item in payload) {
    if (item is! Map) {
      continue;
    }
    final key = item['key'];
    final name = item['name'];
    final version = item['version'];
    final fileName = item['fileName'];
    if (key is! String ||
        key.isEmpty ||
        name is! String ||
        name.isEmpty ||
        version is! String ||
        version.isEmpty ||
        fileName is! String ||
        fileName.isEmpty) {
      continue;
    }
    result.add({
      'key': key,
      'name': name,
      'version': version,
      'fileName': fileName,
      if (item['url'] is String) 'url': item['url'],
      if (item['description'] is String) 'description': item['description'],
    });
  }
  return result;
}

@visibleForTesting
Map<String, dynamic>? normalizeComicSourceSettingItem(Object? value) {
  final map = comicSourceMapOrNull(value);
  if (map == null) {
    return null;
  }
  final type = map['type'];
  if (type is! String) {
    return null;
  }
  final normalized = <String, dynamic>{
    ...map,
    'type': type,
    'title': comicSourceString(map['title']),
  };
  switch (type) {
    case 'select':
      final options = comicSourceMapList(map['options'])
          .map(
            (option) => <String, dynamic>{
              'value': comicSourceString(option['value']),
              'text': comicSourceString(
                option['text'],
                fallback: comicSourceString(option['value']),
              ),
            },
          )
          .toList();
      if (options.isEmpty) {
        return null;
      }
      normalized['options'] = options;
      normalized['default'] = comicSourceString(map['default']);
    case 'switch':
      normalized['default'] = comicSourceBool(map['default']) ?? false;
    case 'input':
      normalized['default'] = comicSourceString(map['default']);
      if (map['validator'] is! String) {
        normalized.remove('validator');
      }
    case 'callback':
      normalized['buttonText'] = comicSourceString(
        map['buttonText'],
        fallback: 'Click',
      );
    default:
      return null;
  }
  return normalized;
}

@visibleForTesting
List<Map<String, String>> normalizeComicSourceSettingOptions(Object? value) {
  return comicSourceMapList(value)
      .map(
        (option) => <String, String>{
          'value': comicSourceString(option['value']),
          'text': comicSourceString(
            option['text'],
            fallback: comicSourceString(option['value']),
          ),
        },
      )
      .toList();
}

@visibleForTesting
Map<String, dynamic> normalizeComicSourceRuntimeSettings(Object? value) {
  return comicSourceMapOrNull(value) ?? <String, dynamic>{};
}

@visibleForTesting
List<MapEntry<String, String>> filterAvailableComicSourceUpdates(
  Map<String, String> updates,
  bool Function(String key) hasSource,
) {
  return updates.entries.where((entry) => hasSource(entry.key)).toList();
}

bool _hasMalformedPercentEncoding(String value) {
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) != 0x25) {
      continue;
    }
    if (i + 2 >= value.length ||
        !_isHexDigit(value.codeUnitAt(i + 1)) ||
        !_isHexDigit(value.codeUnitAt(i + 2))) {
      return true;
    }
  }
  return false;
}

bool _isHexDigit(int codeUnit) {
  return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x46) ||
      (codeUnit >= 0x61 && codeUnit <= 0x66);
}

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
  ]) async {
    if (!source.url.isURL) {
      if (showLoading) {
        App.rootContext.showMessage(message: "Invalid url config");
        return;
      } else {
        throw Exception("Invalid url config");
      }
    }
    ComicSourceManager().remove(source.key);
    bool cancel = false;
    LoadingDialogController? controller;
    if (showLoading) {
      controller = showLoadingDialog(
        App.rootContext,
        onCancel: () => cancel = true,
        barrierDismissible: false,
      );
    }
    try {
      var res = await AppDio().get<String>(
        source.url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      if (cancel) return;
      controller?.close();
      await ComicSourceParser().parse(res.data!, source.filePath);
      await io.File(source.filePath).writeAsString(res.data!);
      ComicSourceManager().removeAvailableUpdates([source.key]);
    } catch (e) {
      if (cancel) return;
      if (showLoading) {
        App.rootContext.showMessage(message: e.toString());
      } else {
        rethrow;
      }
    }
    await ComicSourceManager().reload();
    if (showLoading) {
      App.forceRebuild();
    }
  }

  static Future<int> checkComicSourceUpdate() async {
    if (ComicSource.all().isEmpty) {
      return 0;
    }
    var dio = AppDio();
    var res = await dio.get<String>(appdata.settings['comicSourceListUrl']);
    if (res.statusCode != 200) {
      return -1;
    }
    var list = decodeComicSourceListPayload(res.data);
    if (list == null) {
      return -1;
    }
    var versions = <String, String>{};
    for (var source in list) {
      versions[source['key']] = source['version'];
    }
    var shouldUpdate = <String>[];
    for (var source in ComicSource.all()) {
      if (versions.containsKey(source.key) &&
          compareSemVer(versions[source.key]!, source.version)) {
        shouldUpdate.add(source.key);
      }
    }
    if (shouldUpdate.isNotEmpty) {
      var updates = <String, String>{};
      for (var key in shouldUpdate) {
        updates[key] = versions[key]!;
      }
      ComicSourceManager().updateAvailableUpdates(updates);
    }
    return shouldUpdate.length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: const _Body());
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  var url = "";

  void updateUI() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ComicSourceManager().addListener(updateUI);
  }

  @override
  void dispose() {
    ComicSourceManager().removeListener(updateUI);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Comic Source'.tl), style: AppbarStyle.shadow),
        buildCard(context),
        for (var source in ComicSource.all())
          _SliverComicSource(
            key: ValueKey(source.key),
            source: source,
            edit: edit,
            update: update,
            delete: delete,
          ),
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        var file = File(source.filePath);
        file.delete();
        ComicSourceManager().remove(source.key);
        _validatePages();
        App.forceRebuild();
      },
    );
  }

  void edit(ComicSource source) async {
    if (App.isDesktop) {
      try {
        await Process.run("code", [source.filePath], runInShell: true);
        await showDialog(
          context: App.rootContext,
          builder: (context) => AlertDialog(
            title: const Text("Reload Configs"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("cancel"),
              ),
              TextButton(
                onPressed: () async {
                  await ComicSourceManager().reload();
                  App.forceRebuild();
                },
                child: const Text("continue"),
              ),
            ],
          ),
        );
        return;
      } catch (e) {
        //
      }
    }
    context.to(
      () => _EditFilePage(source.filePath, () async {
        await ComicSourceManager().reload();
        if (mounted) {
          setState(() {});
        }
      }),
    );
  }

  void update(ComicSource source, [bool showLoading = true]) {
    ComicSourcePage.update(source, showLoading);
  }

  Widget buildCard(BuildContext context) {
    return SliverToBoxAdapter(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text("Add comic source".tl),
              leading: const Icon(Icons.dashboard_customize),
            ),
            TextField(
              decoration: InputDecoration(
                hintText: "URL",
                border: const UnderlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                suffix: IconButton(
                  onPressed: () => handleAddSource(url),
                  icon: const Icon(Icons.check),
                ),
              ),
              onChanged: (value) {
                url = value;
              },
              onSubmitted: handleAddSource,
            ).paddingHorizontal(16).paddingBottom(8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: Icon(Icons.article_outlined),
                  label: Text("Comic Source list".tl),
                  onPressed: () {
                    showPopUpWidget(
                      App.rootContext,
                      _ComicSourceList(handleAddSource),
                    );
                  },
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.file_open_outlined),
                  label: Text("Use a config file".tl),
                  onPressed: _selectFile,
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.help_outline),
                  label: Text("Help".tl),
                  onPressed: help,
                ),
                _CheckUpdatesButton(),
              ],
            ).paddingHorizontal(12).paddingVertical(8),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _selectFile() async {
    final file = await selectFile(ext: ["js"]);
    if (file == null) return;
    if (!mounted) return;
    try {
      var fileName = file.name;
      var bytes = await file.readAsBytes();
      if (!mounted) return;
      var content = utf8.decode(bytes);
      await addSource(content, fileName);
    } catch (e, s) {
      App.rootContext.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  void help() {
    launchUrlString(
      "https://github.com/cyc20050130/venera/blob/master/doc/comic_source.md",
    );
  }

  Future<void> handleAddSource(String url) async {
    if (url.isEmpty) {
      return;
    }
    var splits = url.split("/");
    splits.removeWhere((element) => element == "");
    var fileName = splits.last;
    bool cancel = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () => cancel = true,
      barrierDismissible: false,
    );
    try {
      var res = await AppDio().get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      if (cancel) return;
      await addSource(res.data!, fileName);
    } catch (e, s) {
      if (cancel) return;
      if (mounted) {
        context.showMessage(message: e.toString());
      }
      Log.error("Add comic source", "$e\n$s");
    } finally {
      controller.close();
    }
  }

  Future<void> addSource(String js, String fileName) async {
    var comicSource = await ComicSourceParser().createAndParse(js, fileName);
    ComicSourceManager().add(comicSource);
    _addAllPagesWithComicSource(comicSource);
    appdata.saveDataInBackground();
    App.forceRebuild();
  }
}

class _ComicSourceList extends StatefulWidget {
  const _ComicSourceList(this.onAdd);

  final Future<void> Function(String) onAdd;

  @override
  State<_ComicSourceList> createState() => _ComicSourceListState();
}

class _ComicSourceListState extends State<_ComicSourceList> {
  List<Map<String, dynamic>>? json;
  bool changed = false;
  var controller = TextEditingController();
  int _loadRequestId = 0;

  void load() async {
    final requestId = ++_loadRequestId;
    if (json != null) {
      setState(() {
        json = null;
      });
    }
    if (controller.text.isEmpty) {
      setState(() {
        json = [];
      });
      return;
    }
    var dio = AppDio();
    try {
      var res = await dio.get<String>(controller.text);
      if (res.statusCode != 200) {
        throw "error";
      }
      if (mounted && requestId == _loadRequestId) {
        final parsed = decodeComicSourceListPayload(res.data);
        if (parsed == null) {
          throw "error";
        }
        setState(() {
          json = parsed;
        });
      }
    } catch (e) {
      if (mounted && requestId == _loadRequestId) {
        context.showMessage(message: "Network error".tl);
        setState(() {
          json = [];
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    controller.text = appdata.settings['comicSourceListUrl'];
    load();
  }

  @override
  void dispose() {
    if (changed) {
      appdata.settings['comicSourceListUrl'] = controller.text;
      appdata.saveDataInBackground();
    }
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(title: "Comic Source".tl, body: buildBody());
  }

  Widget buildBody() {
    var currentKey = ComicSource.all().map((e) => e.key).toList();

    return ListView.builder(
      itemCount: (json?.length ?? 1) + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.6,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: Icon(Icons.source_outlined),
                  title: Text("Repo URL".tl),
                ),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: "URL",
                    border: const UnderlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onChanged: (value) {
                    changed = true;
                  },
                ).paddingHorizontal(16).paddingBottom(8),
                Text(
                  "The URL should point to a 'index.json' file".tl,
                ).paddingLeft(16),
                Text(
                  "Do not report any issues related to sources to App repo.".tl,
                ).paddingLeft(16),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        launchUrlString(
                          "https://github.com/cyc20050130/venera/blob/master/doc/comic_source.md",
                        );
                      },
                      child: Text("Help".tl),
                    ),
                    FilledButton.tonal(
                      onPressed: load,
                      child: Text("Refresh".tl),
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        }

        if (index == 1 && json == null) {
          return Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
            ).fixWidth(24).fixHeight(24),
          );
        }

        index--;

        var key = json![index]["key"];
        var action = currentKey.contains(key)
            ? const Icon(Icons.check, size: 20).paddingRight(8)
            : Button.filled(
                child: Text("Add".tl),
                onPressed: () async {
                  var fileName = json![index]["fileName"];
                  var url = json![index]["url"];
                  if (url == null || !(url.toString()).isURL) {
                    var listUrl =
                        appdata.settings['comicSourceListUrl']?.toString() ??
                        "";
                    if (listUrl
                        .replaceFirst("https://", "")
                        .replaceFirst("http://", "")
                        .contains("/")) {
                      url =
                          listUrl.substring(0, listUrl.lastIndexOf("/") + 1) +
                          fileName;
                    } else {
                      url = '$listUrl/$fileName';
                    }
                  }
                  await widget.onAdd(url);
                  if (mounted) {
                    setState(() {});
                  }
                },
              ).fixHeight(32);

        var description = json![index]["version"];
        if (json![index]["description"] != null) {
          description = "$description\n${json![index]["description"]}";
        }

        return ListTile(
          title: Text(json![index]["name"]),
          subtitle: Text(description),
          trailing: action,
        );
      },
    );
  }
}

void _validatePages() {
  var explorePages = appdata.settings.stringList('explore_pages');
  var categoryPages = appdata.settings.stringList('categories');
  var networkFavorites = appdata.settings.stringList('favorites');

  var totalExplorePages = ComicSource.all()
      .map((e) => e.explorePages.map((e) => e.title))
      .expand((element) => element)
      .toList();
  var totalCategoryPages = ComicSource.all()
      .map((e) => e.categoryData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();
  var totalNetworkFavorites = ComicSource.all()
      .map((e) => e.favoriteData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();

  for (var page in List.from(explorePages)) {
    if (!totalExplorePages.contains(page)) {
      explorePages.remove(page);
    }
  }
  for (var page in List.from(categoryPages)) {
    if (!totalCategoryPages.contains(page)) {
      categoryPages.remove(page);
    }
  }
  for (var page in List.from(networkFavorites)) {
    if (!totalNetworkFavorites.contains(page)) {
      networkFavorites.remove(page);
    }
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();

  appdata.saveDataInBackground();
}

void _addAllPagesWithComicSource(ComicSource source) {
  var explorePages = appdata.settings.stringList('explore_pages');
  var categoryPages = appdata.settings.stringList('categories');
  var networkFavorites = appdata.settings.stringList('favorites');
  var searchPages = appdata.settings.stringList('searchSources');

  if (source.explorePages.isNotEmpty) {
    for (var page in source.explorePages) {
      if (!explorePages.contains(page.title)) {
        explorePages.add(page.title);
      }
    }
  }
  if (source.categoryData != null &&
      !categoryPages.contains(source.categoryData!.key)) {
    categoryPages.add(source.categoryData!.key);
  }
  if (source.favoriteData != null &&
      !networkFavorites.contains(source.favoriteData!.key)) {
    networkFavorites.add(source.favoriteData!.key);
  }
  if (source.searchPageData != null && !searchPages.contains(source.key)) {
    searchPages.add(source.key);
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();
  appdata.settings['searchSources'] = searchPages.toSet().toList();

  appdata.saveDataInBackground();
}

class _EditFilePage extends StatefulWidget {
  const _EditFilePage(this.path, this.onExit);

  final String path;

  final void Function() onExit;

  @override
  State<_EditFilePage> createState() => __EditFilePageState();
}

class __EditFilePageState extends State<_EditFilePage> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = File(widget.path).readAsStringSync();
  }

  @override
  void dispose() {
    File(widget.path).writeAsStringSync(current);
    widget.onExit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Edit".tl)),
      body: Column(
        children: [
          Container(height: 0.6, color: context.colorScheme.outlineVariant),
          Expanded(
            child: CodeEditor(
              initialValue: current,
              onChanged: (value) => current = value,
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckUpdatesButton extends StatefulWidget {
  const _CheckUpdatesButton();

  @override
  State<_CheckUpdatesButton> createState() => _CheckUpdatesButtonState();
}

class _CheckUpdatesButtonState extends State<_CheckUpdatesButton> {
  bool isLoading = false;

  void check() async {
    setState(() {
      isLoading = true;
    });
    var count = await ComicSourcePage.checkComicSourceUpdate();
    if (!mounted) return;
    if (count == -1) {
      context.showMessage(message: "Network error".tl);
    } else if (count == 0) {
      context.showMessage(message: "No updates".tl);
    } else {
      showUpdateDialog();
    }
    setState(() {
      isLoading = false;
    });
  }

  void showUpdateDialog() async {
    final updates = ComicSourceManager().availableUpdates;
    final liveUpdates = filterAvailableComicSourceUpdates(
      updates,
      (key) => ComicSource.find(key) != null,
    );
    final staleKeys = updates.keys
        .where((key) => !liveUpdates.any((entry) => entry.key == key))
        .toList();
    ComicSourceManager().removeAvailableUpdates(staleKeys);
    if (liveUpdates.isEmpty) {
      context.showMessage(message: "No updates".tl);
      return;
    }
    final updateLines = <String>[];
    for (final update in liveUpdates) {
      final source = ComicSource.find(update.key);
      if (source == null) {
        ComicSourceManager().removeAvailableUpdates([update.key]);
        continue;
      }
      updateLines.add("${source.name}: ${update.value}");
    }
    if (updateLines.isEmpty) {
      context.showMessage(message: "No updates".tl);
      return;
    }
    var text = updateLines.join("\n");
    bool doUpdate = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Updates".tl,
          content: Text(text).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () {
                doUpdate = true;
                context.pop();
              },
              child: Text("Update".tl),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (doUpdate) {
      var loadingController = showLoadingDialog(
        context,
        message: "Updating".tl,
        withProgress: true,
      );
      int current = 0;
      int total = liveUpdates.length;
      try {
        for (var update in liveUpdates) {
          var source = ComicSource.find(update.key);
          if (source == null) {
            ComicSourceManager().removeAvailableUpdates([update.key]);
            continue;
          }
          await ComicSourcePage.update(source, false);
          if (!mounted) return;
          current++;
          loadingController.setProgress(current / total);
        }
      } catch (e) {
        if (mounted) {
          context.showMessage(message: e.toString());
        }
      } finally {
        loadingController.close();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: isLoading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.update),
      label: Text("Check updates".tl),
      onPressed: check,
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText =>
      comicSourceString(widget.setting.value['buttonText'], fallback: "Click");

  String get title =>
      comicSourceString(widget.setting.value['title'], fallback: key);

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    dynamic result;
    try {
      result = func([]);
    } catch (e, s) {
      Log.error(
        "ComicSourcePage",
        "Failed to run source setting callback: $e",
        s,
      );
      return;
    }
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        if (mounted) {
          setState(() {
            isLoading = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

class _SliverComicSource extends StatefulWidget {
  const _SliverComicSource({
    super.key,
    required this.source,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final ComicSource source;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends State<_SliverComicSource> {
  ComicSource get source => widget.source;

  @override
  Widget build(BuildContext context) {
    var newVersion = ComicSourceManager().availableUpdates[source.key];
    bool hasUpdate =
        newVersion != null && compareSemVer(newVersion, source.version);

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(padding: const EdgeInsets.only(top: 16)),
        SliverToBoxAdapter(
          child: ListTile(
            title: Row(
              children: [
                Text(source.name, style: ts.s18),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    source.version,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (hasUpdate)
                  Tooltip(
                    message: newVersion,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: context.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        "New Version".tl,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ).paddingLeft(4),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: "Edit".tl,
                  child: IconButton(
                    onPressed: () => widget.edit(source),
                    icon: const Icon(Icons.edit_note),
                  ),
                ),
                Tooltip(
                  message: "Update".tl,
                  child: IconButton(
                    onPressed: () => widget.update(source),
                    icon: const Icon(Icons.update),
                  ),
                ),
                Tooltip(
                  message: "Delete".tl,
                  child: IconButton(
                    onPressed: () => widget.delete(source),
                    icon: const Icon(Icons.delete),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(children: buildSourceSettings().toList()),
        ),
        SliverToBoxAdapter(child: Column(children: _buildAccount().toList())),
      ],
    );
  }

  Iterable<Widget> buildSourceSettings() sync* {
    // Try to get dynamic settings first (for getters), fall back to cached settings
    var settingsMap = source.getSettingsDynamic() ?? source.settings;

    if (settingsMap == null) {
      return;
    }
    final sourceSettings = normalizeComicSourceRuntimeSettings(
      source.data['settings'],
    );
    source.data['settings'] = sourceSettings;
    for (var item in settingsMap.entries) {
      var key = item.key;
      final setting = normalizeComicSourceSettingItem(item.value);
      if (setting == null) {
        continue;
      }
      final type = comicSourceString(setting['type']);
      final title = comicSourceString(setting['title'], fallback: key);
      try {
        if (type == "select") {
          var current = sourceSettings[key];
          final options = normalizeComicSourceSettingOptions(
            setting['options'],
          );
          if (options.isEmpty) {
            continue;
          }
          final defaultValue = comicSourceString(setting['default']);
          final currentOption = options.firstWhereOrNull(
            (option) => option['value'] == (current ?? defaultValue),
          );
          current = comicSourceString(
            currentOption?['text'] ?? currentOption?['value'] ?? current,
          );
          yield ListTile(
            title: Text(title.ts(source.key)),
            trailing: Select(
              current: current.ts(source.key),
              values: options
                  .map<String>(
                    (option) => comicSourceString(
                      option['text'] ?? option['value'],
                    ).ts(source.key),
                  )
                  .toList(),
              onTap: (i) {
                sourceSettings[key] = options[i]['value'] ?? defaultValue;
                source.saveDataInBackground();
                setState(() {});
              },
            ),
          );
        } else if (type == "switch") {
          var current =
              comicSourceBool(sourceSettings[key]) ??
              (comicSourceBool(setting['default']) ?? false);
          yield ListTile(
            title: Text(title.ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                sourceSettings[key] = v;
                source.saveDataInBackground();
                setState(() {});
              },
            ),
          );
        } else if (type == "input") {
          var current = comicSourceString(
            sourceSettings[key],
            fallback: comicSourceString(setting['default']),
          );
          yield ListTile(
            title: Text(title.ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                RegExp? inputValidator;
                final validator = setting['validator'];
                if (validator is String && validator.isNotEmpty) {
                  try {
                    inputValidator = RegExp(validator);
                  } catch (e, s) {
                    Log.error(
                      "ComicSourcePage",
                      "Invalid source setting validator\n$e\n$s",
                    );
                  }
                }
                showInputDialog(
                  context: context,
                  title: title.ts(source.key),
                  initialValue: current,
                  inputValidator: inputValidator,
                  onConfirm: (value) {
                    sourceSettings[key] = value;
                    source.saveDataInBackground();
                    setState(() {});
                    return null;
                  },
                );
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(
            setting: MapEntry(key, setting),
            sourceKey: source.key,
          );
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  final _reLogin = <String, bool>{};

  Iterable<Widget> _buildAccount() sync* {
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (source.isLoginExpired) {
      yield ListTile(
        leading: const Icon(Icons.error_outline),
        title: Text("Login expired".tl),
        subtitle: Text("Please login again".tl),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          if (!mounted) return;
          source.saveDataInBackground();
          setState(() {});
        },
      );
    }
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.arrow_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          if (!mounted) return;
          source.saveDataInBackground();
          setState(() {});
        },
      );
    }
    if (logged) {
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List && source.account?.login != null) {
        bool loading = _reLogin[source.key] == true;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            final account = source.storedAccountCredentials;
            if (account == null) {
              context.showMessage(message: "No data".tl);
              return;
            }
            setState(() {
              _reLogin[source.key] = true;
            });
            var res = await source.account!.login!(
              account.username,
              account.password,
            );
            if (!mounted) return;
            if (res.error) {
              context.showMessage(message: res.errorMessage!);
            } else {
              context.showMessage(message: "Success".tl);
            }
            setState(() {
              _reLogin[source.key] = false;
            });
          },
          trailing: loading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: () {
          source.data["account"] = null;
          source.account?.logout();
          source.saveDataInBackground();
          ComicSourceManager().notifyStateChange();
          setState(() {});
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  String username = "";
  String password = "";
  bool loading = false;
  int _loginRequestId = 0;

  final Map<String, String> _cookies = {};

  @override
  void dispose() {
    _loginRequestId++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const Appbar(title: Text('')),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 400),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Login".tl, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 32),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Username".tl,
                      border: const OutlineInputBorder(),
                    ),
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      username = s;
                    },
                    autofillHints: const [AutofillHints.username],
                  ).paddingBottom(16),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Password".tl,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      password = s;
                    },
                    onSubmitted: (s) => login(),
                    autofillHints: const [AutofillHints.password],
                  ).paddingBottom(16),
                for (var field in widget.config.cookieFields ?? <String>[])
                  TextField(
                    decoration: InputDecoration(
                      labelText: field,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.validateCookies != null,
                    onChanged: (s) {
                      _cookies[field] = s;
                    },
                  ).paddingBottom(16),
                if (widget.config.login == null &&
                    widget.config.cookieFields == null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Text("Login with password is disabled".tl),
                    ],
                  )
                else
                  Button.filled(
                    isLoading: loading,
                    onPressed: login,
                    child: Text("Continue".tl),
                  ),
                const SizedBox(height: 24),
                if (widget.config.loginWebsite != null)
                  TextButton(
                    onPressed: () {
                      if (App.isLinux) {
                        loginWithWebview2();
                      } else {
                        loginWithWebview();
                      }
                    },
                    child: Text("Login with webview".tl),
                  ),
                const SizedBox(height: 8),
                if (widget.config.registerWebsite != null)
                  TextButton(
                    onPressed: () =>
                        launchUrlString(widget.config.registerWebsite!),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link),
                        const SizedBox(width: 8),
                        Text("Create Account".tl),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void login() async {
    if (loading) return;
    final requestId = ++_loginRequestId;
    if (widget.config.login != null) {
      if (username.isEmpty || password.isEmpty) {
        showToast(
          message: "Cannot be empty".tl,
          icon: const Icon(Icons.error_outline),
          context: context,
        );
        return;
      }
      setState(() {
        loading = true;
      });
      final value = await widget.config.login!(username, password);
      if (!mounted || requestId != _loginRequestId) return;
      if (value.error) {
        context.showMessage(message: value.errorMessage!);
        setState(() {
          loading = false;
        });
      } else {
        context.pop();
      }
    } else if (widget.config.validateCookies != null) {
      setState(() {
        loading = true;
      });
      var cookies = widget.config.cookieFields!
          .map((e) => _cookies[e] ?? '')
          .toList();
      final value = await widget.config.validateCookies!(cookies);
      if (!mounted || requestId != _loginRequestId) return;
      if (value) {
        widget.source.data['account'] = 'ok';
        widget.source.clearLoginExpired();
        widget.source.saveDataInBackground();
        context.pop();
      } else {
        context.showMessage(message: "Invalid cookies".tl);
        setState(() {
          loading = false;
        });
      }
    }
  }

  void loginWithWebview() async {
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void validate(InAppWebViewController c) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookies = (await c.getCookies(url)) ?? [];
        var localStorageItems = await c.webStorage.localStorage.getItems();
        if (!mounted) return;
        var mappedLocalStorage = <String, dynamic>{};
        for (var item in localStorageItems) {
          if (item.key != null) {
            mappedLocalStorage[item.key!] = item.value;
          }
        }
        widget.source.data['_localStorage'] = mappedLocalStorage;
        await widget.source.saveData();
        if (!mounted) return;
        final cookieUri = parseCookieSaveUri(url);
        if (cookieUri == null) {
          Log.warning("ComicSourcePage", "Skip cookies for invalid URL: $url");
          return;
        }
        SingleInstanceCookieJar.instance?.saveFromResponse(cookieUri, cookies);
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        App.mainNavigatorKey?.currentContext?.pop();
      }
    }

    await context.to(
      () => AppWebview(
        initialUrl: widget.config.loginWebsite!,
        onNavigation: (u, c) {
          url = u;
          validate(c);
          return false;
        },
        onTitleChange: (t, c) {
          title = t;
          validate(c);
        },
      ),
    );
    if (!mounted) return;
    if (success) {
      widget.source.data['account'] = 'ok';
      widget.source.clearLoginExpired();
      widget.source.saveDataInBackground();
      context.pop();
    }
  }

  // for linux
  void loginWithWebview2() async {
    if (!await DesktopWebview.isAvailable()) {
      if (mounted) {
        context.showMessage(message: "Webview is not available".tl);
      }
      return;
    }
    if (!mounted) return;

    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void onClose() {
      if (success && mounted) {
        widget.source.data['account'] = 'ok';
        widget.source.clearLoginExpired();
        widget.source.saveDataInBackground();
        context.pop();
      }
    }

    void validate(DesktopWebview webview) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookiesMap = await webview.getCookies(url);
        if (!mounted) return;
        var cookies = <io.Cookie>[];
        cookiesMap.forEach((key, value) {
          cookies.add(io.Cookie(key, value));
        });
        final cookieUri = parseCookieSaveUri(url);
        if (cookieUri == null) {
          Log.warning("ComicSourcePage", "Skip cookies for invalid URL: $url");
          return;
        }
        SingleInstanceCookieJar.instance?.saveFromResponse(cookieUri, cookies);
        var localStorageJson = await webview.evaluateJavascript(
          "JSON.stringify(window.localStorage);",
        );
        if (!mounted) return;
        var localStorage = <String, dynamic>{};
        try {
          var decoded = jsonDecode(localStorageJson ?? '');
          if (decoded is Map<String, dynamic>) {
            localStorage = decoded;
          }
        } catch (e) {
          Log.error("ComicSourcePage", "Failed to parse localStorage JSON\n$e");
        }
        widget.source.data['_localStorage'] = localStorage;
        await widget.source.saveData();
        if (!mounted) return;
        widget.source.clearLoginExpired();
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        webview.close();
        onClose();
      }
    }

    var webview = DesktopWebview(
      initialUrl: widget.config.loginWebsite!,
      onTitleChange: (t, webview) {
        title = t;
        validate(webview);
      },
      onNavigation: (u, webview) {
        url = u;
        validate(webview);
      },
      onClose: onClose,
    );

    webview.open();
  }
}
