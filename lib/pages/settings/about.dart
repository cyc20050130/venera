part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text("V${App.version}", style: const TextStyle(fontSize: 16)),
            Text("Venera is a free and open-source app for comic reading.".tl),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        ListTile(
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            child: Text("Check".tl),
            onPressed: () async {
              if (isCheckingUpdate) return;
              setState(() {
                isCheckingUpdate = true;
              });
              await checkUpdateUi();
              if (!mounted) return;
              setState(() {
                isCheckingUpdate = false;
              });
            },
          ).fixHeight(32),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: const Text("Github"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/cyc20050130/venera");
          },
        ).toSliver(),
      ],
    );
  }
}

Future<bool> checkUpdate() async {
  var res = await AppDio().get(
    "https://cdn.jsdelivr.net/gh/cyc20050130/venera@master/pubspec.yaml",
  );
  if (res.statusCode == 200) {
    var data = loadYaml(res.data);
    if (data["version"] != null) {
      return isNewerAppVersion(
        data["version"].toString().split("+")[0],
        App.version,
      );
    }
  }
  return false;
}

Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  try {
    var value = await checkUpdate();
    if (value) {
      if (delay) {
        await Future.delayed(const Duration(seconds: 2));
      }
      final context = App.rootNavigatorKey.currentContext;
      if (context == null || !context.mounted) {
        return;
      }
      showDialog(
        context: context,
        builder: (context) {
          return ContentDialog(
            title: "New version available".tl,
            content: Text(
              "A new version is available. Do you want to update now?".tl,
            ).paddingHorizontal(16),
            actions: [
              Button.text(
                onPressed: () {
                  Navigator.pop(context);
                  launchUrlString(
                    "https://github.com/cyc20050130/venera/releases",
                  );
                },
                child: Text("Update".tl),
              ),
            ],
          );
        },
      );
    } else if (showMessageIfNoUpdate) {
      final context = App.rootNavigatorKey.currentContext;
      if (context != null && context.mounted) {
        context.showMessage(message: "No new version available".tl);
      }
    }
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
  }
}

/// return true if version1 > version2
@visibleForTesting
bool isNewerAppVersion(String version1, String version2) {
  var v1 = version1.split(".");
  var v2 = version2.split(".");
  final length = v1.length > v2.length ? v1.length : v2.length;
  for (var i = 0; i < length; i++) {
    final n1 = i < v1.length ? int.tryParse(v1[i]) : 0;
    final n2 = i < v2.length ? int.tryParse(v2[i]) : 0;
    if (n1 == null || n2 == null) {
      return false;
    }
    if (n1 > n2) {
      return true;
    }
    if (n1 < n2) {
      return false;
    }
  }
  return false;
}
