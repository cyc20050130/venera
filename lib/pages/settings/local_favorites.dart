part of 'settings_page.dart';

class LocalFavoritesSettings extends StatefulWidget {
  const LocalFavoritesSettings({super.key});

  @override
  State<LocalFavoritesSettings> createState() => _LocalFavoritesSettingsState();
}

class _LocalFavoritesSettingsState extends State<LocalFavoritesSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Local Favorites".tl)),
        _SwitchSetting(
          title: "Show local favorites before network favorites".tl,
          settingKey: "localFavoritesFirst",
        ).toSliver(),
        _SwitchSetting(
          title: "Auto close favorite panel after operation".tl,
          settingKey: "autoCloseFavoritePanel",
        ).toSliver(),
        SelectSetting(
          title: "Add new favorite to".tl,
          settingKey: "newFavoriteAddTo",
          optionTranslation: {"start": "Start".tl, "end": "End".tl},
        ).toSliver(),
        SelectSetting(
          title: "Move favorite after reading".tl,
          settingKey: "moveFavoriteAfterRead",
          optionTranslation: {
            "none": "None".tl,
            "end": "End".tl,
            "start": "Start".tl,
          },
        ).toSliver(),
        SelectSetting(
          title: "Quick Favorite".tl,
          settingKey: "quickFavorite",
          help:
              "Long press on the favorite button to quickly add to this folder"
                  .tl,
          optionTranslation: {
            for (var e in LocalFavoritesManager().folderNames) e: e,
          },
        ).toSliver(),
        _CallbackSetting(
          title: "Delete all unavailable local favorite items".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            try {
              var count = await LocalFavoritesManager().removeInvalid();
              if (!mounted) return;
              context.showMessage(
                message: "Deleted @a favorite items".tlParams({'a': count}),
              );
            } finally {
              controller.close();
            }
          },
          actionTitle: 'Delete'.tl,
        ).toSliver(),
        SelectSetting(
          title: "Click favorite".tl,
          settingKey: "onClickFavorite",
          optionTranslation: {
            "viewDetail": "View Detail".tl,
            "read": "Read".tl,
          },
        ).toSliver(),
      ],
    );
  }
}
