import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bootstrap.dart';
import 'package:venera/pages/categories_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

import '../components/components.dart';
import '../foundation/app.dart';
import 'explore_page.dart';
import 'favorites/favorites_page.dart';
import 'home_page.dart';

@visibleForTesting
void markMainPageFirstFrameInteractive(
  BootstrapController controller, {
  void Function(String event) logEvent = logBootstrapEvent,
}) {
  logEvent('main page visible');
  controller.markHomeInteractive();
}

@visibleForTesting
int resolveInitialMainPageIndex(Object? value, int pageCount) {
  if (pageCount <= 0) {
    return 0;
  }
  final parsed = switch (value) {
    int() => value,
    String() => int.tryParse(value),
    _ => null,
  };
  if (parsed == null || parsed < 0 || parsed >= pageCount) {
    return 0;
  }
  return parsed;
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  late final NaviObserver _observer;

  GlobalKey<NavigatorState>? _navigatorKey;

  void to(Widget Function() widget, {bool preventDuplicate = false}) async {
    if (preventDuplicate) {
      var page = widget();
      final lastRoute = _observer.routes.lastOrNull;
      if (lastRoute != null && "/${page.runtimeType}" == lastRoute.toString()) {
        return;
      }
    }
    final context = _navigatorKey?.currentContext;
    if (context == null || !context.mounted) return;
    context.to(widget);
  }

  void back() {
    final context = _navigatorKey?.currentContext;
    if (context == null || !context.mounted) return;
    context.pop();
  }

  @override
  void initState() {
    super.initState();
    _observer = NaviObserver();
    _navigatorKey = GlobalKey();
    App.mainNavigatorKey = _navigatorKey;
    index = resolveInitialMainPageIndex(
      appdata.settings['initialPage'],
      _pages.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      markMainPageFirstFrameInteractive(bootstrapController);
    });
  }

  @override
  void dispose() {
    if (App.mainNavigatorKey == _navigatorKey) {
      App.mainNavigatorKey = null;
    }
    super.dispose();
  }

  final _pages = [
    const HomePage(),
    const FavoritesPage(key: PageStorageKey('favorites')),
    const ExplorePage(key: PageStorageKey('explore')),
    const CategoriesPage(key: PageStorageKey('categories')),
  ];

  var index = 0;

  @override
  Widget build(BuildContext context) {
    return NaviPane(
      initialPage: index,
      observer: _observer,
      navigatorKey: _navigatorKey!,
      paneItems: [
        PaneItemEntry(
          label: 'Home'.tl,
          icon: Icons.home_outlined,
          activeIcon: Icons.home,
        ),
        PaneItemEntry(
          label: 'Favorites'.tl,
          icon: Icons.local_activity_outlined,
          activeIcon: Icons.local_activity,
        ),
        PaneItemEntry(
          label: 'Explore'.tl,
          icon: Icons.explore_outlined,
          activeIcon: Icons.explore,
        ),
        PaneItemEntry(
          label: 'Categories'.tl,
          icon: Icons.category_outlined,
          activeIcon: Icons.category,
        ),
      ],
      onPageChanged: (i) {
        setState(() {
          index = i;
        });
      },
      paneActions: [
        if (index != 0)
          PaneActionEntry(
            icon: Icons.search,
            label: "Search".tl,
            onTap: () {
              to(() => const SearchPage(), preventDuplicate: true);
            },
          ),
        PaneActionEntry(
          icon: Icons.settings,
          label: "Settings".tl,
          onTap: () {
            to(() => const SettingsPage(), preventDuplicate: true);
          },
        ),
      ],
      pageBuilder: (index) {
        return _pages[index];
      },
    );
  }
}
