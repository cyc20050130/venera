# Venera 性能稳定性审计

日期：2026-06-03

分支：`codex/app-performance-stability`

工作区：`D:\code\projects\venera\.worktrees\codex-app-performance-stability`

## 摘要

本轮优先处理 Android/移动端的启动、久置恢复、阅读器滚动、图片加载、
缓存维护和后台任务抢占问题。不改变用户可见设置、漫画源 JS API、收藏/历史
数据格式、下载目录结构或同步协议。

## 已落地

- 生命周期处理现在会节流下载任务 flush，避免重复隐私遮罩/鉴权页 push，
  并检查 mounted/root navigator 状态；恢复时会向全局启动任务和阅读器图片
  调度广播安静窗口。
- 阅读器图片调度现在会在 pause/resume 时取消非可见预取，在恢复安静窗口内
  延后低优先级预取，跨帧批量执行 `precacheImage`/predownload，记录
  precache 失败，并把目标图片页码传给自定义图片处理。
- 共享图片组件和 `LoadingState` 会忽略 dispose 后到达的异步 stream/load
  回调，避免 late image frame、chunk、error 或 deferred `onDataLoaded`
  触发 setState-after-dispose。
- 启动、缓存和后台任务会等首个可交互界面与恢复安静窗口结束后再运行。
  `CacheManager` 不再构造时立即做初始维护，而是由 bootstrap 显式调度。
- WebDAV 恢复下载会排队到交互安静窗口之后，不再在 app resume 或
  `DataSync` 构造时立即开跑。
- headless 初始化现在复用 `BootstrapController`，GUI 与 headless 共享 phase
  顺序、网络 guard、漫画源加载、SAF worker、配置迁移和启动 hook。
- 网络缓存 HEAD 校验失败时会清掉过期内存缓存并回退到原始 GET，不再把弱网
  或恢复瞬间的校验失败暴露给用户操作。
- 新增 `tools/android_profile_harness.ps1`，固定采集 Android `adb logcat`、
  `[perf]` 日志、crash marker、`dumpsys gfxinfo/framestats` 和 `meminfo`。
  无 adb 或无 Android 设备时会写出 `summary.md` 并以退出码 0 跳过，便于
  之后接上真机/模拟器复用。
- 封面和详情页缩略图现在会在已知显示尺寸的 surface 上传递
  `cacheWidth`/`cacheHeight`，降低封面列表、详情封面和预览缩略图在高
  DPR Android 设备上的原尺寸解码与 ImageCache 压力。reader 大图仍沿用
  现有阅读器专用策略。
- `prevent-parallel` 请求去重从仅按 `path` 等待升级为 GET-only 的
  normalized request key，纳入 normalized URI、query 和关键 header，避免
  不同 query/header 被误等待，同时不改变 POST、下载或离线保存语义。
- `LocalManager.flushCurrentDownloadingTasks()` 会合并同一时间段的 in-flight
  flush，降低恢复瞬间生命周期回调重复触发时的快照写盘抢占。

## 验证

- `flutter analyze --no-pub`
- `flutter test --no-pub test/reader_image_scheduling_test.dart test/reader_image_cache_strategy_test.dart test/reader_loading_test.dart test/network_init_guard_test.dart test/bootstrap_hooks_test.dart test/app_lifecycle_stability_test.dart test/loading_state_stability_test.dart test/animated_image_stability_test.dart test/home_page_test.dart test/cache_manager_test.dart test/network_cache_test.dart test/local_manager_test.dart test/comic_cover_hero_transition_test.dart --reporter=compact`
- `flutter build apk --debug --no-pub`
- `tools\android_profile_harness.ps1 -DurationSeconds 1 -ResumeIdleSeconds 1 -SkipResumeWait`
  在无 Android adb 设备时按预期跳过，并生成
  `build\android-profile\20260603-233459\summary.md`。

Debug APK 输出位置：

- `build\app\outputs\flutter-apk\app-debug.apk`
- `build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk`
- `build\app\outputs\flutter-apk\app-armeabi-v7a-debug.apk`
- `build\app\outputs\flutter-apk\app-x86_64-debug.apk`

第一次 debug build 超过外层命令超时时间，但后台构建最终生成了 APK；随后 warm
rerun 以退出码 0 成功完成。

## 仍需实机验证

本轮没有连接 Android 设备或模拟器。`flutter devices` 只检测到 Windows、
Chrome 和 Edge，因此 DevTools frame timeline、`adb logcat` 和后台 10 分钟后
恢复的 profile trace 仍需在真实 Android 设备/模拟器上补采。

可复用采集入口：

```powershell
.\tools\android_profile_harness.ps1 `
  -Package com.github.wgh136.venera `
  -DurationSeconds 180 `
  -ResumeIdleSeconds 600
```

建议采集场景：

- 冷启动到首页可交互。
- 首页、探索、收藏列表滚动。
- 漫画详情页打开，以及 stale cache 命中后的详情页滚动。
- 阅读器连续/画廊模式滚动 2-3 分钟。
- 后台 10 分钟后恢复，立即翻页、收藏、保存图片、切章节。
- 下载/同步任务运行时恢复并导航。

## 下一轮候选

- 继续瘦身大文件页面级 rebuild：`components/comic.dart`、
  `pages/favorites/local_favorites_page.dart`、`pages/search_page.dart`、
  `pages/explore_page.dart`。
- 有 Android 设备后用 profile harness 对比封面/缩略图 decode-size hint 前后
  的 frame timeline、ImageCache/graphics 内存和 logcat `[perf]` 标记。
- 继续审计长时间下载、导出、导入流程的 pause/resume 取消语义，覆盖当前下载
  flush 节流之外的场景。

## 2026-06-04 追加全项目审查

本轮继续不限于未提交变更做静态巡检与验证，重点看强制 ancestor/context unwrap、
dispose 顺序、异步回包、reader controller 和 headless 参数边界。

新增修复：

- `FlyoutController` 在 `Flyout` dispose 或 controller 切换时解绑旧 `show`
  回调；脱树后再调用 `show()` 变为 no-op，避免旧 context 被弹层触发。
- `GlobalState` 注册前会去重，查找时跳过 unmounted state，并在
  `AutomaticGlobalState.dispose()` 里先 unregister 再 `super.dispose()`。
- 分组章节页的 `TabController` 不再在每次 `didChangeDependencies()` 中重复
  创建；章节组数量变化时才替换，旧 controller/listener 会释放。
- 多处 `dispose()` 顺序改为先移除 listener/observer/controller，再调用
  `super.dispose()`。
- reader 翻页动画、连续滚动动画、PageController/ItemScrollController 跳页补
  attached/mounted/error guard，避免切章、恢复或页面销毁后动画 Future 回包造成
  计数漂移或访问已释放 controller。
- 收藏/详情页的新建文件夹回包、漫画卡片屏蔽词回包、下载任务 listener 回包补
  mounted/nullable guard。
- headless `updatesubscribe --update-comic-by-id-type` 对缺参和目标漫画不存在返回
  JSON error，不再用 `firstWhere` 直接抛异常；Linux/macOS 下 `HOME` 缺失时也不再
  强制 `!`。

新增测试：

- `test/controller_lifecycle_stability_test.dart` 覆盖 `FlyoutController` 脱树后调用
  和 `GlobalState` 不返回已卸载 state。

追加验证：

- `flutter analyze --no-pub`
- 聚焦稳定性/缓存/reader 测试集，包含新增
  `test/controller_lifecycle_stability_test.dart`
- `flutter test --no-pub --reporter=compact`，全量 130 个断言通过
- `flutter build apk --debug --no-pub`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error

本轮全量测试前，worktree 缺少被忽略的
`build\test-zip\shared\zip_flutter.dll`，导致 `test_native_paths_test.dart` 与
`history_test.dart` setUp 红灯；已从主仓库本地 build 产物复制到 worktree 的
ignored `build/` 目录后重跑通过。`android/key.properties` 仍只在 debug build
期间临时复制，构建后确认已删除。

## 2026-06-04 继续全项目审查

本轮继续不限于未提交变更做二次巡检，重点看后台任务、下载器、WebView、事件流、
cookie/network 基础设施、loading 对话框和 await 后 UI 回包。

新增修复：

- `FileDownloader` 的 range 分块写盘改为队列串行，替代易漂移的 `_isWriting`
  布尔锁；状态上报 timer 现在由实例持有并在取消/完成/异常时关闭；取消和异常路径会
  关闭文件与 stream，成功完成时仅在 `.download` 状态文件存在时删除。
- `DesktopWebview` 轮询 timer 在 close/onClose/webview 丢失时主动取消；JS
  evaluate 和 JSON 消息解析增加错误日志与空消息保护；菜单复制/浏览器打开 URL 不再
  强制 unwrap 未创建的 controller；导航回调 substring 增加长度和引号判断。
- `showLoadingDialog` 增加内部 `onClosed` hook；JS UI 的 loading controller map
  会在用户取消或 route 关闭时自动清理，避免漫画源脚本 loading 对话框残留引用。
- `HistoryPage._refreshAllHistories()` 的取消路径改为 `try/finally` 关闭 loading
  controller，避免批量刷新取消后遮罩残留。
- `Channel` 满队列 backpressure 改为循环等待释放容量；一次 `pop` 不再同时放行多个
  blocked producer 导致队列超过容量上限。
- `CookieJarSql` 同名 cookie 选择不再假设 domain 非空，并新增显式 `close()` 释放
  sqlite 句柄；host-specific cookie 仍优先于父域 cookie。
- 文本分享入口从永久 `await for` 改成 idempotent `StreamSubscription`，流错误进入
  日志，行为与 app links 入口对齐。
- 首页图片收藏统计切换、漫画详情首帧 post-frame、网络代理设置解析、WebView cookie
  读取补 mounted/null/空字符串 guard。

新增测试：

- `test/channel_test.dart` 覆盖 blocked producer 不会在一次 release 后突破容量。
- `test/loading_state_stability_test.dart` 覆盖 `showLoadingDialog` close 通知只触发一次。
- `test/cookie_jar_test.dart` 覆盖 host-specific cookie 优先级，并复用
  `test_native_paths.dart` 的 sqlite runtime 入口。

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\channel_test.dart test\loading_state_stability_test.dart test\cookie_jar_test.dart --reporter=compact`
- `flutter test --no-pub --reporter=compact`，全量 135 个断言通过
- `flutter build apk --debug --no-pub`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error

Debug build 期间临时从主仓库复制 ignored `android\key.properties` 到 worktree；
构建完成后 finally 删除，并确认 `key.properties present after cleanup: False`。
`pubspec.yaml` / `pubspec.lock` 未因本轮验证产生无关漂移。

## 2026-06-04 再次全项目审查

本轮继续不限于未提交变更做第三轮静态巡检，重点看外部数据解析、同步配置、
下载断点恢复、评论富文本、图片收藏筛选、生命周期 root context 和 isolate
关闭路径。

新增修复：

- `FileDownloader` 的 `.download` 断点状态解析改为可验证的容错 parser；坏行、
  空洞、重叠、越界或 downloadedBytes 超块大小时丢弃断点并重建任务，不再
  `int.parse` 直接崩溃。断点状态已显示完成时会清理状态文件并发出
  `isFinished=true`。HEAD 缺少或返回非法 `content-length` 时不再误判为
  0 字节完成，而是返回明确错误。
- `App.locale` 对异常同步/配置值容错；只接受已支持语言值，非字符串、空值或
  未知值回退系统语言，避免启动构造 locale 时越界。
- WebDAV 配置解析统一为 `normalizeWebDavConfig()`；同步启用判断、上传/下载和
  设置页初始化共用同一规则，脏列表或非字符串项不会在打开设置页时崩溃。
  `disableSyncFields` 和 `deviceId` 也增加非字符串规范化。
- 旧版 image favorite 导入 id 改为按第一个 `-` 拆分，保留漫画 id 内部连字符；
  无法拆分的旧记录记录 warning 后跳过，不再中断整批导入。
- 旧版 `PageJumpTarget` 字符串解析允许缺 payload 的 `search`/`search:`，
  category 参数按第一个 `@` 拆分，避免 source 旧配置缺分隔符或参数含 `@`
  时越界/截断。
- 评论富文本解析遇到 `<   >` / `</   >` 这类空标签名时按普通文本处理，
  不再访问空 `splits[0]`。
- 图片收藏 `TimeRange` 序列化修正为 `millisecondsSinceEpoch`，并允许
  `null:<duration>` round-trip；“最近一周/月”等筛选不再恢复成 all。
- `IsolateJsEngine.close()` 改为立即完成 pending task error、关闭 receive port
  并 kill isolate，避免主动关闭时等待卡住的 JS 任务自然结束。
- 生命周期隐私遮罩 builder 改为捕获插入时的颜色值，不再延迟强取
  `App.rootContext`；设置页更新弹窗也改用 nullable root context 检查。

## 2026-06-04 第四轮全项目审查

本轮继续不限于未提交变更做静态巡检与验证，重点看缓存维护生命周期、历史异步写入、
分块下载边界、分类页异步回包和 reader 手势延迟回调。

新增修复：

- `CacheManager` 的初始维护和普通维护改为可取消 `Timer`，`close()` 会取消延迟任务
  并设置 closed guard，避免旧 manager 关闭 SQLite 后延迟维护醒来访问已释放 DB。
- `HistoryManager.addHistoryAsync()` 用 `try/finally` 释放 `_haveAsyncTask`，异步写入
  失败或 DB 已关闭时不会把后续历史写入永久卡在等待循环。
- `FileDownloader` 的 Range 请求改为 `Accept-Encoding: identity`，并校验分块请求
  必须拿到 `206`；仅整文件单块可接受 `200`。单个网络 chunk 超过当前 block 剩余
  字节时直接报错，避免服务端忽略 Range 时写坏文件还误判完成。
- `CategoryComicsPage` 的动态 options 加载增加 request generation 和 mounted guard，
  dispose 或旧请求回包不会再触发 `setState`。
- reader 手势层释放 `TapGestureRecognizer`，dispose 时断开 scaffold 对手势 state 的引用；
  长按/双击延迟回调以及复制/保存图片异步回包增加 mounted/null guard。

新增测试：

- `test/category_comics_page_test.dart` 覆盖分类 options 回包只应用 live latest request。
- `test/cache_manager_test.dart` 增加 close 后 scheduled maintenance 不再运行。
- `test/history_test.dart` 增加失败 async history write 后锁释放并可继续写入。
- `test/file_downloader_status_test.dart` 增加 Range 状态码与 block 边界校验。
- `test/reader_gesture_logic_test.dart` 增加 delayed gesture callback mounted/token guard。
- `tools/android_profile_harness.ps1` 允许 adb 空输出写入文件；`logcat -c` 和
  `am force-stop` 这类正常空输出步骤不再被误标为 failed。

追加验证：

- `flutter analyze --no-pub`
- 聚焦稳定性/缓存/reader 测试集，75 个测试通过
- `flutter test --no-pub --reporter=compact`，全量 165 个测试通过
- `flutter build apk --debug --no-pub`
- `tools\android_profile_harness.ps1 -DurationSeconds 1 -ResumeIdleSeconds 1 -SkipResumeWait`
  成功采集本地 emulator evidence，summary 位于
  `build\android-profile\20260604-142722\summary.md`。

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认 worktree 内
`android\key.properties` 不存在。

新增测试：

- `test/file_downloader_status_test.dart`
- `test/app_locale_test.dart`
- `test/data_sync_config_test.dart`
- `test/appdata_normalization_test.dart`
- `test/data_import_compat_test.dart`
- `test/comment_loading_stability_test.dart` 新增空标签 widget 用例
- `test/page_jump_target_test.dart`
- `test/image_favorites_filter_test.dart`

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub --reporter=compact`，全量 156 个断言通过
- `flutter build apk --debug --no-pub`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error

Debug build 期间继续临时从主仓库复制 ignored `android\key.properties` 到
worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第五轮全项目审查

本轮继续不限于未提交变更做静态巡检，重点看外部数据解析、本地/旧库导入、
分类/搜索/ranking 源配置边界、关注更新时间排序和本地库 ID 分配。

新增修复：

- 标签翻译复数归一化修正为真正写回 `replaceLast('s', '')` 结果；
  `female:teachers` 这类命名空间标签可正确归一到 `teacher`。
- OpenCC 简繁检测移除只允许 `"监禁"` 的硬编码，并修正 CRLF/右侧空白导致
  `assets/opencc.txt` 映射被跳过的问题。
- 随机分类起点修正 off-by-one；空列表或 `randomNumber <= 0` 直接返回空结果。
- CBZ/本地目录导入的图片扩展名判断改为大小写不敏感；本地目录漫画只有章节目录、
  根目录没有封面图时，使用首个章节图片作为封面，不再提前判 invalid。
- EhViewer 导入对 `DIRNAME`、标题、时间戳和分类位做容错；分类位越界/非法时跳过
  标签，不再因 `log(category)` 越界崩溃；标签筛选 SQL 改为参数化。
- 漫画源 semver 比较对缺失/非数字核心段按 0 处理；class 名提取允许缩进声明。
- `Appdata` 同步/加载对非字符串 setting key 和异常 `searchHistory` 容错，只保留
  非空字符串历史项。
- 关注更新页更新时间比较抽成纯函数，空值/非法值排到最后，日期按新到旧稳定排序。
- 搜索页 multi-select option 默认值容错解析；非法 JSON、非列表或混合类型按空选择
  处理，点击后写回合法 JSON。
- 分类页 options 默认值归一化：空 options 不再 `keys.first` 崩溃，动态 options
  变化后旧值失效会回退到当前默认值。
- `LocalManager.findValidId()` 对旧库混入非数字本地 ID 使用 `tryParse`，避免下一次
  注册本地漫画时崩溃。
- Ranking 页空 options 进入错误态展示，不再初始化时 `keys.first` 崩溃。

新增/扩展测试：

- `test/tags_translation_test.dart`
- `test/opencc_test.dart`
- `test/category_random_test.dart`
- `test/cbz_import_test.dart`
- `test/comic_source_semver_test.dart`
- `test/import_comic_test.dart`
- `test/appdata_normalization_test.dart`
- `test/follow_updates_test.dart`
- `test/search_options_test.dart`
- `test/category_comics_page_test.dart`
- `test/local_manager_test.dart`
- `test/ranking_page_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 新增聚焦测试集全部通过
- `flutter test --no-pub --reporter=json`，`success=True`
- `flutter test --no-pub --reporter=compact`，全量 184 个测试通过
- `flutter build apk --debug --no-pub`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error

本轮 `pubspec.lock` 无 diff。Debug build 期间继续临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认 worktree 内
`android\key.properties` 不存在。

## 2026-06-04 第六轮全项目审查

本轮继续不限于未提交变更做外部数据入口巡检，重点看 Pica 旧数据、用户导入收藏
JSON、远端漫画源列表和模型 `fromJson` 强制类型转换。

新增修复：

- Pica 旧数据导入增加 source key、folder sync JSON、legacy type、tags 和整数
  字段归一化；坏 `folder_sync` 行、坏收藏行和坏 history/image favorite 行会跳过
  或回退默认值，不再拖垮整批导入。
- Pica `htmanga` 迁移到 `wnacg` 的逻辑抽成纯函数；`sync_data.folderId` 只接受
  有效字符串，非法 JSON/非对象/非字符串 folderId 直接跳过。
- `FavoriteItem.fromJson()` 支持字符串 type、混合 tags 过滤和空 author/cover 容错；
  缺少 id/name/type 仍作为无效收藏项记录并跳过。
- 远端漫画源列表解析抽成 `parseComicSourceListPayload()`；自动更新检查遇到非列表
  payload 返回 `-1`，列表弹窗只接受包含 `key/name/version/fileName` 的有效项，
  坏行跳过，非字符串 description/url 不再进入 UI。

新增/扩展测试：

- `test/data_import_compat_test.dart`
- `test/favorite_item_test.dart`
- `test/comic_source_list_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 新增聚焦测试集全部通过

## 2026-06-04 第七轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看漫画源模型、历史/图片收藏
DB 行、本地漫画旧库、下载任务快照和同步设置类型污染。

新增修复：

- 漫画源模型 `Comment`、`Comic`、`ComicDetails`、`ArchiveInfo`、`ComicChapters`
  增加内部归一化 helper；混合数字/字符串字段、缺失 tags、坏 recommend/comments
  项、非字符串章节 key/value 和坏 PageJumpTarget attributes 不再让页面解析崩溃。
- `LocalComic.fromRow()` 对旧库/损坏 DB 行的 tags、chapters、downloadedChapters、
  created_at 和标量字段做容错，避免单条本地库脏数据拖垮本地列表。
- `History.fromMap()` / `History.fromRow()` 统一支持字符串/数字/null 字段，
  `readEpisode` 支持列表、逗号串和旧 JSON 串，修复旧 Pica 导入数字章节集可能触发
  类型错误的问题。
- 图片收藏表改为按行容错；坏 `image_favorites_ep` 行只跳过，不再让
  `ImageFavoriteManager.getAll()` 返回空列表；空图片章节不再访问 `imageFavorites[0]`。
- 下载任务快照恢复改为逐条恢复，坏任务跳过并清理快照，正常任务不再因为同一文件中
  的坏项丢失。
- `Settings.stringList()` 统一归一化字符串列表设置；搜索、收藏侧栏、分类/探索、
  多页筛选、评论/关键词屏蔽和源码管理页不再直接 `as List`。
- 代理、DNS override 和源码列表 URL 设置读取增加类型保护，坏同步设置不会在网络层
  或设置弹窗打开时直接抛异常。

新增/扩展测试：

- `test/comic_source_models_test.dart`
- `test/local_manager_test.dart`
- `test/history_test.dart`
- `test/appdata_normalization_test.dart`

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\appdata_normalization_test.dart test\history_test.dart test\local_manager_test.dart test\comic_source_models_test.dart test\search_options_test.dart test\home_page_test.dart --reporter=compact`
- `flutter test --no-pub --reporter=compact`，全量 204 个测试通过
- `flutter build apk --debug --no-pub`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error

本轮 `pubspec.lock` 无 diff。Debug build 期间继续临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第八轮全项目审查

本轮继续不限于未提交变更做全项目外部数据边界审查，重点看同步设置污染、
缓存/SQLite 坏行、漫画源动态配置、导入文件元数据、JS bridge message 和分页
`subData` 类型漂移。

新增修复：

- `Settings` 的 comic/device specific reader settings 增加嵌套 map 恢复 helper；
  同步或旧数据把嵌套值写成字符串/窄类型 map 时，后续写入会替换为真正
  `Map<String, dynamic>`，不再在恢复设置时抛类型错误。
- `CookieJarSql` 按行解析 SQLite cookie；坏 `expires` 或坏字段行会跳过并记录
  warning，正常 cookie 继续生成请求头。
- `CacheManager.findCache()`、初始维护、过期清理和删除路径统一校验 cache DB 行；
  坏 `dir/name/expires/key` 行会删除或跳过，不再影响图片/缩略图缓存命中。
- 漫画源 `settings`、动态 settings、translation、thumbnail loading config、
  link handler 和 source settings UI 增加归一化；坏 options/title/default/validator
  不再让源码设置页或缩略图加载崩溃。
- `MultiPageLoadingState` 重置时清空旧 `_maxPage`，并接受数字字符串/num
  `subData`；评论页 maxPage、缩略图 next cursor、收藏文件夹 `subData` 和 mixed
  explore 列表也做类型归一化。
- CBZ metadata、EhViewer/Pica 导入标签、导入 isolate 复制参数和 JS bridge
  headers/extra/cookies 增加外部数据容错；坏项跳过，正常项继续导入/请求。

新增/扩展测试：

- `test/cookie_jar_test.dart`
- `test/cache_manager_test.dart`
- `test/comic_source_list_test.dart`
- `test/loading_state_stability_test.dart`
- `test/comic_page_favorite_status_test.dart`
- `test/comment_loading_stability_test.dart`
- `test/comic_cover_hero_transition_test.dart`
- `test/cbz_import_test.dart`
- `test/reader_image_cache_strategy_test.dart`
- `test/explore_page_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮新增/相关聚焦测试全部通过
- `flutter test --no-pub --reporter=compact`，全量 222 个测试通过
- `flutter build apk --debug --no-pub`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error

本轮 `pubspec.lock` 无 diff。Debug build 期间继续临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第九轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看久置恢复后高频操作会触发的
SQLite isolate 访问、PageStorage 旧状态、漫画源/图片加载外部配置和 WebView
JS 返回值类型漂移。

新增修复：

- `LocalFavoritesManager.getFolderComicsAsync()` / `getAllComicsAsync()` 和
  `HistoryManager.addHistoryAsync()` 不再把主 isolate 的 sqlite native handle
  或 handle address 传进 worker isolate；改为传 DB path，在 worker isolate 内
  open/dispose，避免恢复后历史写入/收藏读取击中跨 isolate native 指针风险。
- `HistoryManager` 迁移、缓存刷新和清理未收藏历史时复用 row decoder；旧库/坏行的
  `type/id/source_key/count` 不再通过强 cast 触发启动或清理流程崩溃。
- Reader 原图 loading config 增加 `normalizeComicImageLoadingConfig()`，和缩略图
  config 一样清洗 url/method/headers；`onResponse` 异常路径也确保释放 JS 回调。
- 漫画源设置 UI 对 `source.data['settings']` 做运行时 map 归一化；同步/导入污染成
  非 Map 时恢复为空 Map，避免打开源设置页直接崩溃。
- 本地收藏批量移动/复制改用当前 `_LocalFavoritesPage.widget.folder`，并禁止从
  “全部本地收藏”虚拟文件夹执行 move，避免把虚拟 label 当真实表名。
- `Cloudflare` WebView challenge 检测不再把 `evaluateJavascript()` 结果强转
  String；null/非字符串结果会转为空字符串或文本继续判断。
- `ExplorePage` 和通用 `ComicList` 的 PageStorage 恢复改为纯 helper 过滤旧状态；
  坏 `loading/page/data/parts/nextUrl` 不再在依赖变更或页面恢复时触发 TypeError。
- `AppTabBar` 的 PageStorage index 改为安全解析；坏 tab index 会被丢弃。
- Explore parser 的 single/multi/mixed 返回值改为过滤式解析，坏漫画项/坏分区项
  跳过，正常项继续展示；archive download URL 返回空或坏值时返回 `Res.error`。

新增/扩展测试：

- `test/appbar_state_test.dart`
- `test/comic_list_state_test.dart`
- `test/explore_page_test.dart`
- `test/comic_source_models_test.dart`
- `test/comic_source_list_test.dart`
- `test/reader_image_cache_strategy_test.dart`
- `test/favorites_manager_test.dart`
- `test/history_test.dart`
- `test/local_manager_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试 64 项通过
- `flutter test --no-pub --reporter=compact`，全量 232 个测试通过
- `flutter build apk --debug --no-pub`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第十轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看 fire-and-forget Future、
`async void`、Timer 回调和久置恢复后自动触发的后台任务。核心目标是让恢复期的
保存、预热、鉴权导航、下载任务和 WebView 回调失败只进入日志，不再变成全局
未处理异步异常。

新增修复：

- `LocalManager` 新增下载任务快照 guarded background save/flush helper；下载任务
  pause/error/complete/remove/move、生命周期 flush、restore cleanup 和 dispose
  都走带日志的后台保存路径。
- `ImagesDownloadTask.resume()` 和 `ArchiveDownloadTask.resume()` 增加外层 guard；
  网络、目录创建、下载快照写入、封面写入和归档解压的漏网异常会设置任务错误态
  并记录日志，不再从 `async void` 逃逸。
- `Appdata.writeImplicitData()` 改为可等待 Future 且内部记录写入失败；新增
  `saveDataInBackground()`，把设置页、首页、搜索、漫画源页等裸
  `appdata.saveData()` 调用改为显式后台保存。
- `ComicSource.saveData()` 用 `finally` 复位 `_isSaving`，新增
  `saveDataInBackground()`；JS 回调、parser 和源设置 UI 的非等待保存不再泄漏
  Future 错误。
- Reader 自动后台任务增加异常 guard：图片缓存大小检测、下一章预热、重试预热和
  历史写入失败只记录日志，不影响阅读器交互。
- `ImageDownloader` 共享流取消时捕获 `StreamIterator.cancel()` 失败，确保 controller
  清理继续完成。
- 启动 `_run()`、生命周期 AuthPage push、详情页收藏状态后台刷新、首页延迟同步下载、
  桌面窗口位置轮询、DataSync 关闭等待弹窗和 Cloudflare WebView challenge 回调增加
  异常记录与吞并。

新增/扩展测试：

- `test/appdata_normalization_test.dart`
- `test/local_manager_test.dart`
- `test/bootstrap_hooks_test.dart`
- `test/follow_updates_test.dart`
- `test/comic_page_favorite_status_test.dart`
- `test/home_page_test.dart`
- `test/reader_image_cache_strategy_test.dart`
- `test/reader_image_scheduling_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试 62 项通过
- `flutter test --no-pub --reporter=compact`，全量 236 个测试通过
- `flutter build apk --debug --no-pub`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第十一轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看外部导入数据、动态 SQL
表名边界、外部 URL 解析、归档/本地导入路径冲突，以及网络请求去重在 malformed
输入下是否会比真实请求更脆。

新增修复：

- `LocalFavoritesManager` 的收藏夹名校验扩展到保留表名；创建、重命名、旧库表名扫描和
  JSON 导入都会跳过或归一化危险名称，避免外部收藏夹名进入 raw SQL 表名位置。
- Pica 数据导入只读取通过收藏夹名校验的外部 SQLite 表；`folder_sync` 只链接实际可导入
  的安全表名，导入 appdata 时要求 JSON 根节点为对象，坏 JSON 会记录日志并跳过。
- `utils/app_links.dart` 新增安全 URL 解析：先过滤 URL 形态和 malformed percent
  encoding，再交给 `Uri.tryParse()`；搜索页和富文本评论不再直接 `Uri.parse()` 外部文本。
- WebView desktop cookie 域名匹配对坏 URL 返回 false，不再让 cookie 回收路径抛出异常。
- `AppDio` 的 `prevent-parallel` request key 构造遇到坏 path/baseUrl 时返回 null，
  让请求继续走正常网络路径，不因为去重 key 解析提前失败。
- CBZ 导入用 `findValidDirectoryName()` 生成目标目录，避免不同标题清洗后撞到同一目录并
  混写文件。
- 本地漫画导入复制时，已有目标目录的备份路径改为目标父目录下的
  `<name>_old`，避免把完整路径当文件名清洗后重命名到错误位置。

新增/扩展测试：

- `test/favorites_manager_test.dart`
- `test/data_import_compat_test.dart`
- `test/app_links_test.dart`
- `test/network_init_guard_test.dart`
- `test/cbz_import_test.dart`
- `test/import_comic_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试 28 项通过
- `flutter test --no-pub --reporter=compact`，全量 244 个测试通过
- `flutter build apk --debug --no-pub`

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第十二轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看 WebDAV 远端文件名、
WebView/JS 回调类型、漫画源登录 cookie 保存 URL，以及下载任务恢复路径。

新增修复：

- `DataSync` 下载远端 `.venera` 时不再把 WebDAV 返回的 `file.name` 直接拼到本地
  cache path；新增本地缓存文件名清洗和远端文件名可用性判断，路径型远端名字不会进入
  WebDAV read/remove 或本地写入路径。
- `DataSync` 上传后的旧备份清理不再对远端文件名做 `name!` 强制解包；只处理可用的
  `.venera` 文件名，空名/路径型名字会被跳过。
- `WebviewExtension.getUA()` 对 JS 返回的 UA 做平衡引号归一化；单个引号或非字符串不会
  触发 range error。
- `WebviewExtension.getCookies()` 捕获插件 URL/cookie 读取失败并返回空列表，避免登录和
  Cloudflare 检查路径被插件异常打断。
- 漫画源登录 WebView 保存 cookie 前校验导航 URL 必须有 host；`about:blank`、空串等
  回调不会进入 cookie jar。
- `DownloadTask.fromJson()` 增加 `ArchiveDownloadTask` 分发；归档下载任务重启后可恢复。
- `ArchiveDownloadTask.fromJson()` 改为容错解析，缺 archive URL、坏 comic、缺 source 的
  快照会跳过，不再拖垮有效下载任务恢复。

新增/扩展测试：

- `test/data_sync_config_test.dart`
- `test/webview_helpers_test.dart`
- `test/comic_source_list_test.dart`
- `test/local_manager_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试 26 项通过
- `flutter test --no-pub --reporter=compact`，全量 249 个测试通过
- `flutter build apk --debug --no-pub`

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第十三轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看阅读器保存/分享当前图片、
图片 cache 读取、以及漫画源 JS 返回列表的旧式强解析路径。

新增修复：

- Reader 选择当前图片新增索引归一化；overlay 未命中图片、`indexOf == -1`、空图片列表或
  当前页越界时返回 null，不再进入 `images[-1]`。
- Reader 保存/分享当前图片读取本地文件和 cache 时增加 guard；远端图片 cache 未命中或
  文件读取失败只记录日志并取消本次操作，不再抛出到 UI。
- 漫画源 parser 新增 `normalizeSourceComicListResult()`，统一处理 JS 返回的漫画列表根对象。
- category/ranking/search/favorites 的 `res["comics"].length -> Comic.fromJson`
  旧入口改用过滤式解析；坏根对象返回 `Res.error`，坏漫画项跳过，正常项继续展示，
  `maxPage/next` subData 保持兼容。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart`
- `test/comic_source_models_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试 45 项通过
- `flutter test --no-pub --reporter=compact`，全量 251 个测试通过
- `flutter build apk --debug --no-pub`

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第十四轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看网络/Cloudflare 半初始化、
阅读器恢复瞬间手势、外部文件 URI、漫画源远端 JSON，以及图片响应 body 边界。

新增修复：

- 图片缩略图和 reader 图片下载不再在空响应 body 后继续访问 `req.data!`；响应
  `contentLength` 统一归一化，`-1`/null 不进入进度总量。
- Cloudflare challenge URL 增加 http/https、host 和 malformed percent encoding 校验；
  Linux 桌面保存 cookie 时 cookie jar 缺失会记录并跳过，不再强制解包崩溃。
- Reader gallery/continuous 长按缩放、双击缩放和长按拖动不再假定
  `PhotoViewController` 与 `getInitialScale` 已就绪；恢复或切页瞬间控制器未挂载时
  本次手势直接跳过。
- 本地 `file://` 路径 fallback 解码改为安全解码；坏 `%` 编码会保留原始路径，不再在
  fallback 中再次抛出。
- 漫画源列表远端响应新增安全 JSON 解码 helper；坏 JSON、空响应或非列表根对象返回
  现有错误路径，不再抛到后台更新检查。
- 漫画源登录 cookie 保存 URL 也过滤 malformed percent encoding。
- `AppDio` 在 App 已初始化但 cookie jar 尚未创建时跳过 cookie interceptor，其余缓存、
  Cloudflare 和日志 interceptor 继续挂载，避免半初始化恢复路径被 `instance!` 打断。

新增/扩展测试：

- `test/cloudflare_test.dart`
- `test/reader_image_cache_strategy_test.dart`
- `test/reader_gesture_logic_test.dart`
- `test/local_file_uri_test.dart`
- `test/comic_source_list_test.dart`
- `test/network_init_guard_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试 44 项通过
- `flutter test --no-pub --reporter=compact`，全量 259 个测试通过
- `flutter build apk --debug --no-pub`

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第十五轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看共享图片组件的异步 stream
回调、reader 图片 stream 切换、headless CLI 输出，以及 Desktop WebView message 解析。

新增修复：

- `AnimatedImage` 的 image stream listener 捕获 stream key；dispose 或图片源切换后迟到的
  frame/chunk/error 回调会被丢弃，迟到 `ImageInfo` 会立即释放，不再覆盖当前图片或
  setState 到错误状态。
- Reader `ComicImage` 同步增加 stream-key guard，章节切换、页面复用或恢复瞬间旧图片流
  回调不会写回当前 reader image 状态。
- Headless `updatesubscribe` 的最终 updated comics JSON 输出改为安全解码；坏 JSON 会输出
  error + 空列表，不再让 CLI 进程直接抛异常退出。
- Desktop WebView 的 `document_created` message 解析抽成纯函数，只接受完整
  `id/data/title` 结构；坏 JSON、空 data、非字符串 title 会被静默跳过，避免 timer 反复
  记录解析异常。

新增/扩展测试：

- `test/animated_image_stability_test.dart`
- `test/reader_gesture_logic_test.dart`
- `test/headless_test.dart`
- `test/webview_helpers_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试 19 项通过
- `flutter test --no-pub --reporter=compact`，全量 264 个测试通过
- `flutter build apk --debug --no-pub`

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第十六轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看下载断点恢复、图片收藏/封面缓存、
通用图片 CacheManager 空文件、appdata 启动解析，以及漫画源页面跳转边界。

新增修复：

- 分块文件下载读取 `ResponseBody` 时改为本地 body guard；空响应体给出明确错误，不再在
  后续 stream 读取中依赖 `res.data!`。
- 下载任务 snapshot 恢复会归一化负数进度，并丢弃 `_chapter/_index` 越界的损坏行，避免
  久置恢复后下载列表继续运行时触发 `RangeError`。
- 图片收藏 provider 统一写入/删除 cache key；删除收藏能清掉对应磁盘缓存，空缓存文件不再
  作为命中返回。
- 图片收藏本地回退遇到缺失/空本地图或页码越界时返回可控错误/空结果，允许继续走缓存或网络。
- 本地收藏封面缓存读取新增空文件清理；下载失败留下的空文件不会毒化后续封面加载。
- 历史封面读取本地下载封面时只接受存在且非空的文件；本地封面缺失时继续尝试详情封面。
- `implicitData.json` 启动解析只接受 Map 根对象并统一 key 为字符串，避免合法但非对象 JSON
  进入运行期。
- 通用 thumbnail/reader 图片 cache 命中会丢弃并删除空缓存；网络/处理结果为空时不再写入
  CacheManager。
- category PageJumpTarget 在源已删除、未加载或无 categoryData 时记录错误并跳过导航，不再
  强制解包导致点击旧标签闪退。

新增/扩展测试：

- `test/local_manager_test.dart`
- `test/reader_image_cache_strategy_test.dart`
- `test/appdata_normalization_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试通过
- `flutter test --no-pub --reporter=compact`，全量 273 个测试通过
- `flutter build apk --debug --no-pub`

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第十七轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看 EPUB/PDF 导出、本地目录导入、
CBZ 相邻逻辑和底层文件选择/IO helper。

新增修复：

- EPUB 导出新增 XML/XHTML 转义 helper；标题、作者、章节名和图片 alt/src 文本不再直接插入
  XML，避免 `&`、`<`、引号等字符生成损坏 EPUB。
- EPUB 从本地漫画导出时，下载章节列表里存在已失效 chapter id 会用 chapter id 作为章节名兜底，
  不再强制解包 `comic.chapters![chapter]!`。
- PDF 导出新增图片文件过滤 helper；只导出支持的图片扩展，按文件名排除已单独加入的 cover，
  不再把 `metadata.txt` 等非图片送进解码，也避免封面重复页。
- PDF 多章节导出遇到 stale downloaded chapter 目录缺失时跳过该目录，不再同步抛出。
- 本地目录导入只登记含图片的章节目录；空章节目录不会进入 `chapters/downloadedChapters`，
  避免导入后 reader 进入空章节。
- 单文件选择扩展名判断改为大小写不敏感，`.CBZ` / `.ZIP` 这类文件不会被误判非法。

新增/扩展测试：

- `test/epub_export_test.dart`
- `test/pdf_export_test.dart`
- `test/import_comic_test.dart`
- `test/local_file_uri_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试通过
- `flutter test --no-pub --reporter=compact`，全量 277 个测试通过
- `flutter build apk --debug --no-pub`

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第十八轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看 WebDAV 数据同步、
网络收藏导入/删除、工具层初始化、数据导出缺文件兼容，以及 Android 原生事件流回调。

新增修复：

- WebDAV 上传清理远端备份时抽出删除决策；当天旧备份被删除后会从候选列表移除，
  不再因为保留数量裁剪重复删除同一个远端文件，同时会按上限为新备份预留位置。
- `webdavAutoSync` 统一归一化为 bool；同步配置或 implicitData 被坏值污染时，
  DataSync 和 WebDAV 设置弹窗不再把非 bool 当作运行期 bool 使用。
- `OpenCC.init()` 改为幂等初始化；bootstrap 重试或测试重复调用不会因为 `late final`
  二次赋值崩溃，未初始化时转换/检测会安全返回原值或 false。
- 标签翻译读取改为先构建新 map 再整体替换；重复读取或 locale 切换时不会混入旧数据，
  malformed namespace/tag 也会被跳过。
- 网络收藏“移除”入口只在源支持 `addOrDelFavorite` 时显示，底层删除函数也会先检查能力，
  避免源能力变化或旧收藏页点击后空断言闪退。
- 网络收藏从旧到新导入时，超大“全部更新”页数会把起始页夹到 1；坏的本地
  `local_favorites_update_page_num` implicitData 会回退为全部更新。
- App 数据导出只打包实际存在的核心文件；新装、部分迁移或某个 DB 尚未生成时，
  手动导出/WebDAV 上传不会因为可选文件缺失直接失败。
- App links、文本分享和音量键原生事件流增加异步错误兜底与 mounted/空文本检查；
  原生 stream error 或 link handler 异常不会变成未处理 Future/stream 错误。

新增/扩展测试：

- `test/data_sync_config_test.dart`
- `test/network_favorites_page_test.dart`
- `test/data_import_compat_test.dart`
- `test/opencc_test.dart`
- `test/tags_translation_test.dart`
- `test/controller_lifecycle_stability_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试通过
- `flutter test --no-pub --reporter=compact`，全量 287 个测试通过
- `flutter build apk --debug --no-pub`

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第十九轮全项目审查

本轮继续不限于未提交变更做全项目稳定性审查，重点看共享设置组件、
后台跟随更新流、进度弹窗，以及计时器/取消路径触发的恢复期稳定性问题。

新增修复：

- 共享设置组件读取 switch 值时统一走 bool 归一化；同步或导入带来的
  `"true"` / `"false"` / 非 bool 坏值不会再让设置页构建时因为 dynamic 断言或类型错误崩溃。
- 共享 slider 设置读取时统一走 numeric 归一化并夹在 min/max；坏同步值、
  字符串数值、越界值不会再因为 `.toDouble()` 直接命中非 num 而闪退。
- 跟随更新 `updateFolder` stream 增加取消感知和 guarded runner；UI 取消或新检查抢占后，
  producer/consumer 会停止推新任务并安全 close stream，避免取消后继续向已关闭 stream 发进度。
- 跟随更新消费者取消路径改为先 pop 释放有界队列容量，再退出，避免 producer 在队列满载时等待释放。
- 跟随更新进度比例新增 helper；总数为 0、负数、超出上限或非有限值不会传入进度条。
- `LoadingDialogController.setProgress` 统一过滤 `NaN` / `Infinity` 并夹到 `0..1`；
  历史刷新、漫画源更新、本地漫画导出等所有进度弹窗都获得同一层兜底。

新增/扩展测试：

- `test/settings_components_test.dart`
- `test/follow_updates_test.dart`
- `test/loading_state_stability_test.dart`

追加验证：

- `flutter analyze --no-pub`
- 本轮触及面聚焦测试通过
- `flutter test --no-pub --reporter=compact`，全量 291 个测试通过
- `flutter build apk --debug --no-pub`

本轮 `pubspec.lock` 无 diff。Debug build 期间临时从主仓库复制 ignored
`android\key.properties` 到 worktree；构建完成后 finally 删除，并确认
`key.properties present after cleanup: False`。

## 2026-06-04 第二十轮全项目审查

本轮按“只继续修高置信、可验证的 P0/P1 稳定性问题；低优先风险先记录，不无限扫”
收敛范围，重点处理下载/导入导出路径互踩和已有输出文件保护。

新增修复：

- 归档下载任务不再使用固定 `archive_downloading.zip` 和固定 SAF 解压缓存目录；
  每次 resume 生成 operation id，下载临时 zip 与 Android SAF 解压缓存目录都按 operation
  scoped 路径隔离，下载取消、失败或解压失败都会在 `finally` 清理临时 zip。
- CBZ 导入不再共用固定 `cbz_import` 缓存目录，避免两个导入任务互删对方解压内容。
- CBZ 导出不再共用固定 `cbz_export` 缓存目录，避免并发导出互相覆盖 staging 图片。
- CBZ 导出不再在压缩前删除用户已有目标文件；现在先压缩到 operation scoped 临时 CBZ，
  再用 backup/restore 提交，替换失败时恢复旧文件，避免导出失败造成已有 CBZ 丢失。

新增/扩展测试：

- `test/local_manager_test.dart` 覆盖归档下载临时 zip 与 SAF 解压缓存目录按 operation id 隔离。
- `test/cbz_import_test.dart` 覆盖 CBZ 导入/导出缓存路径隔离、临时输出/备份路径，以及
  CBZ 输出提交成功替换、失败恢复旧文件。

本轮暂不强行修复、已记录为下一轮候选：

- `importAppData()` / `importPicaData()` 与历史、收藏、cookie 等生产态 DB 写入之间缺少统一导入互斥；
  已在第二十二轮先补同进程导入会话锁，跨 manager 暂停/恢复仍保留为更大范围候选。
- `FileDownloader` 同一 `savePath` 被重复实例化时仍可能共享目标文件和 `.download` 状态；
  候选修法是按 `savePath` 做进程内单实例注册，或把状态文件提交改成更完整的任务级 key/锁。
- EPUB/PDF/CBZ 这类最终输出到同一路径的并发导出仍应在上层统一加“同输出路径互斥”；
  本轮只修复 CBZ 旧文件丢失和 staging 路径互踩这一硬风险。
- app links / 文本分享全局订阅已有幂等启动和错误兜底，但生产 shutdown/dispose 生命周期还可进一步统一。
- reader quiet period 预取延迟 timer 已有 mounted guard；后续可并入 reader deferred scheduler，降低页面关闭后的短暂悬挂。

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\cbz_import_test.dart test\local_manager_test.dart --reporter=compact`
- `flutter test --no-pub test\cbz_import_test.dart test\local_manager_test.dart test\controller_lifecycle_stability_test.dart --reporter=compact`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error
- 本轮 `pubspec.lock` 无 diff。

## 2026-06-04 第二十一轮全项目审查

本轮继续按“只修高置信、可验证 P0/P1；低优先风险写报告，不无限扫”推进，
从上一轮候选里收敛处理 `FileDownloader` 同目标路径并发写入风险。

新增修复：

- `FileDownloader.start()` 现在会按 normalized `savePath` 做进程内注册；同一目标路径已有
  active download 时，重复启动会立即通过 stream 返回明确 `StateError` 并关闭，不再让两个实例
  同时写同一个目标文件和同一个 `.download` 断点状态文件。
- 下载完成、失败、异常或 stream cancel 触发 `stop()` 后都会释放目标路径注册；取消中的下载仍会
  走已有 cancel token 和文件关闭逻辑，不改变下载目录、任务 JSON 或 `.download` 文件格式。

新增/扩展测试：

- `test/file_downloader_status_test.dart` 覆盖同一 `savePath` 的重复 active download 被拒绝，
  并验证取消首个下载后 registry 会释放。

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\file_downloader_status_test.dart --reporter=compact`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error
- 本轮 `pubspec.lock` 无 diff。

## 2026-06-04 第二十二轮全项目审查

本轮继续从已记录候选中只处理高置信、可验证 P1，收敛处理 appdata/Pica 导入并发修改生产态
DB、收藏与 cookie 状态的风险。

新增修复：

- `importAppData()` 和 `importPicaData()` 现在共用同进程导入会话队列；手动导入、WebDAV 恢复导入、
  Pica 导入如果被同时触发，会串行进入生产态 DB/收藏/cookie 写入区，不再并发删除、rename 或写
  同一批状态文件。
- 导入队列在导入成功、提前返回、异常或失败后都会释放；不改变 `.venera` 数据格式、Pica 导入格式、
  下载目录或同步协议。
- 本轮只做同进程导入互斥。跨 manager 的完整暂停/恢复写入口仍属于更大范围架构候选，没有在本轮
  半截改动。

新增/扩展测试：

- `test/data_import_compat_test.dart` 覆盖导入会话不会重叠，并验证前一个导入抛错后后续导入仍可继续。

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\data_import_compat_test.dart --reporter=compact`
- `flutter test --no-pub test\data_import_compat_test.dart test\file_downloader_status_test.dart --reporter=compact`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error
- 本轮 `pubspec.lock` 无 diff。

## 2026-06-04 第二十三轮全项目审查

本轮继续按“只修高置信、可验证 P0/P1；低优先风险写报告，不无限扫”推进，
从上一轮候选中收敛处理 EPUB/PDF/CBZ 导出到同一最终输出路径时的并发提交风险。

新增修复：

- `lib/utils/io.dart` 新增 normalized 输出路径队列和通用 `commitTemporaryOutputFile`；
  同一目标文件的 temp -> final 提交现在会串行执行，路径归一化会处理 `file://` 与
  Windows 大小写差异，不同目标路径仍可并发。
- CBZ 导出提交复用通用 helper，保留 operation scoped temp/backup 路径和失败恢复旧文件语义。
- PDF 导出在主入口 `createPdfFromComicIsolate()` 按输出路径串行整个 isolate 任务，
  并在 `PdfGenerator.generate()` 内部用通用 helper 提交临时 PDF，避免不同 isolate
  同时 backup/rename 同一最终文件。
- EPUB 导出在主入口 `createEpubWithLocalComic()` 按输出路径串行 isolate 任务，
  底层 `createEpubComic()` 也用通用 helper 提交临时 EPUB，避免同名导出互相覆盖或恢复错位。

新增/扩展测试：

- `test/local_file_uri_test.dart` 覆盖输出路径锁同路径串行、不同路径可并发、
  Windows 路径大小写归一化。
- `test/cbz_import_test.dart` 覆盖 CBZ 输出提交会等待同输出路径锁释放。

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\local_file_uri_test.dart test\cbz_import_test.dart test\pdf_export_test.dart test\epub_export_test.dart --reporter=compact`
- `git diff --check` 只有既有 CRLF 提示，无 whitespace error
- 本轮 `pubspec.lock` 无 diff。

## 2026-06-04 第二十四轮全项目审查

本轮继续审查导出、保存、分享和用户文件交互路径，收敛处理同名临时源文件互踩风险。

新增修复：

- `saveFile(data: filename:)` 不再把待保存数据写入固定 `App.cachePath/filename`；
  现在使用 operation scoped `save_file-<operationId>/<filename>` 临时源文件，
  快速连续保存同名图片、封面或日志时不会互相覆盖源文件。
- 保存流程结束后会在 `finally` 清理 operation scoped 临时目录；传入已有 `file`
  的调用保持原行为，不改变用户选择的保存文件名、下载目录或外部 API。
- Windows `Share.shareFile()` 不再把分享图片写入固定 `App.cachePath/filename`；
  现在使用 operation scoped `share_file-<operationId>/<filename>` 临时源文件，
  分享 Future 结束后清理目录。非 Windows 仍使用 `XFile.fromData`。

新增/扩展测试：

- `test/local_file_uri_test.dart` 覆盖 `saveFile` 数据缓存路径和 Windows 分享缓存路径
  均按 operation id 隔离。

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\local_file_uri_test.dart test\cbz_import_test.dart test\pdf_export_test.dart test\epub_export_test.dart --reporter=compact`
- 本轮 `pubspec.lock` 无 diff。

## 2026-06-04 第二十五轮全项目审查

本轮继续审查本地漫画导入与目录拷贝路径，收敛处理同批导入中源目录 basename
相同导致的目标目录错配风险。

新增修复：

- `ImportComic._copyDirectories()` 现在记录本批次已复制出来的 normalized 目标目录；
  后续同 basename 源目录会选择 `Comic(1)` 这类新目录，而不是把本批次刚复制好的
  `Comic` 误当作外部旧目录改名备份。
- 原有“目标目录在导入前就已存在时，先备份再替换；失败时恢复旧目录”的语义保持不变。
  本轮只区分“本批次刚创建的目录”和“导入前已有的外部目录”，避免导入记录指向被后续
  同名源目录替换后的路径。

新增/扩展测试：

- `test/import_comic_test.dart` 覆盖同一导入批次内两个不同父目录下的同名 `Comic`
  源目录会分别复制到 `Comic` 与 `Comic(1)`，且不会创建误备份的 `Comic_old`。

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\import_comic_test.dart --reporter=compact`
- `flutter test --no-pub test\local_file_uri_test.dart test\cbz_import_test.dart test\pdf_export_test.dart test\epub_export_test.dart test\import_comic_test.dart --reporter=compact`

## 2026-06-04 第二十六轮全项目审查

本轮继续审查固定缓存路径与 Android 文件交互路径，收敛处理 direct access 目录选择
使用固定缓存目录的互踩风险。

新增修复：

- `DirectoryPicker.pickDirectory(directAccess: true)` 在 Android 上不再把选中目录复制到固定
  `App.cachePath/selected_directory`；现在使用 operation scoped
  `selected_directory-<operationId>` 缓存目录。
- 多 CBZ 导入等 direct access 调用如果短时间内重复触发，后一轮不会先删除前一轮仍在读取的
  缓存目录。目录对象仍通过原 finalizer 在不再使用后清理，不改变用户选择目录、导入格式或外部 API。

新增/扩展测试：

- `test/local_file_uri_test.dart` 覆盖 direct access 目录缓存路径按 operation id 隔离。

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\local_file_uri_test.dart --reporter=compact`

## 2026-06-04 第二十七轮全项目审查

本轮继续审查恢复、dispose 与后台下载任务快照写盘路径，收敛处理重复 flush/save
造成的无意义写盘和测试 teardown 后残留后台写入噪声。

新增修复：

- `LocalManager` 记录最近一次成功写入的下载任务 JSON 快照；如果后续 flush/save
  请求的数据完全一致，会直接跳过实际文件写入，降低恢复期、dispose 和下载任务状态
  连续通知时的磁盘抢占。
- 去重只在成功写盘后更新 last-written 记录；如果写入 hook 或文件写入失败，下一次
  flush 仍会重试，不会把失败快照误判为已持久化。
- 现有 in-flight flush 合并语义保持不变：相同快照共享同一次写入，不同快照会在当前
  写入结束后继续写最新状态。

新增/扩展测试：

- `test/local_manager_test.dart` 覆盖相同下载任务快照只写一次、状态变化后重新写入，
  并保留写入失败后的后续重试能力。

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\local_manager_test.dart --reporter=compact`

## 2026-06-04 第二十八轮全项目审查

本轮继续审查缓存临时文件生命周期与 finalizer 清理路径，收敛处理 cache path
归属判断使用裸字符串前缀导致的误删风险。

新增修复：

- `DirectoryPicker` 和 `FileSelectResult` 的 finalizer 不再用 `path.startsWith(App.cachePath)`
  判断是否可以清理临时文件；改为 `isPathInsideDirectory()`，先归一化本地路径/`file://`
  URI，再按 Windows/Posix 路径规则做真实目录边界判断。
- 路径等于缓存目录或位于缓存目录子树时仍会清理；`cache-old`、`cache_backup` 这类
  仅共享字符串前缀的外部路径不会再被误当作缓存临时路径删除。
- 不改变 Android SAF/direct access、桌面文件选择、保存/分享外部 API，只收紧内部
  临时路径清理边界。

新增/扩展测试：

- `test/local_file_uri_test.dart` 覆盖 Posix/Windows 路径、`file://` URI、大小写归一化
  和同前缀兄弟目录不被判定为缓存子路径。

追加验证：

- `flutter test --no-pub test\local_file_uri_test.dart --reporter=compact`

## 2026-06-04 第二十九轮全项目审查

本轮继续审查外部文件选择/保存与 Android 生命周期恢复鉴权之间的交互，收敛处理
多个文件操作重叠时 `IO.isSelectingFiles` 被提前清零的风险。

新增修复：

- `IO.isSelectingFiles` 从单个 bool 改为内部计数式 guard；文件选择、目录选择、
  direct access 目录复制和 `saveFile` 开始时递增，结束后的延迟清理递减。
- 多个外部文件操作重叠时，先结束的操作不会把全局状态提前置 false；最后一个操作
  的清理完成后才恢复 false，避免生命周期 `hidden` 回调在文件选择/保存期间误判并
  触发鉴权页或遮罩。
- 外部 API 不变，仍只暴露 `IO.isSelectingFiles`；测试 hook 仅用于验证计数边界。

新增/扩展测试：

- `test/local_file_uri_test.dart` 覆盖两个文件操作重叠退出时，第一轮结束后
  `IO.isSelectingFiles` 仍保持 true，第二轮结束后才清零。

追加验证：

- `flutter test --no-pub test\local_file_uri_test.dart --reporter=compact`

## 2026-06-05 第三十轮全项目审查

本轮继续审查离线下载任务与图片加载流结束顺序，收敛处理图片流正常结束但没有产出
最终图片字节时下载队列永久等待的风险。

新增修复：

- `_ImageDownloadWrapper` 在 `ImageDownloader.loadComicImageNoCache()` 流结束后如果没有
  收到非空 `imageBytes`，会按下载失败处理并唤醒所有 `wait()` waiter；不会再让
  `ImagesDownloadTask.resume()` 永久挂在当前图片。
- 空 `imageBytes` 也会进入错误/重试路径，避免写出 0 字节图片并把下载进度误推进。
- 无章节漫画下载任一图片失败时会进入任务错误态并保留下载任务快照，而不是继续
  `completeTask()` 生成缺图/空图的本地漫画。分章节漫画仍保留既有“跳过失败章节”
  语义。
- `ImagesDownloadTask._setError()` 统一触发 guarded background snapshot save，错误态可
  在恢复后继续被展示/处理；前序快照去重会避免重复错误保存造成额外写盘抖动。

新增/扩展测试：

- `test/local_manager_test.dart` 覆盖 debug 图片流只产出进度、不产出 `imageBytes`
  时，下载任务会在 3 次重试后进入 error 态、停止速度计时，并留在下载队列中等待用户处理。

追加验证：

- `flutter test --no-pub test\local_manager_test.dart --reporter=compact`

## 2026-06-05 第三十一轮全项目审查

本轮继续审查缓存 DB 损坏/异常 row 与磁盘清理边界，收敛处理 cache row 中 `dir/name`
异常时可能把缓存目录外文件误当作缓存文件删除的风险。

新增修复：

- `CacheManager` 从 SQLite row 还原缓存文件路径时，先用真实路径边界确认目标仍位于
  `CacheManager.cachePath` 子树内；不在缓存根内的 row 统一视为 malformed row。
- 过期清理、容量清理、`findCache`、`delete` 和 managed size 统计都会复用该路径校验；
  损坏 row 只删除 DB 记录，不触碰缓存目录外文件。
- 不改变缓存 DB schema、cache key、文件目录结构或正常缓存命中语义。

新增/扩展测试：

- `test/cache_manager_test.dart` 覆盖过期 malformed cache row 指向缓存根外文件时，
  `checkCache()` 会删除异常 DB row，但不会删除缓存目录外的真实文件。

追加验证：

- `flutter test --no-pub test\cache_manager_test.dart --reporter=compact`

## 2026-06-05 第三十二轮全项目审查

本轮继续审查后台追更服务与恢复期同步任务的交互，收敛处理取消追更时仍可能卡在
等待 `DataSync` 下载结束的风险。

新增修复：

- `FollowUpdatesService._check()` 在等待 `DataSync().isDownloading` 的循环中会同步检查
  cancel flag；用户切换追更文件夹、手动检查或测试 reset 后，旧后台任务不会继续
  留在等待循环里占用服务状态。
- 等待逻辑抽成 `shouldWaitForDataSyncBeforeFollowUpdate()` 纯函数，便于测试取消、下载
  结束和正常等待三种状态；不改变追更间隔、WebDAV 同步协议或收藏数据格式。

新增/扩展测试：

- `test/follow_updates_test.dart` 覆盖追更检查器在 DataSync 下载中收到取消信号时不再
  继续等待。

追加验证：

- `flutter test --no-pub test\follow_updates_test.dart --reporter=compact`
- `flutter test --no-pub test\cache_manager_test.dart --reporter=compact`

## 2026-06-05 第三十三轮全项目审查

本轮继续审查下载弹窗与下载任务 listener 生命周期，收敛处理依赖变化或任务实例替换后
重复绑定/漏重绑导致的重复刷新风险。

新增修复：

- `DownloadingPage.didChangeDependencies()` 不再每次依赖变化都直接给首个下载任务
  `addListener(update)`；统一走 `_bindFirstTask()`，同一对象只绑定一次。
- 下载任务 listener 重绑判断改为对象身份 `identical`，避免 `DownloadTask.operator ==`
  的业务相等把“不同实例但同一漫画任务”误判成同一个对象，导致旧 task listener
  未移除或新 task listener 未绑定。
- `_DownloadTaskTile.didUpdateWidget()` 复用同一身份判断；不改变下载队列、任务恢复、
  下载目录或用户操作语义。

新增/扩展测试：

- `test/downloading_page_test.dart` 覆盖 listener 重绑决策使用对象身份；两个 `==`
  相等但实例不同的任务仍会触发重绑。

追加验证：

- `flutter test --no-pub test\downloading_page_test.dart --reporter=compact`
- `flutter test --no-pub test\follow_updates_test.dart test\cache_manager_test.dart --reporter=compact`

## 2026-06-05 第三十四轮全项目审查

本轮继续审查平台回调、通用按钮状态与恢复期重复操作风险，收敛处理销毁边缘回调和
首帧 loading 状态不一致导致的稳定性问题。

新增修复：

- `VirtualWindowFrame` 的 `WindowListener` 平台回调在 `setState()` 前统一检查
  `mounted`；Linux/桌面窗口 focus、maximize、fullscreen 事件如果在 frame dispose
  边缘晚到，不再触发 `setState() called after dispose()`。
- `WindowFrameController.setWindowFrame()` 同样增加 `mounted` guard；下层页面持有的
  inherited controller 回调在 frame 已销毁后触发时会安全丢弃。
- 通用 `Button` 的内部 `isLoading` 状态在 `initState()` 中同步 `widget.isLoading`；
  首帧即处于 loading 的保存、导入、同步、确认类按钮不会先渲染成可点击状态，避免弱网
  或恢复期重复提交。
- `AppScrollBar` 的 controller microtask 更新入口增加 `mounted` guard；滚动页快速
  切出或列表 controller 替换后，排队中的 `onChanged()` 不再访问已销毁 state。
- `AppTabBar` 在 tabs 数量变化时会同步 resize 内部 `GlobalKey` 列表；探索/分类等
  动态 tab 场景不再因为新 tab 访问旧长度 key 列表而越界崩溃。相关滚动通知与 tab
  animation listener 也增加 `mounted` guard，避免快速切页后晚到回调访问已销毁 state。
- 设置页多页筛选的“Add”对话框确认时会先检查外层筛选 state 是否仍 mounted 且
  selected 非空；弹窗/页面被快速关闭后，晚到按钮回调不会再对已销毁 state 调用
  `setState()`。
- `Appdata.saveData()` 在 `disableSyncFields` 为空时会删除旧的 `syncdata.json`；用户关闭
  同步字段裁剪后，后续 WebDAV/手动数据导出不会继续打包过期的裁剪数据。

新增/扩展测试：

- `test/button_state_test.dart` 覆盖 `Button.filled(isLoading: true)` 首次构建就显示
  loading，并阻止点击回调。
- `test/controller_lifecycle_stability_test.dart` 覆盖 `AppScrollBar` 快速 dispose 后
  排队更新不会抛异常。
- `test/appbar_state_test.dart` 覆盖 `AppTabBar` key 列表扩容/缩容时保持长度正确并保留
  既有 key。
- `test/settings_components_test.dart` 覆盖多页筛选选择合并只在 mounted 且 selected
  非空时执行。
- `test/appdata_normalization_test.dart` 覆盖关闭同步字段裁剪后 stale `syncdata.json`
  会被清理。

追加验证：

- `flutter analyze --no-pub`
- `flutter test --no-pub test\button_state_test.dart test\window_placement_test.dart test\appbar_state_test.dart test\tab_controller_lifecycle_test.dart test\controller_lifecycle_stability_test.dart --reporter=compact`

后续待证据确认：

- `DataSync.uploadData()` 在下载中收到本地数据变更时仍是直接返回成功，不排队上传；
  这可能在 WebDAV 恢复下载与本地收藏/源数据快速修改重叠时丢掉一次远端上传机会。
  但这涉及“下载导入优先”与“本地变更优先”的冲突策略，本轮只记录为需要 Android
  profile/真实 WebDAV 场景验证的同步语义风险，不直接改变同步协议行为。

## 2026-06-05 第三十五轮全项目审查

本轮继续审查全局导航、主视图重建回调和外部 controller 持有 UI state 的路径，收敛处理
导航子树销毁后父级仍持有旧刷新闭包的风险。

新增修复：

- `_NaviMainViewState` 注册到 `NaviPaneState.mainViewUpdateHandler` 的刷新闭包在调用前
  检查 `mounted`，并在 dispose 时只清理自己注册的 handler。
- 快速切页、导航容器重建或页面销毁后，`NaviPaneState.updatePage()` 不会再通过旧
  `mainViewUpdateHandler` 调用已销毁 `_NaviMainViewState.setState()`。
- 不改变导航路由、页面切换、底栏/侧栏行为，只收紧 controller 生命周期边界。

新增/扩展测试：

- `test/controller_lifecycle_stability_test.dart` 覆盖 `NaviPane` 主视图 handler 在子树
  dispose 后被外部调用不会抛 `setState after dispose`。

追加验证：

- `flutter test --no-pub test\controller_lifecycle_stability_test.dart --reporter=compact`

## 2026-06-05 第三十六轮全项目审查

本轮继续审查 reader overlay、桌面 WebView 关闭回调和全局 LoadingState retry 生命周期，
收敛处理久置恢复、快速返回和快速重开窗口时的悬挂 UI/后台请求抖动。

新增修复：

- 阅读器“选择图片”遮罩改为由 `ReaderSelectImageOverlayController` 统一持有并清理；
  `_ReaderScaffoldState.dispose()` 会主动移除当前 overlay、完成等待中的 Future，并按
  Flutter `OverlayEntry` 约束先 `remove()` 再 `dispose()`。
- 阅读器选择图片遮罩文案改为 `Expanded + ellipsis`，避免英文或长翻译在固定宽浮层里
  触发 `RenderFlex overflow`，减少 debug/profile 下的异常噪声。
- `DesktopWebview.open()` 引入 session guard；旧 WebView 的 `onClose` 回调晚到时不会
  取消新窗口的轮询 timer，也不会重复触发新一轮登录/Cloudflare 流程的 `onClose`。
- `LoadingState.loadDataWithRetry()` 在 retry delay 后再次检查 `mounted`；页面已销毁时
  不再继续第二轮网络加载/解析，避免快速返回或恢复期后台请求抢占主交互。

新增/扩展测试：

- `test/reader_loading_test.dart` 覆盖 reader 选择图片 overlay 在 owner dispose 后会
  被移除，等待 Future 以 `null` 完成且无异常。
- `test/webview_helpers_test.dart` 覆盖 DesktopWebview close callback 决策：当前窗口关闭
  和手动关闭旧窗口可处理，旧 session close 晚到且已有新窗口时会被丢弃。
- `test/loading_state_stability_test.dart` 覆盖 LoadingState 在 dispose 后不会继续 retry
  第二次 `loadData()`。

追加验证：

- `flutter test --no-pub test\reader_loading_test.dart --reporter=compact`
- `flutter test --no-pub test\webview_helpers_test.dart --reporter=compact`
- `flutter test --no-pub test\loading_state_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`

外部依据补充：

- Flutter `OverlayEntry.remove()` 说明 entry 从 overlay 移除且只能调用一次。
- Flutter `OverlayEntry.dispose()` 说明已插入 overlay 时必须先 `remove()` 再 `dispose()`。
- Flutter `State.mounted` 说明 `dispose()` 后再调用 `setState()` 是错误。

## 2026-06-05 第三十七轮全项目审查

本轮继续审查全局 overlay、toast 和导航手势收尾路径，收敛处理高频 UI 资源释放和路由
手势状态在销毁边缘残留的风险。

新增修复：

- `showToast()` 在没有 `OverlayWidget` 宿主时直接空操作；如果宿主 overlay 尚不可用，
  新建的 `OverlayEntry` 会立即 `dispose()`，不再依赖后续 timer 兜底。
- `OverlayWidgetState.remove()` / `removeAll()` 对 toast entry 统一执行 `remove()` 后
  `dispose()`，符合 Flutter `OverlayEntry` owner 生命周期约束，避免全 App 高频 toast
  在连续提示或页面销毁后留下未释放 entry。
- `IOSBackGestureController` 增加幂等 `cancel()`；`IOSBackGestureDetector.dispose()`
  会取消仍在进行中的返回手势，确保 `Navigator.didStopUserGesture()` 不会在 sidebar、
  popup 或路由销毁边缘遗漏。
- `IOSBackGestureController.dragUpdate()` / `dragEnd()` 在已取消后直接丢弃，避免重复
  `didStopUserGesture()` 触发 Navigator 内部断言。

新增/扩展测试：

- `test/overlay_widget_test.dart` 覆盖 toast timeout 自然移除、宿主 dispose 清理，以及无
  `OverlayWidget` 宿主时 `showToast()` 不抛异常。
- `test/comic_cover_hero_transition_test.dart` 覆盖 `IOSBackGestureController.cancel()`
  能把 `Navigator.userGestureInProgress` 恢复为 false，重复 cancel/dragEnd 不抛异常。

追加验证：

- `flutter test --no-pub test\overlay_widget_test.dart --reporter=compact`
- `flutter test --no-pub test\comic_cover_hero_transition_test.dart --reporter=compact`
- `flutter analyze --no-pub`

## 2026-06-05 第三十八轮全项目审查

本轮继续审查全局 `BuildContext` 导航扩展和异步回包持有旧 context 的路径，收敛处理
页面销毁后仍尝试导航导致的恢复期/快速返回崩溃风险。

新增修复：

- `BuildContext.canPop()` 在 context 已 unmounted 时直接返回 `false`。
- `BuildContext.to()` / `toReplacement()` 在 context 已 unmounted 时返回已完成 Future，
  不再调用 `Navigator.of(context)`。
- 不改变正常 mounted context 下的路由、snapshotting 或返回值语义，只补齐和既有
  `BuildContext.pop()` 一致的 mounted guard。

新增/扩展测试：

- `test/context_navigation_test.dart` 覆盖保存下来的 stale context 在 widget 卸载后调用
  `canPop()`、`to()`、`toReplacement()` 都不会抛异常。

追加验证：

- `flutter test --no-pub test\context_navigation_test.dart --reporter=compact`
- `flutter analyze --no-pub`

## 2026-06-05 第三十九轮全项目审查

本轮继续审查后台同步、下载任务快照和数据导入导出链路，优先处理能本地纯函数验证的
数据稳定性问题，避免在缺少真实 WebDAV 冲突证据时改动同步协议。

新增修复：

- WebDAV 远端备份文件解析统一为内部 helper：只接受安全 `.venera` 文件名，并从最后
  一个 `-` 后解析数字 `dataVersion`；`sync-12.venera` 这类旧安全文件名仍保持可识别。
- `downloadData()` 选择远端备份时改为按数字 `dataVersion` 选最新，不再用字符串倒序；
  避免 `...-9.venera` 被错误排在 `...-10.venera` 之后，导致恢复旧备份。
- 上传前远端清理改为去重后按备份年龄清理，并删除当前上传前缀下的所有旧备份；避免
  同一天多次上传只删除一个旧文件，远端保留窗口逐步膨胀。
- 下载缓存文件名继续使用 sanitize 后的本地安全名，防止远端异常文件名影响本地 cache
  路径；未通过安全解析的远端文件不会参与下载选择和保留窗口计算。

新增/扩展测试：

- `test/data_sync_config_test.dart` 覆盖 WebDAV 配置归一化、远端备份文件解析、旧安全
  文件名兼容、数字版本号排序、同上传前缀批量清理和按数字年龄裁剪保留窗口。

追加验证：

- `flutter test --no-pub test\data_sync_config_test.dart --reporter=compact`

继续观察但本轮不改的低置信风险：

- `DataSync.uploadData()` 目前在下载中会直接返回成功，且上传失败前已经本地递增
  `dataVersion`；这可能影响多设备冲突策略，但改变行为需要真实 WebDAV 场景和迁移
  证据，暂不在全项目审查中盲改。
- `App.rootContext` 仍有大量同步 UI 点击路径使用直取；本轮只把后台延迟 close listener
  和旧 context 导航路径收紧，未做全局替换，避免扩大行为面。

## 2026-06-05 第四十轮全项目审查

本轮继续审查 reader 输入事件、定时器和全局事件订阅路径，优先处理异常/合成 pointer
事件对阅读器内部手势状态的破坏，减少恢复期、快速切换和系统输入边缘导致的阅读器错判。

新增修复：

- `_ReaderGestureDetector` 对 `Offset.zero` 的 sentinel pointer down 继续忽略，但 pointer
  up/cancel 现在会通过统一 helper 把手指数 clamp 到不低于 0，不再把 `fingers` 打成负数。
- `_ReaderImagesState` 和连续滚动 reader 层的 pointer up/cancel 同样复用该 clamp helper；
  避免重复 cancel/up 或系统合成事件让多指缩放、禁用滚动、长按拖拽和章节边缘跳转状态失真。
- 正常 down/up/cancel 路径不改变，只补齐异常输入序列下的状态边界；延迟长按/双击回调仍按
  mounted 和当前 pending pointer guard 执行。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 覆盖 sentinel pointer down 不进入跟踪，以及 pointer
  end 在 2/1/0/负数输入下都会得到安全手指数。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart test\reader_image_scheduling_test.dart test\reader_image_cache_strategy_test.dart test\reader_loading_test.dart --reporter=compact`

继续观察但本轮不改的低置信风险：

- 全局 `App.rootContext` 的同步 UI 点击路径仍较多，当前没有证据证明这些同步调用是恢复期
  崩溃主因；后续若 trace 指向 root navigator 未挂载，再做集中替换。
- reader 的 `VolumeListener`、电量/时钟 timer 和 app-link/text-share 订阅已有取消或测试
  reset 路径，本轮未发现同等置信的新泄漏点。

## 2026-06-05 第四十一轮全项目审查

本轮继续不限于未提交变更审查全局 overlay owner 生命周期，重点覆盖搜索建议、toast
宿主、主入口隐私遮罩和 reader overlay host。Flutter `OverlayEntry` 由创建者持有，已插入
entry 必须先 `remove()` 再 `dispose()`；本轮只修同类高置信释放缺口。

新增修复：

- 新增 `removeAndDisposeOverlayEntry()` 内部 helper，统一执行 `OverlayEntry.remove()` 后
  `dispose()`，减少各页面手写 owner 清理遗漏。
- 搜索结果页 tag suggestions overlay 在关闭、搜索、打开设置或页面销毁时都会释放 owner
  entry；销毁时不再把清理延后到 microtask，同时清空 suggestions state 引用。
- 主入口 lifecycle 隐私遮罩在恢复或 app dispose 时按 owner 规则释放，不再只 `remove()` 后
  丢弃引用。
- `OverlayWidget` 的 toast entry 和根 `initialEntries` entry 都改为 state 持有并释放；
  根 entry 在 child 更新时 `markNeedsBuild()`，保持宿主内容刷新能力。
- reader overlay host 的自持 `initialEntries` entry 在 state dispose 时释放；reader 选择图片
  overlay 仍保持既有 controller 清理路径。

新增/扩展测试：

- `test/overlay_widget_test.dart` 覆盖通用 helper 会移除并 dispose owner entry、`OverlayWidget`
  child 更新仍刷新、toast 超时/宿主销毁/无宿主路径无异常。
- `test/reader_loading_test.dart` 继续覆盖 reader overlay host 更新和 reader 选择图片 overlay
  owner dispose 清理。
- `test/app_lifecycle_stability_test.dart` 继续覆盖 lifecycle 隐私遮罩显示/恢复移除决策。

追加验证：

- `flutter test --no-pub test\overlay_widget_test.dart test\reader_loading_test.dart test\app_lifecycle_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`

继续观察但本轮不改的低置信风险：

- `Overlay(initialEntries)` 本身不会替业务 owner 调 `OverlayEntry.dispose()`；本轮已修当前
  `lib/` 下可确认的自持 entry。后续新增 overlay owner 时应复用 helper 或显式配对释放。
- 全局同步点击路径仍有不少 `App.rootContext` 读取；本轮只处理 overlay 生命周期，没有扩大到
  全局导航替换。

## 2026-06-05 第四十二轮全项目审查

本轮继续审查 controller、picker 和延迟回包路径，优先处理用户可触发且能纯函数验证的
稳定性问题。重点落在图片收藏筛选弹窗的自定义时间范围：旧同步数据或用户只选一端日期时，
确认路径会触发 `end!` / `start!` 空断言；日期选择器返回后也可能命中已销毁弹窗。

新增修复：

- 图片收藏时间筛选新增 `resolveImageFavoriteTimeRangeSelection()`，统一把预设筛选和
  custom start/end 转成 `TimeRange`；custom 必须同时具备 start/end，且 end 不早于 start。
- `_ImageFavoritesDialogState.initState()` 处理旧的半截 custom range 时不再直接 `end!`。
- 两个 `showDatePicker()` 返回后增加 `mounted` guard，避免弹窗关闭后继续 `setState()`。
- custom 日期未选完整或时间倒置时禁用确认按钮，避免写入非法筛选配置或触发空断言。

新增/扩展测试：

- `test/image_favorites_filter_test.dart` 覆盖预设筛选解析、合法 custom 范围，以及缺
  start、缺 end、end 早于 start 时返回 null。

追加验证：

- `flutter test --no-pub test\image_favorites_filter_test.dart --reporter=compact`
- `flutter analyze --no-pub`

继续观察但本轮不改的低置信风险：

- 搜索、收藏和本地库页面仍有较多弹窗后 `setState()` 路径；本轮只修已确认会空断言或
  dispose 后回包的日期筛选弹窗，其他路径需要逐个结合测试补强。

## 2026-06-05 第四十三轮全项目审查

本轮继续审查 controller、timer、listener 和 navigator observer 生命周期路径，优先处理
全局导航容器里自定义监听器的可重入通知风险。Flutter `ChangeNotifier.notifyListeners()`
明确要求通知期间新增的 listener 不参与本轮、已移除的 listener 不再被调用；本轮把
`NaviObserver` 的行为向这个稳定语义收敛，并修正 route 栈同步边界。

新增修复：

- `NaviObserver.didPop()` 现在按 Flutter 传入的 `route` 移除对应 route，而不是无条件
  `removeLast()`；避免 observer route 队列与 Navigator 实际 pop 事件不同步时误删后续
  route 或空队列抛错。
- `NaviObserver.notifyListeners()` 改为快照派发，并跳过已在本轮通知期间移除的 listener；
  避免监听器在回调中移除自己或其它监听器时破坏迭代，导致漏通知、重复状态刷新或恢复期
  导航状态不同步。
- `listeners` 改为 `final`，收紧 owner 状态，避免外部或后续维护时误替换监听列表。

新增/扩展测试：

- `test/controller_lifecycle_stability_test.dart` 覆盖 listener 在通知中移除自己时不会影响
  后续 listener，且被移除 listener 不会参与下一轮通知。
- 同一测试文件覆盖 `didPop(route, ...)` 会按实际 popped route 移除，而不是盲删最后一个
  route。

追加验证：

- `flutter test --no-pub test\controller_lifecycle_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`

继续观察但本轮不改的低置信风险：

- 多数 `AnimationController`、`TextEditingController`、`ScrollController` 和 `FocusNode`
  owner 已有 dispose；后续继续审查剩余弹窗、延迟 `Future.delayed()` 和滚动分页路径。
- `NaviObserver` 仍是轻量自定义 listenable；如果后续需要异常隔离或更完整的 ChangeNotifier
  语义，可以再评估直接继承 `ChangeNotifier`，但本轮不扩大行为面。

## 2026-06-05 第四十四轮全项目审查

本轮继续审查高频图片、controller owner 和页面销毁路径，优先处理图片收藏查看器的
`PageController` 生命周期。Flutter `PageController` 属于创建者持有的 controller；页面
私有创建后必须在 `State.dispose()` 中释放，否则多次打开/关闭图片收藏大图查看会积累
scroll/page controller 状态和监听器。

新增修复：

- `ImageFavoritesPhotoView` 现在在 `dispose()` 中释放自建 `PageController`，避免图片收藏
  大图查看器反复打开/关闭后 controller 泄漏。
- 新增仅测试用 `debugPageControllerFactory`，保持用户行为不变，同时允许 focused widget
  test 捕获由页面创建的 controller 并验证 owner dispose。

新增/扩展测试：

- `test/image_favorites_photo_view_test.dart` 覆盖 `ImageFavoritesPhotoView` 卸载时会释放其
  owner `PageController`，且页面移除后无异常。

追加验证：

- `flutter test --no-pub test\image_favorites_photo_view_test.dart --reporter=compact`
- `flutter analyze --no-pub`

继续观察但本轮不改的低置信风险：

- `ImageFavoritesPhotoView.onPop()` 在 `didPop` 后使用当前 context 显示 toast；当前路径只在
  有待删除图片时触发，且缺少明确恢复期崩溃证据，本轮不和 controller 生命周期修复混在一起。
- 图片收藏查看器的保存/阅读菜单仍有异步文件保存和全局 root context 导航路径；后续若 trace
  指向该菜单，再单独做 mounted/root navigator guard。

## 2026-06-05 第四十五轮全项目审查

本轮继续审查 reader 恢复后首操作路径，重点落在“选择当前图片”相关异步回包：图片收藏、
保存图片、分享图片都会先等待选择 overlay 或磁盘/cache 读取，然后继续访问 `context.reader`。
如果用户在 overlay 打开、恢复卡顿或读图期间退出 reader/切章节，旧回包可能击中已销毁或已
替换的 reader 状态。

新增修复：

- reader 选图 overlay 返回后新增 `mounted` 和 image view controller identity guard；reader
  已销毁或章节/模式切换导致 controller 替换时，丢弃旧选择结果，不再继续定位图片。
- `selectImageToData()` 读取图片数据时使用进入函数时的 reader snapshot，并在选择返回、cache
  查询返回、读图结束后再次检查 `mounted`；避免保存/分享路径在页面销毁后继续读
  `context.reader`。
- `saveCurrentImage()`、`share()` 和 `addImageFavorite()` 在 await 返回后继续触发保存、
  分享、收藏或 toast 前补 `mounted` guard；异常 toast 也只在 state 仍挂载时显示。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 新增 `shouldUseReaderImageSelectionResult()` 覆盖：
  只有 mounted、image view controller 未替换且 overlay 返回有效位置时，才允许继续处理选图结果。
- `test/reader_loading_test.dart` 继续覆盖 selection overlay owner dispose 时 pending future
  返回 null，确保 reader scaffold 销毁会关闭选择 overlay。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart test\reader_loading_test.dart --reporter=compact`
- `flutter analyze --no-pub`

继续观察但本轮不改的低置信风险：

- reader 的保存/分享最终文件系统交互仍依赖平台插件返回；本轮只处理本地 reader state 生命周期，
  未改变保存目录、分享协议或文件命名语义。
- 全局 `App.rootContext` 的同步 UI 路径仍较多；没有明确 trace 前，继续按具体操作链逐个加 guard，
  不做一次性替换。

## 2026-06-05 第四十六轮全项目审查

本轮继续不限于未提交 diff 做全项目审查，重点落在详情页收藏/点赞这类高频外部源交互。
这些路径会等待漫画源 JS/API 回包；如果用户关闭详情页、收藏侧栏，或应用久置恢复后旧请求才返回，
裸 `setState()`、`context.showMessage()` 和 `async void` 异常都可能造成闪退或 loading 状态卡死。

新增修复：

- `_NetworkSectionState.loadFolders()` 新增 request id guard；加载收藏文件夹返回后只有当前面板仍挂载、
  且请求仍是最新请求时才更新 `folders`、`addedFolders` 和 `isLoadingFolders`。
- 网络收藏单文件夹和多文件夹操作新增 mounted/request guard；多文件夹按 folder id 记录 token，
  避免关闭面板或同一项重复点击后旧回包继续触发 `setState()`、toast 或 `context.pop()`。
- 收藏面板的 `loadFolders()`、`addOrDelFavorite()` 异常路径进入 `Log.error` 并释放当前 loading，
  避免漫画源实现抛错时变成未捕获 `async void` 异常。
- 详情页 `likeOrUnlike()` 新增 owner mounted getter、请求 token 和 try/catch/finally；点赞请求返回后
  只应用当前页面的当前回包，异常时记录日志并恢复 `isLiking`，不改变点赞 API 参数语义。
- 新增 `shouldApplyComicPageAsyncResult()` 和 `shouldApplyNetworkFavoritePanelResult()` 测试 helper，
  用纯函数固定 mounted/current-request 判定。

新增/扩展测试：

- `test/comic_page_favorite_status_test.dart` 覆盖详情页异步回包 helper：mounted 且请求号当前才允许落地；
  unmounted 或 stale request 均丢弃。
- 同一测试文件继续覆盖收藏文件夹 `subData` 归一化、后台收藏状态刷新和用户操作后 stale request 丢弃。

追加验证：

- `flutter test --no-pub test\comic_page_favorite_status_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`

继续观察但本轮不改的低置信风险：

- `actions.dart` 中 archive 下载弹窗、评分弹窗已有局部 `context.mounted` guard；后续若 trace 指向这些
  路径，再按具体弹窗补 request token 和异常日志，不把语义不同的弹窗操作混在本轮修复里。
- `comments_page.dart`、收藏列表批量更新和本地收藏页面仍有大量外部源/文件系统异步回包；下一轮继续按
  高频入口逐个验证和修复。

## 2026-06-05 第四十七轮全项目审查

本轮继续按全项目而非未提交 diff 审查，聚焦详情页评论侧栏。评论分页加载路径已经有 in-flight 和
request guard，本轮没有重复扩大；高置信风险落在发送评论、点赞评论和投票评论这些外部漫画源函数：
源实现抛错时原先会从 UI `async` 回调漏出，同时 loading 状态可能无法释放。

新增修复：

- `CommentsPage` 的发送评论路径新增 request id guard；侧栏关闭、重试刷新或新请求启动后，旧回包不再
  清空输入框、重置列表或触发 toast。
- `sendCommentFunc` 异常路径进入 `Log.error` 并释放 `sending`，避免漫画源 JS/API 抛错时变成未捕获
  异常或让发送按钮长期处于 loading。
- `_CommentTile` 的评论点赞和投票路径新增 request id guard，并在 `dispose()` 中失效未完成请求；
  旧回包不会继续更新点赞数、投票状态、toast 或 loading。
- `likeCommentFunc`、`voteCommentFunc` 异常路径进入 `Log.error` 并释放当前按钮 loading，不改变
  成功/失败返回 `Res` 的现有 UI 语义。
- 新增 `shouldApplyCommentActionResult()` 和 `resolveCommentVoteStatus()` 纯函数，固定评论 action
  回包落地条件和投票状态计算。

新增/扩展测试：

- `test/comment_loading_stability_test.dart` 覆盖评论 action 回包只有 mounted 且 request id 当前时才允许
  落地。
- 同一测试覆盖投票状态解析：upvote、downvote 和取消投票分别解析为 `1`、`-1`、`0`。

追加验证：

- `flutter test --no-pub test\comment_loading_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`

继续观察但本轮不改的低置信风险：

- 章节评论页与评论预览仍需单独审查；虽然形态相似，但涉及 reader/chapter state，下一轮按独立入口验证，
  不把两个上下文混在本轮修复里。
- 评论分页加载 catch 目前转成 `Res.error` 并显示错误；没有明确崩溃证据，本轮只修 action 的未捕获异常和
  stale 回包。

## 2026-06-05 第四十八轮全项目审查

本轮继续不限于未提交 diff 审查相邻的 reader 章节评论入口。章节评论主侧栏和嵌入式章节评论的分页加载
已经具备 in-flight/request guard；高置信风险仍在发送章节评论、点赞评论、投票评论这些外部漫画源函数。
源实现抛错或 reader/章节评论页销毁后旧回包返回时，原路径可能产生未捕获 UI 回调异常、继续更新已销毁
组件，或让按钮 loading 卡住。

新增修复：

- `ChapterCommentsPage` 发送章节评论新增 request id guard；侧栏关闭、重试刷新或新发送请求启动后，旧回包
  不再清空输入框、刷新列表或触发 toast。
- 嵌入式章节评论 `_EmbeddedChapterCommentsPage` 发送路径同样新增 request id guard 和异常处理，避免
  reader 页面内嵌评论块销毁后继续更新 UI。
- `_ChapterCommentTile` 点赞和投票路径新增 request id guard，并在 `dispose()` 中失效未完成 action；
  旧回包不会继续更新点赞数、投票状态或按钮 loading。
- `sendChapterCommentFunc`、`likeCommentFunc`、`voteCommentFunc` 异常路径进入 `Log.error` 并释放当前
  loading 状态，不改变成功/失败 `Res` 的现有 UI 语义。
- 新增 `shouldApplyChapterCommentActionResult()` 和 `resolveChapterCommentVoteStatus()` 纯函数，固定
  章节评论 action 回包落地条件和投票状态计算。

新增/扩展测试：

- `test/comment_loading_stability_test.dart` 覆盖章节评论 action 回包只有 mounted 且 request id 当前时才允许
  落地。
- 同一测试覆盖章节评论投票状态解析：upvote、downvote 和取消投票分别解析为 `1`、`-1`、`0`。

追加验证：

- `flutter test --no-pub test\comment_loading_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`

继续观察但本轮不改的低置信风险：

- `comments_preview.dart` 是详情页静态预览，当前只持有并 dispose `ScrollController`，没有同类外部源 action
  回包；本轮不做无证据改动。
- 章节评论分页加载的 `maxPage = res.subData` 仍依赖源数据类型；详情页已有 normalization helper，是否复用到
  reader 章节评论需要单独确认行为兼容，暂列低优先审计项。

## 2026-06-05 第四十九轮全项目审查

本轮继续审查收藏相关入口，优先看网络收藏列表、文件夹操作和本地收藏批量操作。多文件夹网络收藏加载
已经有 in-flight/request guard，本地收藏大列表异步加载也已有 request id；高置信风险落在网络收藏的
删除漫画、删除文件夹和创建文件夹 action：这些路径调用外部漫画源函数，原先只处理 `Res.error`，源函数
直接抛错时会从 UI async 回调漏出，同时按钮 loading 可能无法释放。

新增修复：

- `_deleteComic()` 在网络收藏删除漫画时新增 request id guard 和 try/catch；旧回包或 dialog 已销毁后不再
  落地，外部源抛错会记录 `Log.error` 并释放 loading。
- `_FolderTile.onDeleteFolder()` 删除网络收藏文件夹时新增同样的 request guard、异常日志和 loading 释放，
  保持删除成功后刷新列表的现有语义。
- `_CreateFolderDialogState` 创建网络收藏文件夹时新增 `_createRequestId`，dispose 后失效未完成请求；源函数
  抛错时记录日志、显示错误并释放 loading。
- 新增 `shouldApplyNetworkFavoriteActionResult()` 测试 helper，固定 mounted/current-request 判定。

新增/扩展测试：

- `test/network_favorites_page_test.dart` 覆盖网络收藏 action 回包只有 mounted 且 request id 当前时才允许
  落地。

追加验证：

- `flutter test --no-pub test\network_favorites_page_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`

继续观察但本轮不改的低置信风险：

- `updateComicsInfo()` 的本地收藏批量更新会长时间运行，但已有错误计数、取消 dialog 和外层 mounted 更新；
  是否需要新增全局取消 token 取决于真实 trace，本轮不做大范围语义调整。
- 图片收藏大图保存图片仍会 await 读图和 `saveFile()`；目前没有明确崩溃证据，且保存动作涉及平台文件选择，
  后续若 trace 指向再单独加 mounted/owner guard。

## 2026-06-05 第五十轮全项目审查

本轮继续不限于未提交 diff 审查图片收藏大图预览入口。`OverlayWidget`、历史页刷新和图片收藏预览的
部分生命周期治理已存在；高置信风险落在图片收藏预览页右上角菜单：保存图片会先 await 收藏图片 provider
读图，再调用平台 `saveFile()`。如果用户在读图期间翻页、退出预览或重复触发保存，旧回包仍会继续使用
变化后的 `currentPage` 生成文件名并进入平台文件选择，存在旧页面异步动作落地、页码错配和异常漏出的风险。

新增修复：

- `ImageFavoritesPhotoView` 保存图片动作新增 `_saveImageRequestId`，并在 `dispose()` 中失效未完成保存请求；
  旧保存请求回包不再进入文件类型识别和平台 `saveFile()`。
- 保存图片时锁定触发瞬间的页码，保存文件名使用锁定页码，不再在 await 后读取可能已经变化的 `currentPage`。
- 保存图片异常路径进入 `Log.error`，仅当前页面、当前请求、当前页仍有效时记录，避免已销毁页面继续落地 UI action。
- 右上角菜单保存图片和跳转阅读入口共用 `isValidImageFavoriteMenuPage()`，避免空列表或过期页码直接索引
  `images[currentPage]`。
- 新增 `shouldApplyImageFavoriteMenuActionResult()` 纯函数，固定 mounted、request id 和页码一致时才允许保存回包落地。

新增/扩展测试：

- `test/image_favorites_photo_view_test.dart` 覆盖图片收藏菜单 action 只有 mounted、当前 request id、当前页码一致时
  才允许落地。
- 同一测试覆盖菜单页码边界：负数、等于列表长度、空列表都不会被视为有效页。

追加验证：

- `flutter test --no-pub test\image_favorites_photo_view_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`
- `git diff --check`（仍只有该 worktree 已知的 LF/CRLF 提示）

继续观察但本轮不改的低置信风险：

- `ImageFavoritesPhotoView` 的 `PhotoViewGallery` 翻页 `setState` 仍是高层刷新；需要真实滚动/缩放 trace 判断是否值得拆成
  更细粒度状态，本轮不盲目重构。
- `image_favorites_page.dart` 中筛选 dialog 和列表排序已有若干既有改动；本轮只验证图片预览菜单稳定性，不把语义不确定的
  筛选行为继续扩大调整。

## 2026-06-05 第五十一轮全项目审查

本轮继续不限于未提交 diff 审查关注更新入口。`FollowUpdatesService` 后台检查已经有串行、取消和异常日志；
页面手动 `setFolder()`、`checkNow()` 也已有 request id、loading finally 和进度归一化。高置信风险仍在这两个
用户触发路径的 `await for (updateFolder(...))`：漫画源/网络更新流直接抛错时，会从 `async void` UI 回调漏出，
虽然 loading 会被 finally 关闭，但异常仍可能造成操作闪退或测试环境未捕获异步异常。

新增修复：

- `FollowUpdatesPage.setFolder()` 的 `updateFolder()` 流新增 try/catch；外部源抛错时记录 `Log.error`，
  关闭 loading，并停止本次 UI action。
- `FollowUpdatesPage.checkNow()` 先锁定当前 folder，避免 await 前后配置变化导致 `folder!` 断言风险；更新流抛错时
  同样记录日志、关闭 loading 并停止落地。
- 新增 `shouldApplyFollowUpdateActionResult()`，统一 mounted/current-request 判定；`setFolder()` 和 `checkNow()`
  复用 `_shouldApplyUpdateResult()`，旧请求或已销毁页面不再落地 UI 更新。

新增/扩展测试：

- `test/follow_updates_test.dart` 覆盖关注更新 action 只有 mounted 且 request id 当前时才允许落地。

追加验证：

- `flutter test --no-pub test\follow_updates_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`
- `git diff --check`（仍只有该 worktree 已知的 LF/CRLF 提示）

继续观察但本轮不改的低置信风险：

- `FollowUpdatesWidget.updateCount()` 是全局状态回调，目前由 `AutomaticGlobalState` 管理；没有确认 dispose 后仍会被调用的
  证据，本轮不扩成全局状态框架改动。
- 关注更新的真实耗时和恢复期抢占仍需 Android profile trace 验证；本轮只修可本地证明的异常漏出和旧请求落地条件。

## 2026-06-05 第五十二轮全项目审查

本轮继续不限于未提交 diff 审查本地漫画长任务入口，重点看删除、导出、打开文件夹和下载弹窗。下载弹窗已经有
listener rebind 和 mounted guard；本地漫画导出已有 operation-scoped cache path、loading finally 和导出阶段
异常日志。高置信风险落在多本漫画导出 zip 的最终保存阶段：`saveFile(file: File(outFile), filename: "comics_export.zip")`
位于主导出 try/catch 之外，如果平台文件选择或保存失败，会从 `async void exportComics()` 漏出未捕获异常。

新增修复：

- 多本本地漫画导出 zip 的最终 `saveFile()` 新增 try/catch/finally；平台保存失败时记录 `Log.error`，并继续清理
  临时 zip 文件，不再让异常打穿 UI 回调。
- 新增 `shouldApplyLocalComicsExportResult()`，统一导出 UI 落地条件；页面已销毁或用户取消后，不再继续更新导出进度或
  弹出错误消息。
- 导出阶段原有 catch 的错误提示也改用同一个 helper，保持异常日志与 UI 落地条件一致。

新增/扩展测试：

- `test/local_comics_export_test.dart` 覆盖本地漫画导出结果只有 mounted 且未取消时才允许落地。

追加验证：

- `flutter test --no-pub test\local_comics_export_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`
- `git diff --check`（仍只有该 worktree 已知的 LF/CRLF 提示）

继续观察但本轮不改的低置信风险：

- 单本漫画导出时 `saveFile()` 仍在导出阶段 try/catch 内，已具备日志和 loading finally；是否需要区分平台保存失败的
  用户文案，需要真实 Android 保存失败日志再定。
- `openComicFolder()` 已有异常日志和 root context mounted 检查；不同桌面文件管理器 fallback 的可用性属于平台兼容问题，
  本轮不改。

## 2026-06-05 第五十三轮全项目审查

本轮继续不限于未提交 diff 审查搜索入口，重点看搜索页、搜索结果页和聚合搜索页的外部源变化与异步 UI 回包。
搜索页设置监听和搜索结果页设置 dialog 已有 mounted guard，搜索建议 overlay 也已有 dispose/remove 治理。高置信风险
落在 `SearchResultPage.build()`：页面持有的 `sourceKey` 如果在页面打开后被删除、禁用或变成不支持搜索，
`ComicSource.find(sourceKey)!` 和 `source.searchPageData!` 会在 rebuild 时空指针崩溃。

新增修复：

- `SearchResultPage` 新增 `resolveSearchResultSourceError()`，统一判断源缺失和源不支持搜索两种不可继续构建 `ComicList`
  的情况。
- `SearchResultPage.build()` 在构建 `ComicList` 前先解析源状态；源缺失或搜索数据不可用时返回 `NetworkError`，
  不再通过 `!` 断言打穿页面。
- 正常源路径保留原 `loadPage` / `loadNext` 语义，只把 `searchPageData` 解析成局部变量，避免重复空断言。

新增/扩展测试：

- `test/search_options_test.dart` 覆盖搜索结果源缺失、源不支持搜索和正常支持搜索三种 helper 判定。

追加验证：

- `flutter test --no-pub test\search_options_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`
- `git diff --check`（仍只有该 worktree 已知的 LF/CRLF 提示）

继续观察但本轮不改的低置信风险：

- `AggregatedSearchPage` 初始化时会把当前设置中的 search source 固定成 `ComicSource` 列表；源管理页热删除后是否需要主动
  监听并刷新聚合搜索源列表，需要更完整页面流验证，本轮不做无证据改动。
- 搜索结果设置 dialog 内的源列表来自当前启用源；如果用户在 dialog 打开期间从其他入口改源，可能出现 stale 选项，
  但需要并发 UI 操作证据，本轮只修 build 阶段确定的空指针风险。

## 2026-06-05 第五十四轮全项目审查

本轮继续不限于未提交 diff 审查分类漫画页。`CategoryComicsPage` 已有 options request id、dispose 失效和
options value 归一化；高置信风险仍在动态分类 options loader：外部漫画源 `optionsLoader` 如果直接抛异常，
原 `loadOptions()` 会从 `async void` 漏出未捕获异常，可能导致打开分类页或重试 options 加载时闪退。

新增修复：

- `CategoryComicsPage.loadOptions()` 对 `optionsLoader` 新增 try/catch；源函数抛错时记录 `Log.error`，
  并把异常转成页面 `NetworkError` 的 `error` 状态。
- 异常落地同样使用 `shouldApplyCategoryOptionsLoad()`，只有页面仍 mounted 且 request id 当前时才 setState；
  已销毁页面或旧请求回包不会落地。
- 新增 `categoryOptionsLoadExceptionMessage()`，固定异常到错误文案的转换，便于测试和后续统一错误处理。

新增/扩展测试：

- `test/category_comics_page_test.dart` 覆盖分类 options loader 异常文案转换。

追加验证：

- `flutter test --no-pub test\category_comics_page_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`
- `git diff --check`（仍只有该 worktree 已知的 LF/CRLF 提示）

继续观察但本轮不改的低置信风险：

- `findData()` 在分类源缺失时仍会 throw；这通常发生在路由参数已经失效或源被删除后，是否需要改为错误页要单独验证
  分类入口和导航栈行为，本轮只修已确认的异步 options loader 漏异常。
- `CategoryComicsPage` 的 `data.load()` 由 `ComicList` 统一承载错误处理；本轮不重复改分页加载语义。

## 2026-06-05 第五十五轮全项目审查

本轮继续不限于未提交 diff，对上一轮搜索结果页源缺失修复做闭环审计。页面主体已经在源缺失或源不支持搜索时返回
`NetworkError`；高置信残留风险在搜索结果页的设置 dialog 和搜索建议输入回调：`buildSearchOptions()`、
`validateOptions()`、`onChanged()` 仍存在 `ComicSource.find(searchTarget)!` 或 `searchPageData!` 断言。若用户在
搜索结果页打开期间删除/禁用搜索源，或源变成不支持搜索，这些同步 UI 路径仍可能空指针崩溃。

新增修复：

- 新增 `resolveSearchSettingsOptions()`，复用 `resolveSearchResultSourceError()` 判断搜索设置 dialog 是否还能读取
  search options；源缺失或不支持搜索时返回 null。
- `_SearchSettingsDialogState.buildSearchOptions()` 不再直接空断言 `ComicSource.find(searchTarget)!`，源失效时显示错误文本，
  不再打崩 dialog。
- 搜索设置 dialog 的源列表过滤掉没有 `searchPageData` 的源；切换源时直接使用当前 `ComicSource` 实例的 options，
  避免重复查找并空断言。
- `SearchResultPage.validateOptions()` 和 `onChanged()` 改为 nullable 源解析；源失效时不再校验 options 或构建建议 overlay，
  并主动移除已有建议 overlay。

新增/扩展测试：

- `test/search_options_test.dart` 覆盖搜索设置 options 只有源存在且支持搜索时才返回 options；源缺失、不支持搜索返回 null。

追加验证：

- `flutter test --no-pub test\search_options_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`
- `git diff --check`（仍只有该 worktree 已知的 LF/CRLF 提示）

继续观察但本轮不改的低置信风险：

- `_SuggestionsController` 持有创建时的 `sourceKey`，如果用户在 dialog 中切换搜索源后不重新创建 controller，标签建议仍按旧源
  插入规则处理；这更偏语义一致性，需要真实使用流验证，本轮只修源失效导致的崩溃。
- `AggregatedSearchPage` 的源列表热更新仍列为后续低置信项，等待更完整页面流证据。

## 2026-06-05 第五十六轮全项目审查

本轮继续不限于未提交 diff 审查漫画源更新入口。高置信风险落在漫画源更新状态残留：`availableUpdates` getter 返回的是
内部 map 的拷贝，旧代码通过 `ComicSourceManager().availableUpdates.remove(source.key)` 并不会真正清掉更新状态；
同时更新弹窗和批量更新循环会对残留 key 执行 `ComicSource.find(key)!`。如果源在检查更新后被删除、重载失败或变更为不可用，
打开更新弹窗或点击更新可能空指针崩溃，并且成功更新后的提示也可能反复残留。

新增修复：

- `ComicSourceManager` 新增 `removeAvailableUpdates()`，真正删除内部 `_availableUpdates` 并只在有变化时通知监听器。
- `ComicSourcePage.update()` 更新成功后改用 `removeAvailableUpdates([source.key])`，不再修改 getter 拷贝。
- 新增 `filterAvailableComicSourceUpdates()`，更新弹窗先过滤仍存在的源，并清理 stale key；没有 live update 时显示
  `"No updates"`，不进入空列表进度逻辑。
- 更新弹窗文本构造和实际更新循环均移除 `ComicSource.find(...)!`，源在弹窗打开前后变为 null 时跳过并清理残留 key。

新增/扩展测试：

- `test/comic_source_list_test.dart` 覆盖漫画源更新过滤会丢弃 stale source key。
- `test/comic_source_list_test.dart` 覆盖 `removeAvailableUpdates()` 会真正清理 manager 内部更新状态，而不是只修改拷贝。

追加验证：

- `flutter test --no-pub test\comic_source_list_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`
- `git diff --check`（仍只有该 worktree 已知的 LF/CRLF 提示）

继续观察但本轮不改的低置信风险：

- `headless.dart` 的 `updatescript all` 已对 `ComicSource.find(key)` 做 null 检查，不会走同样空断言；但它的 total 仍按
  原始 `availableUpdates.length` 计算，存在进度统计包含 stale key 的语义偏差。本轮只修 GUI 崩溃与状态清理，后续可结合
  headless 输出契约单独调整。
- 首页更新数已经按 `ComicSource.find(key)` 和 `compareSemVer` 过滤，不会展示已删除源；现在 manager 会清理残留状态，后续可继续
  观察是否需要在源删除动作中也主动清理更新状态。

## 2026-06-05 第五十七轮全项目审查

本轮继续不限于未提交 diff 审查搜索入口。上一轮已经修复搜索结果页在源缺失/不支持搜索时的空断言风险；高置信残留风险在
`SearchPage` 本身：页面保存的 `searchTarget` 和 `searchSources` 可能在漫画源热删除、重载失败或设置变化后变成 stale。
原 `currentSearchPageData`、`findSuggestions()` 和 `buildSearchTarget()` 会执行 `ComicSource.find(searchTarget)!` 或
`ComicSource.find(e)!`，用户在搜索页输入、切换目标源或触发搜索建议时可能直接空指针崩溃。

新增修复：

- 新增 `resolveSearchPageData()`，当前搜索源为空或查不到 search data 时返回 null，便于纯函数测试搜索页降级决策。
- `currentSearchPageData` 改为 nullable；`buildSearchOptions()` 在源失效时清空 options 并隐藏选项区域，不再空断言。
- `findSuggestions()` 在当前源失效或不允许标签建议时只刷新现有 URL/ID 建议，不再读取 `enableTagsSuggestions` 的空断言路径。
- `buildSearchTarget()` 重新解析并过滤仍存在且支持搜索的源；列表中残留 stale key 时不再崩溃。

新增/扩展测试：

- `test/search_options_test.dart` 覆盖搜索页 helper：空 source key、缺失源数据返回 null，正常 search data 原样返回。

追加验证：

- `flutter test --no-pub test\search_options_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`
- `git diff --check`（仍只有该 worktree 已知的 LF/CRLF 提示）
- `rg "ComicSource\.find\(searchTarget\)!|currentSearchPageData\.searchOptions|searchSources\.map\(\(e\) => ComicSource\.find\(e\)!" lib\pages\search_page.dart`
  未命中。

继续观察但本轮不改的低置信风险：

- `SearchPage.search()` 在 stale `searchTarget` 下仍可能导航到 `SearchResultPage`；搜索结果页现在会显示 `NetworkError` 而不是崩溃。
  是否要在搜索页直接拦截并提示，需要更完整 UX 决策，本轮只修同步空断言稳定性风险。
- 聚合搜索页仍持有初始化时的源列表；源热删除后的语义刷新继续保留为低置信观察项，等待实际页面流证据。

## 2026-06-05 第五十八轮全项目审查

本轮继续不限于未提交 diff 审查 JS bridge。聚合搜索页源热删除项复核后仍缺少直接崩溃证据：页面初始化时持有的是已解析的
`ComicSource` 对象，而不是后续反复按 stale key 空断言查找。本轮没有硬改该低置信项。高置信风险转移到 `JsEngine`
的外部脚本消息入口：漫画源脚本可以异步发送 `save_data` / `isLogged`，如果脚本回调晚到而对应源已经删除或重载失败，
旧代码会执行 `ComicSource.find(key)!` / `ComicSource.find(message["key"])!`，导致 JS bridge 直接空指针崩溃。

新增修复：

- `save_data` 消息改为先解析 nullable source；源缺失时直接忽略该晚到写入，不再空断言。
- `isLogged` 消息通过 `resolveSourceLoginStateForJs()` 解析登录态；源缺失时返回 false，保留源存在时的原 `isLogged` 语义。
- `save_data` / `delete_data` 写入改用既有后台保存路径，避免 JS bridge 同步等待磁盘写入。
- 新增 `shouldHandleSourceDataMessage()` / `resolveSourceLoginStateForJs()` 测试 hook，覆盖源缺失和登录过期两类决策。

新增/扩展测试：

- 新增 `test/js_engine_stability_test.dart`，覆盖源缺失时 JS source data 消息会被忽略。
- 新增 `test/js_engine_stability_test.dart`，覆盖源缺失时 JS 登录态返回 false，源存在、已登录和登录过期语义保持正确。

追加验证：

- `flutter test --no-pub test\js_engine_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`
- `git diff --check`（仍只有该 worktree 已知的 LF/CRLF 提示）
- `Select-String -Path lib\foundation\js_engine.dart -Pattern 'ComicSource.find(key)!' -SimpleMatch` 未命中。

继续观察但本轮不改的低置信风险：

- `ComicSourceParser` 内部闭包仍存在多处 `_key!`，但这些闭包由 parser 在完成 key 解析后生成，缺少同等明确的 stale-source
  外部回调证据。本轮不做无证据重构。
- 聚合搜索页源列表热更新仍保留为观察项；当前证据更偏 UX 刷新语义，而不是确定崩溃。

## 2026-06-05 第五十九轮全项目审查

本轮继续不限于未提交 diff 审查漫画详情页。详情页主体加载已经能在源缺失时返回 `Comic source not found`，但页面打开后如果用户
删除/重载漫画源，已显示的详情页仍会在 actions、信息区、缩略图延迟加载和收藏面板里继续读取 `comicSource`。旧代码包含
`ComicSource.find(comic.sourceKey)!`、`widget.type.comicSource!` 以及多处非空 `comicSource.loadComicThumbnail` / `commentsLoader`
访问，用户点击下载、点赞、评论、评分、收藏，或 deferred thumbnails rebuild 时可能空指针崩溃。

新增修复：

- `ComicPage` 新增 `shouldEnableComicPageSourceAction()`，统一描述源依赖动作只有 live source 存在时才可用。
- `_ComicPageActions.comicSource` 改为 nullable；下载、点赞、评论、评分等依赖源的动作入口先解析 live source，源缺失时提示
  `"Comic source not found"` 并返回。
- 信息区、评论按钮、收藏状态后台刷新和缩略图区块改为 nullable source；源缺失时禁用翻译/网络评论/远程缩略图加载，不再在
  rebuild 或延迟加载阶段崩溃。
- `_FavoritePanel` 的网络收藏源改为 nullable；源缺失时仍保留本地收藏区，网络收藏区不创建，避免 `widget.type.comicSource!`
  空断言。
- 顺手补齐 like/archive/star rating 的 mounted/request guard，避免相关异步回包在页面关闭或请求失效后落地。

新增/扩展测试：

- `test/comic_page_favorite_status_test.dart` 覆盖 `shouldEnableComicPageSourceAction()`：源缺失返回 false，源存在返回 true。

追加验证：

- `flutter test --no-pub test\comic_page_favorite_status_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock`
- `git diff --check`（仍只有该 worktree 已知的 LF/CRLF 提示）
- `Select-String -Path lib\pages\comic_details_page\*.dart -Pattern 'ComicSource.find(comic.sourceKey)!','type.comicSource!','state.comicSource.loadComicThumbnail','comicSource.commentsLoader','comicSource.enableTagsTranslate','comicSource.key' -SimpleMatch`
  未命中。

继续观察但本轮不改的低置信风险：

- `_FavoritePanel` 源缺失时只保留本地收藏能力；是否额外显示网络收藏不可用提示属于 UX 取舍，本轮只修崩溃。
- `ComicSourceParser` 内部 `_key!` 仍保持第五十八轮结论：缺少外部 stale-source 回调证据，本轮不做无证据重构。

## 2026-06-05 第六十轮全项目审查

本轮继续不限于未提交 diff 审查 JS HTML bridge。第五十八轮已经修掉 source data / 登录态 stale source 空断言，但
`handleHtmlCallback()` 仍对 `_documents[...]!`、`elements[key]`、`nodes[key]` 做直接索引。HTML 文档缓存超过 8 个会主动淘汰
最旧文档，脚本也可能在 dispose 后继续持有旧 doc / element / node 句柄；这属于漫画源外部脚本可触发的高置信崩溃面。

新增修复：

- `handleHtmlCallback()` 新增安全文档句柄解析；文档不存在时记录 `JS Engine` warning，并按函数语义返回 null、空列表、
  空属性 map 或 `"unknown"`，不再通过 `_documents[...]!` 崩溃。
- `parse` 消息校验 doc key 和 HTML 内容类型，非法消息直接忽略并记录 warning，避免外部脚本传入坏形状时污染文档缓存。
- `DocumentWrapper` 为 element / node 句柄增加边界检查 helper；坏下标或非 int key 不再触发 `RangeError`，查询类返回空值或空集合。

新增/扩展测试：

- `test/js_engine_stability_test.dart` 覆盖 HTML 文档 dispose 后继续 query / getText 不崩溃。
- `test/js_engine_stability_test.dart` 覆盖 stale element / node 句柄返回空值、空集合或 `"unknown"`。

追加验证：

- `flutter test --no-pub test\js_engine_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `rg "_documents\[[^\n]+\]!|elements\[[^\n]+\]\.|nodes\[[^\n]+\]\." lib\foundation\js_engine.dart` 未命中危险直接访问；
  剩余 `return elements[key]` / `return nodes[key]` 仅存在于通过边界检查后的 `_elementAt()` / `_nodeAt()` helper 内。

继续观察但本轮不改的低置信风险：

- `ComicSourceParser` 内部 `_key!` 仍缺少外部 stale 回调证据，继续保留观察。
- `aggregated_search_page.dart` 的源列表构造仍更像初始化时当前源快照，暂不做无证据行为改动。

## 2026-06-05 第六十一轮全项目审查

本轮继续不限于未提交 diff 审查下载恢复和漫画详情页归档下载入口。`ImagesDownloadTask.fromJson()` 已经会在源缺失时跳过坏任务，
但 `ArchiveDownloadTask` 的公开构造入口仍会执行 `ComicSource.find(comic.sourceKey)!`。用户在详情页打开归档下载对话、等待下载
URL 返回期间删除或重载漫画源，或者恢复旧下载快照时遇到 stale source，都可能在任务构造阶段直接崩溃。

新增修复：

- `ArchiveDownloadTask` 新增 `tryCreate()`；归档 URL 为空或漫画源已不存在时返回 null，不再空断言崩溃。
- 保留原 `ArchiveDownloadTask(...)` factory，源缺失时抛明确 `StateError('Comic source not found: ...')`，避免隐藏调用点静默创建坏任务。
- `ArchiveDownloadTask.fromJson()` 和漫画详情页归档下载确认入口改用 `tryCreate()`；恢复快照会跳过 stale source 归档任务，详情页会提示
  `"Comic source not found"` 并关闭对话，不把坏任务加入下载队列。

新增/扩展测试：

- `test/local_manager_test.dart` 覆盖归档下载快照恢复时 stale source 行被跳过、有效行保留。
- `test/local_manager_test.dart` 覆盖 `ArchiveDownloadTask.tryCreate()` 缺源返回 null、有效源正常创建，以及保留构造器缺源时抛
  `StateError`。

追加验证：

- `flutter test --no-pub test\local_manager_test.dart --reporter=compact`
- `flutter test --no-pub test\comic_page_favorite_status_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。
- `rg "ArchiveDownloadTask\(|ComicSource\.find\(comic\.sourceKey\)!|ArchiveDownloadTask\.tryCreate" lib test -n` 确认唯一直接构造保留在
  factory 和测试错误路径，UI / JSON 恢复入口均走 `tryCreate()`。

继续观察但本轮不改的低置信风险：

- `ComicSourceParser` 内部 `_key!` 仍缺少与用户操作直接相关的 stale 回调证据，本轮不做无证据重构。
- `aggregated_search_page.dart` 的源快照构造仍保持观察，缺少确定崩溃路径。

## 2026-06-05 第六十二轮全项目审查

本轮继续不限于未提交 diff 审查 Android 启动/日志初始化路径。`App.init()` 在 Android 上对
`getExternalStorageDirectory()` 返回值直接 `!`，而该目录在设备状态、权限或外部存储不可用时可能为空；随后 `Log.addLog()`
也会用 `App.externalStoragePath!` 打开日志文件。若发生在冷启动、久置恢复后的首条日志或错误日志阶段，会把本该可降级的路径问题
升级成启动/恢复崩溃。

新增修复：

- `App.init()` 增加 `resolveAndroidExternalStoragePath()`；Android external storage 不可用时回退到 `dataPath`，不再空断言。
- `Log.addLog()` 增加 `resolveLogDirectoryPath()`；Android 日志目录为空时回退到 `dataPath`。
- 日志文件打开失败时只打印 warning 并继续保留内存日志，不再让任意日志调用拖垮应用。

新增/扩展测试：

- `test/app_locale_test.dart` 覆盖 Android external storage 为空/空字符串时回退到 app data path。
- `test/app_locale_test.dart` 覆盖 Android / 非 Android 日志目录选择 fallback。

追加验证：

- `flutter test --no-pub test\app_locale_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。
- `rg "externalStoragePath!|getExternalStorageDirectory\(\)!|getExternalStorageDirectory\(\)\!" lib test -n` 未命中。

继续观察但本轮不改的低置信风险：

- `aggregated_search_page.dart` 仍有 `ComicSource.find(e)!`，但它先从当前 live source 列表同步过滤 settings，缺少用户可触发的 stale
  空断言窗口，本轮只保留观察。
- `import_comic.dart` 的 `pathMap[c.directory]!` 依赖同一次复制 helper 的返回 map；目前更像异常路径防御性改进，缺少 P1 证据。
- `NetworkFavoritePage` 的 `folders![keys[i]]!` 是同一帧从同一个 map 派生 key/value，暂不做无证据改动。

## 2026-06-05 第六十三轮全项目审查

本轮继续不限于未提交 diff 审查 headless/follow updates、app link/text share、下载任务恢复、网络缓存和外部图片配置解析。
`headless.dart` 的 `progress.comic!` 已由同一作用域 `progress.comic != null` 保护；follow updates 页面已有 requestId/mounted
guard；下载任务恢复快照已有边界校验，运行态异常也会落到下载错误态；网络缓存已有 key/header/HEAD 合并与失败 fallback 测试。

本轮确认的高置信风险在详情页缩略图：`_ComicThumbnails` 使用 `CachedImageProvider(thumbnail.url, sourceKey: ...)`
时没有传入当前漫画 id。若漫画源的 `getThumbnailLoadingConfig()` 把缩略图 URL 重写为 `cover.*`，`ImageDownloader.loadThumbnail()`
会进入“通过漫画详情加载真实封面”的分支；旧逻辑直接调用 `loadComicInfo!(cid!)`，在缺 `cid` 或缺 loader 时可由源配置/详情页预览图路径触发空断言，
表现为图片加载期间崩溃或详情页恢复后缩略图刷新闪退。

新增修复：

- 详情页缩略图 `CachedImageProvider` 传入 `cid: state.comic.id`，让 `cover.*` 重定向能拿到稳定漫画 id。
- `ImageDownloader` 新增 `shouldRedirectThumbnailToComicCover()` 测试 helper；只有 `cover.*`、sourceKey、非空 cid 和
  `loadComicInfo` 同时存在时才执行封面重定向。
- 缺少 cid 或 loader 时记录 `Network` warning，并移除坏 `url` 配置继续走原缩略图 URL 请求，不再空断言崩溃。

新增/扩展测试：

- `test/reader_image_cache_strategy_test.dart` 覆盖缩略图封面重定向必须具备 comic id 和 info loader，缺任一条件不允许进入重定向分支。

追加验证：

- `flutter test --no-pub test\reader_image_cache_strategy_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `headless.dart` 的进度输出空断言已由局部 null guard 保护，未发现异步突变窗口。
- `FollowUpdatesService` 取消后 finally 可能触发一次全局 UI 刷新，但目标 state 查找使用 `GlobalState.findOrNull`，且页面刷新有
  mounted/folder guard，本轮不做无证据改动。
- `App.rootContext` 直接使用点很多，但多数来自已挂载 UI 点击事件；没有确认的启动/恢复空 root context 触发路径，本轮不做大范围 API 改造。

## 2026-06-05 第六十四轮全项目审查

本轮继续不限于未提交 diff 审查 `loadComicInfo!`、下载任务恢复、本地库/CBZ/PDF/EPUB 导入导出、`appdata`/同步导入、
以及配置驱动页面列表。`ComicDetailsRepository` 已对缺源/缺 `loadComicInfo` 返回错误；下载任务缺 loader 会被 `_runWithRetry`
收敛到下载错误态；CBZ、本地库 row、appdata 和同步导入已有 normalization；PDF/EPUB 的强制访问多来自内部同一 map/同一 isolate 协议，
缺少外部坏数据可直接打穿的 P1 证据。

本轮确认的高置信风险在分类页旧配置恢复：`CategoriesPage.initState()` 先把 `appdata.settings["categories"]` 过滤为当前仍存在的分类，
但旧逻辑创建 `TabController` 时使用的是过滤前本地变量 `categories.length`。当用户删除/重载漫画源后设置里残留 stale 分类，
页面实际 tabs/children 使用过滤后的列表，而 controller 长度使用过滤前长度，进入分类页即可触发 Flutter tab 长度不一致断言或页面异常。

新增修复：

- 新增 `normalizeEnabledCategoryPages()`，统一按当前可用分类过滤设置中的分类列表。
- `CategoriesPage.initState()` 改为使用过滤后的 `this.categories.length` 初始化 `TabController`。
- `onSettingsChanged()` 继续使用同一 helper，避免初始化和后续源变化逻辑分叉。

新增/扩展测试：

- `test/category_random_test.dart` 覆盖 stale 分类会被过滤，只保留当前可用分类。

追加验证：

- `flutter test --no-pub test\category_random_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `ExplorePage` 也按当前源过滤旧 explore pages，但初始化 controller 已使用过滤后的 `pages.length`，未发现同类长度错配。
- PDF isolate 消息处理仍有内部协议假设，但消息来源是本地 isolate 创建流程；缺少外部坏文件直接触发未知消息并挂死的证据。
- `App.rootContext` 和大量 UI 分支空断言仍保留观察；本轮未找到和启动/恢复/自动任务直接重合的确定空 root context 路径。

## 2026-06-05 第六十五轮全项目审查

本轮继续横向审查配置驱动页面、`TabController` / `NaviPane` 初始化、Favorites 侧栏和默认搜索源等旧配置恢复路径。分类页长度错配已在第六十四轮修复；
`ExplorePage` 的 controller 初始化已使用过滤后的 `pages.length`；Favorites 侧栏会按当前源过滤网络收藏页；默认搜索源会在 live source
列表中校验后才使用。

本轮确认的高置信风险在主页面启动：`MainPage.initState()` 直接从 `appdata.settings["initialPage"]` 解析整数并传给 `NaviPane`。
`NaviPane` 内部会用 `currentPage` 直接索引 `paneItems[currentPage]`，主页面 `pageBuilder` 也会用同一个 index 访问 `_pages[index]`。
如果同步数据、旧配置或手工编辑把 `initialPage` 写成 `-1`、`4`、`99` 或非数字，在应用启动进入主页面时即可越界崩溃。

新增修复：

- 新增 `resolveInitialMainPageIndex()`；只有页数范围内的非负整数才作为初始页，malformed、负数、越界值全部回退到 0。
- `MainPage.initState()` 使用真实 `_pages.length` 校验 `initialPage`，避免 `NaviPane` 和 `_pages` 直接索引越界。

新增/扩展测试：

- `test/home_page_test.dart` 覆盖有效初始页、非数字、负数、等于页数、超大页码和空页面数。

追加验证：

- `flutter test --no-pub test\home_page_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `NaviPane.updatePage(index)` 仍假设调用方传入合法 index，但公开调用来自生成的 pane item tap，index 由 `paneItems.length` 生成，缺少外部坏输入路径。
- `FavoritesPage.initState()` 对 local stale folder 已清理；network stale folder 在 `buildBody()` 中发现缺 `favoriteData` 后回退 `folder = null`，暂不做行为改动。
- `aggregated_search_page.dart` 的 `ComicSource.find(e)!` 仍保持低置信观察：当前构造参数来源已经由 live source 列表过滤。

## 2026-06-05 第六十六轮全项目审查

本轮继续不限于未提交 diff 审查 Reader 初始页、图片收藏查看器、连续/画廊模式 `PageController` /
`ScrollablePositionedList` 初始化、收藏页 stale 状态和页面跳转入口。图片收藏查看器当前已默认把缺失目标图落到第 0 页；
主页面 `initialPage` 已在第六十五轮收敛；本轮确认的高置信风险集中在 Reader 历史页恢复。

风险：

- `ReaderWithLoading` 会把外部入口页或历史 `history.page` 传给 `Reader.initialPage`，Reader 只做了下限归一。
- 章节图片加载完成前并不知道真实 `maxPage`；如果同步数据、旧历史或手工数据把页码写成远大于当前章节图片数的值，
  画廊模式会用该值创建 `PageController(initialPage: reader.page)`，连续模式会用该值作为 `initialScrollIndex`。
- 这会让阅读器从超出 `itemCount` / 真实图片范围的位置启动，表现为恢复阅读时空白、卡住、首个翻页异常，或后续图片范围计算被越界页污染。

新增修复：

- 新增 `normalizeReaderPageForLoadedImages()`；在章节图片加载完成且真实 `maxPage` 可用后，把 Reader 当前页收敛到 `1..maxPage`。
- `_handleJumpToLastPage()` 保留“切上一章跳最后一页”的既有语义；非跳最后一页场景统一用真实页数夹住旧历史/入口页。
- 修复位置保持在 Reader 内部，不要求各个入口分别防御，不改变用户可见设置、漫画源 JS API 或历史数据格式。

新增/扩展测试：

- `test/reader_history_page_test.dart` 覆盖正常页、最后页、超大 stale 页、0、负数和空章节页数的归一结果。

追加验证：

- `flutter test --no-pub test\reader_history_page_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- 图片收藏查看器当前目标图缺失时已经默认从第 0 页打开，暂未发现能把 `-1` 传给 `PageController` 的路径。
- Reader `setPage()` 仍假设调用方传合法页，但公开翻页入口会走 `_validatePage()`；本轮不做全局 setter 行为改动。
- 连续模式 `initialScrollIndex` 仍依赖 `reader.page`，但本轮已在图片加载后、组件初始化前按真实 `maxPage` 收敛。

## 2026-06-05 第六十七轮全项目审查

本轮继续不限于未提交 diff 审查设置页、详情页、搜索/聚合页、Reader 章节页和各类 `PageController` /
`TabController` / list index 初始化路径。Reader 历史页越界已在第六十六轮修复；本轮确认的高置信风险在设置页初始页恢复。

风险：

- `SettingsPage.initialPage` 是公开构造参数，`SettingsPage` 初始化时直接把它写入 `currentPage`。
- 双栏模式下 `buildRight()` 只特殊处理 `-1`，其余值直接进入 `_buildSettingsContent(currentPage)`；`8`、`99`、负数等异常值会进入
  `throw UnimplementedError()`，表现为打开设置页或恢复设置页时崩溃。
- 移动端 `_SettingsDetailPage` 目前只由合法列表点击创建，但内部也有同样的默认 `throw UnimplementedError()`，未来入口复用或状态恢复时风险相同。

新增修复：

- 新增 `normalizeSettingsPageIndex()`，保留 `-1` 作为双栏“未选中”语义，其余只允许 `0..pageCount-1`。
- `SettingsPage.initState()` 和双栏 `buildRight()` 都先归一化页码，异常值不再进入未实现分支。
- 新增 `buildSettingsPageContent()`，详情页和双栏共用同一内容入口；异常详情页 index 默认回到 Explore 设置页，不再抛出崩溃。

新增/扩展测试：

- `test/settings_components_test.dart` 覆盖 `-1`、合法页、字符串页、越界页、非数字、`allowUnset: false` 和空 pageCount 场景。

追加验证：

- `flutter test --no-pub test\settings_components_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `AggregatedSearchPage` 的 `ComicSource.find(e)!` 仍由调用方传入 sources；当前已知调用路径会先从 live source 列表过滤，暂未找到 stale source 可直接进入构造器的窗口。
- 详情页章节和 Reader 章节列表的 `elementAt(index)` 来自 builder 的合法 index 或当前章节边界，缺少外部坏状态直接触发的路径。
- `SettingComponents` 中 option map 的 `optionTranslation[key]!` 依赖开发期成对配置；这是配置完整性风险，但不是当前可由用户状态恢复触发的 P1。

## 2026-06-05 第六十八轮全项目审查

本轮继续不限于未提交 diff 审查 Reader 初始章节、分类/搜索过滤器 option index、详情页章节列表和分组章节抽屉。
分类和搜索 option 的 index 来自当前控件 values；详情页/Reader 章节列表 builder index 来自当前 childCount。确认的高置信风险仍在 Reader
历史恢复路径，和第六十六轮页码越界属于同一类旧状态污染问题。

风险：

- `ReaderWithLoading` 会把外部入口 `initialEp` 或历史 `history.ep` / `history.group` 传给 `Reader.initialChapter` /
  `Reader.initialChapterGroup`。
- `Reader.initState()` 之前只把章节号下限收敛到 1；普通章节没有按 `chapters.length` 收敛，旧历史章节号大于当前源章节数时会进入越界章节。
- 分组章节路径更危险：只要 `initialChapterGroup != null` 就会访问 `widget.chapters!.getGroupByIndex(i)`。如果历史 group
  过期、漫画从分组变为非分组、章节为空或 group 超出当前分组数，Reader 初始化阶段即可崩溃，常见触发点是漫画源重载/同步旧历史后恢复阅读。

新增修复：

- 新增 `normalizeReaderInitialChapter()`，统一处理普通章节、分组章节、空章节、缺 chapters、过期 group 和过期 ep。
- 普通章节按 `1..chapters.length` 收敛；无 chapters 或空章节回退到 1。
- 分组章节仅在当前 chapters 仍为 grouped 且 group 合法时转换为绝对章节号；group 过期回退到 1，group 内 ep 过大收敛到该组最后一章。
- `Reader.initState()` 删除直接 `getGroupByIndex()` 的循环，改用 helper，避免初始化阶段被旧历史打穿。

新增/扩展测试：

- `test/reader_loading_test.dart` 覆盖普通章节合法/超大/负数/null chapters。
- `test/reader_loading_test.dart` 覆盖 grouped 章节合法转换、组内 ep 过大、group 过期和非 grouped chapters 携带 group 的兼容路径。

追加验证：

- `flutter test --no-pub test\reader_loading_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `CategoryComicsPage` 和 `SearchPage` dropdown 的 `elementAt(index)` index 来自当前 Select values，暂未发现外部 stale index 可进入回调。
- `ComicChapters.length` 对空 grouped map 会 reduce 失败，但 `ComicChapters.fromJson` 会把空输入转成 flat empty chapters；直接构造空 grouped
  只见测试/内部构造风险，本轮不改模型语义。
- Reader 章节抽屉的 `elementAt(index)` 仍依赖当前 builder childCount，初始化章节已在本轮先收敛。

## 2026-06-05 第六十九轮全项目审查

本轮继续不限于未提交 diff 审查聚合搜索、漫画源更新列表、收藏页恢复状态、隐式数据 normalization 和收藏导入。
聚合搜索当前会先用 live source key 过滤 settings；漫画源更新列表的 `versions[key]!` key 来自同一轮 `shouldUpdate`；
本轮确认的高置信风险在收藏页 `implicitData['favoriteFolder']` 子结构恢复。

风险：

- `normalizeImplicitData()` 只保证 `implicitData` 根是 Map，不校验每个字段的子结构。
- `FavoritesPage.initState()` 之前直接读取 `appdata.implicitData['favoriteFolder']` 后访问 `data['name']`、`data['isNetwork']`。
- 如果同步数据、旧文件、手工编辑或异常写入把 `favoriteFolder` 写成字符串、列表、数字，进入收藏页会因对非 Map 使用 `[]` 触发运行时异常。
- 如果 `name` / `isNetwork` 类型漂移，也可能让页面恢复到不一致的 folder/network 状态，表现为收藏页打开闪退或选中状态异常。

新增修复：

- 新增 `normalizeFavoriteFolderSelection()`，只接受 Map 子结构；坏结构、空 name、非字符串 name 都回到未选中。
- `isNetwork` 复用 `normalizeBoolSetting()`，支持 bool、数字和常见字符串布尔，避免同步类型漂移。
- `FavoritesPage.initState()` 改为使用 helper 恢复状态；本地收藏 stale folder 的现有存在性检查保持不变。

新增/扩展测试：

- `test/favorite_item_test.dart` 覆盖 null、字符串坏结构、空 name、合法本地 folder、字符串 true 和数字 1 的网络 folder 恢复。

追加验证：

- `flutter test --no-pub test\favorite_item_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `AggregatedSearchPage` 的 `ComicSource.find(e)!` 仍保留观察；当前构造前已经按 `ComicSource.all()` live keys 过滤 settings。
- `ComicSourcePage.checkComicSourceUpdate()` 的 `versions[key]!` 来自同一次 `versions.containsKey(source.key)` 筛出的 `shouldUpdate`，暂未发现外部坏数据越过检查。
- `import_comic.dart` 的 favorite folder map 强访问依赖同一 helper 生成的 map，仍缺少独立 P1 触发证据。

## 2026-06-05 第七十轮全项目审查

本轮继续不限于未提交 diff 审查图片收藏页的恢复状态、过滤器持久化和异步 UI 入口。
确认的高置信风险集中在 `implicitData` 中图片收藏筛选字段的子类型漂移。

风险：

- `normalizeImplicitData()` 只校验 `implicitData` 根结构，不能保证每个页面私有字段类型仍符合预期。
- `ImageFavoritesPage.initState()` 之前直接把 `image_favorites_time_filter` 交给 `TimeRange.fromString(String?)`，并把 `image_favorites_number_filter` 赋给 `late int`。
- 如果同步数据、旧版本数据、手工编辑或异常写入把时间过滤写成数字/列表，或把数量过滤写成字符串、列表、非法数字，打开图片收藏页可能在初始化时触发运行时异常。
- 数量过滤如果把非整数数字截断成合法档位，也会把脏数据误解释为有效筛选，导致页面恢复状态不可预测。

新增修复：

- `TimeRange.fromString()` 改为接受 `Object?`，仅解析合法字符串；非字符串、格式错误、负 duration、非法 timestamp 全部回退 `TimeRange.all`。
- 新增 `normalizeImageFavoriteNumberFilter()`，只接受 `numFilterList` 中的合法整数档位；非整数数字、非法字符串和坏结构全部回退默认值。
- `ImageFavoritesPage.initState()` 使用 helper 恢复数量过滤，避免坏数据击穿 `late int`。

新增/扩展测试：

- `test/image_favorites_filter_test.dart` 覆盖非字符串 time filter、格式错误 time filter、负 duration。
- `test/image_favorites_filter_test.dart` 覆盖 null、int、整数 double、非整数 double、字符串、坏字符串、非法数字和列表的 number filter normalization。

追加验证：

- `flutter test --no-pub test\image_favorites_filter_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- 图片收藏页已有的自定义时间范围确认按钮禁用和 date picker mounted guard 保持观察；当前测试已覆盖纯函数决策。
- `TimeRange.contains()` 使用运行时 `DateTime.now()` 是既有语义，本轮不改变时间过滤行为。

## 2026-06-05 第七十一轮全项目审查

本轮继续不限于未提交 diff 审查 `implicitData` 恢复路径、同步坏数据进入页面 init 的强类型字段，以及本地收藏筛选弹窗。
`lastCheckUpdate` 的坏类型当前会被自动更新检查外层 catch 记录，暂不作为 P1 修复；本轮确认的高置信风险在本地收藏 read filter。

风险：

- `normalizeImplicitData()` 只保证根结构是 Map，不能保证 `local_favorites_read_filter` 仍为合法字符串枚举。
- `_LocalFavoritesPageState.initState()` 之前直接把 `appdata.implicitData["local_favorites_read_filter"] ?? readFilterList[0]` 赋给 `late String readFilterSelect`。
- 如果同步数据、旧版本数据、手工编辑或异常写入把该字段写成数字/列表/非法字符串，打开本地收藏页可能在初始化时触发运行时类型错误，或恢复到不可达过滤状态。
- `_LocalFavoritesFilterDialog` 实际只有一个 tab/child，但 `DefaultTabController(length: 2)` 固定为 2，打开筛选弹窗时存在 tab 数量不一致导致断言/状态异常的明确风险。

新增修复：

- 新增 `normalizeLocalFavoritesReadFilter()`，只接受 `readFilterList` 内的合法值，其余全部回退 `All`。
- `_LocalFavoritesPageState.initState()` 使用 helper 恢复 read filter，避免坏同步数据击穿页面初始化。
- `_LocalFavoritesFilterDialog` 的 `DefaultTabController.length` 改为 `optionTypes.length`，与实际 tab/child 数保持一致。

新增/扩展测试：

- `test/favorite_item_test.dart` 覆盖 null、合法枚举、非法字符串、数字和列表形式的本地收藏 read filter normalization。

追加验证：

- `flutter test --no-pub test\favorite_item_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `bootstrap.dart` 的 `lastCheckUpdate` 坏类型可能导致自动更新检查被 catch 后跳过，但没有直接页面闪退证据，本轮先记录观察。
- Cloudflare `implicitData['ua']` 坏类型当前会在 Dio header 层表现为请求问题，尚未确认直接稳定性 P1。

## 2026-06-05 第七十二轮全项目审查

本轮继续不限于未提交 diff 审查本地页面从 `implicitData` 恢复状态的强类型入口。
确认的高置信风险在本地漫画页排序字段恢复。

风险：

- `LocalComicsPage.initState()` 之前直接读取 `appdata.implicitData["local_sort"] ?? "name"`，并传给 `LocalSortType.fromString(String)`。
- 如果同步数据、旧版本数据、手工编辑或异常写入把 `local_sort` 写成数字、列表或其他非字符串，打开本地漫画页会在初始化时触发运行时类型错误。
- 非法字符串虽然会由 `LocalSortType.fromString()` 回退，但非字符串不会进入该兜底，导致恢复路径不一致。

新增修复：

- 新增 `normalizeLocalComicsSortType()`，只把字符串传入 `LocalSortType.fromString()`；非字符串统一回退 `LocalSortType.name`。
- `LocalComicsPage.initState()` 使用 helper 恢复排序状态，避免坏同步数据击穿页面初始化。

新增/扩展测试：

- `test/local_comics_export_test.dart` 覆盖 null、合法排序值、非法字符串、数字和列表形式的 local sort normalization。

追加验证：

- `flutter test --no-pub test\local_comics_export_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `lastCheckUpdate` 和 Cloudflare `ua` 坏类型仍记录观察；当前没有比本地漫画页排序更明确的页面初始化崩溃证据。

## 2026-06-05 第七十三轮全项目审查

本轮继续不限于未提交 diff 审查 reader 图片加载路径中可同步 settings 的强类型入口。
确认的高置信风险在自定义图片处理开关恢复。

风险：

- `ReaderImageProvider.load()` 之前直接把 `appdata.settings['enableCustomImageProcessing']` 当作 `if` 条件使用。
- 该 settings 可能来自同步数据、旧版本数据或手工编辑；如果值漂移为字符串、数字、列表等非 bool，reader 图片加载时会触发运行时类型错误。
- 触发路径位于图片加载热路径，用户表现可能是阅读器翻页/恢复后图片加载闪退。

新增修复：

- 新增 `shouldEnableCustomImageProcessing()`，复用 `normalizeBoolSetting()` 归一化开关。
- `ReaderImageProvider.load()` 改为通过 helper 判断是否启用自定义图片处理；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退关闭。

新增/扩展测试：

- `test/reader_image_provider_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的自定义图片处理开关归一化。

追加验证：

- `flutter test --no-pub test\reader_image_provider_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- Reader 其他 settings 直接 bool 使用仍需逐一确认触发路径；本轮优先修复图片加载热路径中最直接的 P1 风险。
- Cloudflare `implicitData['ua']` 坏类型仍偏请求兼容问题，暂未升级为页面/reader 崩溃修复。

## 2026-06-05 第七十四轮全项目审查

本轮继续不限于未提交 diff 审查 reader 手势热路径中可同步 settings 的强类型入口。
确认的高置信风险在长按缩放开关恢复。

风险：

- `reader/images.dart` 的 gallery 和 continuous 两套 reader 视图之前直接使用 `!appdata.settings['enableLongPressToZoom']`。
- 该字段可能来自同步数据、旧版本数据或手工编辑；如果值漂移为字符串、数字、列表等非 bool，用户在阅读器长按/抬手时会触发运行时类型错误。
- 触发点位于 reader 手势热路径，表现会接近“恢复后操作一下闪退”或“长按图片时闪退”。

新增修复：

- 新增 `shouldEnableReaderLongPressZoom()`，复用 `normalizeBoolSetting()`，并按默认设置保持 fallback 为 true。
- `reader/images.dart` 中四处长按缩放开关判断改为通过 helper；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退默认开启。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的长按缩放开关归一化。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- Reader 里 `showSystemStatusBar`、`enableClockAndBatteryInfoInReader`、`limitImageWidth` 也存在直接 bool 使用；需要逐个确认触发面和默认值后再修，避免一次性扩大行为面。
- `quickCollectImage` 和 `longPressZoomPosition` 是字符串比较，坏类型不会直接 `if (dynamic)` 崩溃，本轮不改。

## 2026-06-05 第七十五轮全项目审查

本轮继续不限于未提交 diff 审查 reader build 热路径中的可同步 bool settings。
确认的高置信风险在阅读器状态信息开关恢复。

风险：

- `_ReaderScaffoldState.buildStatusInfo()` 之前直接使用 `if (appdata.settings['enableClockAndBatteryInfoInReader'])`。
- 该字段可能来自同步数据、旧版本数据或手工编辑；如果值漂移为字符串、数字、列表等非 bool，reader scaffold build 阶段会触发运行时类型错误。
- 触发点在阅读器渲染路径，比手势入口更早，表现可能是进入阅读器或恢复后 build 闪退。

新增修复：

- 新增 `shouldShowReaderClockAndBatteryInfo()`，复用 `normalizeBoolSetting()`，并按默认设置保持 fallback 为 true。
- `buildStatusInfo()` 改为通过 helper 判断；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退默认显示。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的阅读器状态信息开关归一化。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- Reader 里 `showSystemStatusBar`、`limitImageWidth` 仍需逐个确认默认值和触发路径后再修。
- `showPageNumberInReader == true` 已是显式比较，坏类型不会直接作为 bool 使用。

## 2026-06-05 第七十六轮全项目审查

本轮继续不限于未提交 diff 审查 reader 用户操作路径中的可同步 bool settings。
确认的高置信风险在系统状态栏开关恢复。

风险：

- `_ReaderScaffoldState.openOrClose()` 之前直接使用 `nextOpen || appdata.settings['showSystemStatusBar']`。
- 该字段可能来自同步数据、旧版本数据或手工编辑；如果值漂移为字符串、数字、列表等非 bool，用户关闭 reader 工具栏时会触发运行时类型错误。
- 触发点是阅读器常用交互，表现可能是进入 reader 后点一下/恢复后点一下就闪退。

新增修复：

- 新增 `shouldShowReaderSystemStatusBar()`，复用 `normalizeBoolSetting()`，并按默认设置保持 fallback 为 false。
- `openOrClose()` 改为通过 helper 判断；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退默认隐藏。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的系统状态栏开关归一化。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- Reader `limitImageWidth` 仍存在直接 bool 使用，但需要确认触发面、默认值和 resize 行为后再单独修。
- 其他字符串比较类 setting 坏类型不会直接 `if (dynamic)` 崩溃，本轮不改。

## 2026-06-05 第七十七轮全项目审查

本轮继续不限于未提交 diff 审查 reader 图片布局 build 路径中的可同步 bool settings。
确认的高置信风险在连续阅读模式的图片宽度限制开关恢复。

风险：

- `reader/images.dart` 之前直接使用 `appdata.settings['limitImageWidth'] && ...`。
- 该字段可能来自同步数据、旧版本数据或手工编辑；如果值漂移为字符串、数字、列表等非 bool，continuous reader 图片布局 build 阶段会触发运行时类型错误。
- 触发点在 reader 图片渲染路径，表现可能是进入连续阅读、恢复后重建或滚动到图片时闪退。

新增修复：

- 新增 `shouldLimitReaderImageWidth()`，复用 `normalizeBoolSetting()`，并按默认设置保持 fallback 为 true。
- 连续阅读图片布局中的宽度限制判断改为通过 helper；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退默认限制宽度。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的 reader 图片宽度限制开关归一化。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- Reader 中剩余字符串比较类 setting 坏类型不会直接 `if (dynamic)` 崩溃，本轮不改。
- 全局 settings 仍需按“触发路径明确、默认值明确、可测试”原则逐步审查，不一次性大扫。

## 2026-06-05 第七十八轮全项目审查

本轮继续不限于未提交 diff 审查网络初始化和恢复期请求路径中的可同步 bool settings。
确认的高置信风险在 DNS override 开关恢复。

风险：

- `RHttpAdapter._getOverrides()` 之前直接使用 `!appdata.settings['enableDnsOverrides'] == true`。
- 该字段可能来自同步数据、旧版本数据或手工编辑；如果值漂移为字符串、数字、列表等非 bool，网络请求构造 `ClientSettings` 时会触发运行时类型错误。
- 触发点在 AppDio/rhttp 请求准备阶段，可能表现为启动、恢复后首个网络操作或缓存校验时闪退。

新增修复：

- 新增 `shouldEnableDnsOverrides()`，复用 `normalizeBoolSetting()`，并按默认设置保持 fallback 为 false。
- `RHttpAdapter._getOverrides()` 改为通过 helper 判断；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退为关闭 DNS override。

新增/扩展测试：

- `test/network_init_guard_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的 DNS override 开关归一化。

追加验证：

- `flutter test --no-pub test\network_init_guard_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `sni` 和 `ignoreBadCertificate` 使用的是 `!= false` / `!= true` 显式比较，坏类型不会直接作为 bool 使用，本轮不改。
- `dnsOverrides` 本体已做 `config is Map` 和 key/value 类型过滤，坏结构不会直接崩溃，本轮不改。

## 2026-06-05 第七十九轮全项目审查

本轮继续不限于未提交 diff 审查详情页章节构建路径中的可同步 bool settings。
确认的高置信风险在章节倒序开关恢复。

风险：

- `_NormalComicChaptersState.initState()` 和 `_GroupedComicChaptersState.initState()` 之前直接使用 `appdata.settings["reverseChapterOrder"] ?? false` 赋给 `late bool reverse`。
- 该字段可能来自同步数据、旧版本数据或手工编辑；如果值漂移为字符串、数字、列表等非 bool，打开详情页章节区域时会触发运行时类型错误。
- 触发点在详情页章节初始化路径，可能表现为详情页打开、刷新详情或恢复后重建时闪退。

新增修复：

- 新增 `shouldReverseChapterOrder()`，复用 `normalizeBoolSetting()`，并按默认设置保持 fallback 为 false。
- 普通章节和分组章节初始化统一通过 helper 判断；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退为不倒序。

新增/扩展测试：

- `test/comic_page_favorite_status_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的章节倒序开关归一化。

追加验证：

- `flutter test --no-pub test\comic_page_favorite_status_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- 详情页收藏面板 `autoCloseFavoritePanel` 和 `localFavoritesFirst` 也存在 direct dynamic bool 风险；需要确认默认值、触发路径和测试落点后单独修，避免一轮扩大到多个用户行为面。
- `newFavoriteAddTo`、`moveFavoriteAfterRead`、`onClickFavorite` 等字符串比较坏类型不会直接 `if (dynamic)` 崩溃，本轮不改。

## 2026-06-05 第八十轮全项目审查

本轮继续不限于未提交 diff 审查详情页收藏面板 build 路径中的可同步 bool settings。
确认的高置信风险在本地收藏优先显示开关恢复。

风险：

- `_FavoriteListState.build()` 之前使用 `appdata.settings['localFavoritesFirst'] ?? true` 并在同一 build 中执行 `if (localFavoritesFirst)`。
- 该字段可能来自同步数据、旧版本数据或手工编辑；如果值漂移为字符串、数字、列表等非 bool，打开详情页收藏面板时会触发运行时类型错误。
- 触发点在收藏面板构建路径，可能表现为详情页点收藏、恢复后点收藏或刷新后打开收藏面板闪退。

新增修复：

- 新增 `shouldShowLocalFavoritesFirst()`，复用 `normalizeBoolSetting()`，并按默认设置保持 fallback 为 true。
- 收藏面板本地/网络收藏排序判断改为通过 helper；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退为本地收藏优先。

新增/扩展测试：

- `test/comic_page_favorite_status_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的本地收藏优先显示开关归一化。

追加验证：

- `flutter test --no-pub test\comic_page_favorite_status_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `autoCloseFavoritePanel` 仍有三处 direct dynamic bool 使用，但触发在收藏操作成功后；下一轮可按同样原则单独归一化和测试。
- `quickFavorite` 已检查 `folder is String`，坏类型会 no-op，不会直接崩溃，本轮不改。

## 2026-06-05 第八十一轮全项目审查

本轮继续不限于未提交 diff 审查详情页收藏面板操作成功路径中的可同步 bool settings。
确认的高置信风险在收藏面板自动关闭开关恢复。

风险：

- `_NetworkSectionState._buildSingleFolder()`、`_NetworkSectionState._buildMultiFolder()` 和 `_LocalSectionState.build()` 之前都直接使用 `appdata.settings['autoCloseFavoritePanel'] ?? false`。
- 该字段可能来自同步数据、旧版本数据或手工编辑；如果值漂移为字符串、数字、列表等非 bool，收藏操作成功后判断是否关闭面板时会触发运行时类型错误。
- 触发点覆盖网络单收藏、网络多文件夹收藏和本地收藏三条常用成功路径，可能表现为详情页收藏成功后立即闪退。

新增修复：

- 新增 `shouldAutoCloseFavoritePanel()`，复用 `normalizeBoolSetting()`，并按默认设置保持 fallback 为 false。
- 三处收藏成功后的自动关闭判断统一通过 helper；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退为不自动关闭。

新增/扩展测试：

- `test/comic_page_favorite_status_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的自动关闭收藏面板开关归一化。

追加验证：

- `flutter test --no-pub test\comic_page_favorite_status_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `checkUpdateOnStart` 仍在启动后 update check 路径直接作为 bool 使用，但触发在延后后台任务中，需下一轮确认默认值和测试落点后再修。
- 字符串比较类设置继续保留观察；坏类型不会直接 `if (dynamic)` 崩溃。

## 2026-06-05 第八十二轮全项目审查

本轮继续不限于未提交 diff 审查 bootstrap PhaseB 启动路径中的可同步数值 settings。
确认的高置信风险在缓存大小设置恢复。

风险：

- `BootstrapController._runPhaseB()` 之前直接调用 `CacheManager().setLimitSize(appdata.settings['cacheSize'])`。
- `cacheSize` 可能来自同步数据、旧版本数据或手工编辑；如果值漂移为字符串、列表、null 或非正数，PhaseB 设置缓存上限时可能触发运行时类型错误或设置出无效缓存上限。
- 触发点在启动 PhaseB，可能表现为应用启动/久置恢复后初始化链异常，后续首页和网络缓存任务无法稳定进入 ready。

新增修复：

- 新增 `normalizeCacheSizeMb()`，复用 `normalizeNumSetting()`，并按默认设置保持 fallback 为 2048 MB。
- PhaseB 设置 CacheManager 上限前先归一化；合法 int 行为不变，数字字符串兼容，坏结构和非正数回退到默认 2048 MB。

新增/扩展测试：

- `test/bootstrap_hooks_test.dart` 覆盖 int、数字字符串、小数、坏字符串、列表、null 和非正数的缓存大小归一化。

追加验证：

- `flutter test --no-pub test\bootstrap_hooks_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `checkUpdateOnStart` 仍是后台 update check 中的 direct dynamic bool；该路径外层已有 catch，风险更接近更新检查失败而非启动崩溃，本轮不改。
- 设置页里 `cacheSize` 文案和用户手动输入仍按原逻辑处理；本轮只修同步/旧数据进入 bootstrap 的稳定性边界。

## 2026-06-05 第八十三轮全项目审查

本轮继续不限于未提交 diff 审查 reader 初始化路径中的漫画/设备特定 settings。
确认的高置信风险在进入阅读器时系统状态栏和音量键翻页开关恢复。

风险：

- `_ReaderState.initState()` 之前直接对 `getReaderSetting(..., 'showSystemStatusBar')` 做 `!`，并直接把 `getReaderSetting(..., 'enableTurnPageByVolumeKey')` 放进 `if`。
- 这两个值可能来自全局设置、漫画特定设置、设备特定设置、同步数据或旧版本数据；如果值漂移为字符串、数字、列表等非 bool，进入阅读器初始化时会触发运行时类型错误。
- 触发点在 reader initState，可能表现为打开漫画、恢复后重新进阅读器或切换设备特定设置后立即闪退。

新增修复：

- 复用既有 `shouldShowReaderSystemStatusBar()` 归一化系统状态栏开关，默认仍为 false。
- 新增 `shouldEnableReaderVolumeKey()`，复用 `normalizeBoolSetting()`，并按默认设置保持 fallback 为 true。
- reader 初始化中的系统 UI 模式和音量键监听判断都改为通过 helper；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退到默认行为。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的音量键翻页开关归一化。
- 既有系统状态栏归一化测试继续覆盖同一 reader initState 使用的 helper。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `_shouldShowChapterCommentsAtEnd` 使用 `== true` 显式比较，坏类型不会直接崩溃，本轮不改。
- reader 中 `quickCollectImage`、`longPressZoomPosition` 等字符串比较坏类型不会直接 `if (dynamic)` 崩溃，本轮不改。

## 2026-06-05 第八十四轮全项目审查

本轮继续不限于未提交 diff 审查 reader 设置面板变更回调中的漫画/设备特定 settings。
确认的高置信风险在阅读器内修改系统状态栏和音量键翻页开关。

风险：

- `ReaderSettings.onChanged` 之前在 `enableTurnPageByVolumeKey` 分支里直接把 `getReaderSetting(...)` 放进 `if`。
- 同一回调在 `showSystemStatusBar` 分支里直接把 `getReaderSetting(...)` 参与 `isOpen || showStatusBar`。
- 这两个值可能来自漫画特定设置、设备特定设置、同步数据或旧版本数据；如果值漂移为字符串、数字、列表等非 bool，用户在阅读器设置面板保存/切换后会触发运行时类型错误。

新增修复：

- `enableTurnPageByVolumeKey` 设置变更回调复用 `shouldEnableReaderVolumeKey()`，默认仍为 true。
- `showSystemStatusBar` 设置变更回调复用 `shouldShowReaderSystemStatusBar()`，默认仍为 false。
- 合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退到默认行为。

新增/扩展测试：

- 复用 `test/reader_gesture_logic_test.dart` 中已有的系统状态栏和音量键翻页归一化矩阵，覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `checkUpdateOnStart` 仍是后台 update check 中的 direct dynamic bool；外层已有 catch，继续记录为低优先观察。
- reader 里字符串比较类设置坏类型不会直接 `if (dynamic)` 崩溃，本轮不改。

## 2026-06-05 第八十五轮全项目审查

本轮继续不限于未提交 diff 审查 reader 分页布局路径中的漫画/设备特定 settings。
确认的高置信风险在单页封面和每屏图片数设置恢复。

风险：

- `_ImagePerPageHandler.showSingleImageOnFirstPage()` 之前直接返回 `getReaderSetting(..., 'showSingleImageOnFirstPage')`。
- `_ImagePerPageHandler.imagesPerPage` 之前直接把 `getReaderSetting(..., 'readerScreenPicNumberForPortrait/Landscape') ?? 1` 作为 `int` 返回。
- 这些值可能来自全局设置、漫画特定设置、设备特定设置、同步数据或旧版本数据；如果值漂移为字符串、列表、null、0 或负数，阅读器 build、翻页、横竖屏重算和页数计算可能触发运行时类型错误或除零。

新增修复：

- 新增 `shouldShowSingleImageOnFirstPage()`，复用 `normalizeBoolSetting()`，默认仍为 false。
- 新增 `normalizeReaderImagesPerPage()`，复用 `normalizeNumSetting()`，并把结果限制在 1-5。
- reader 分页布局统一在读取设置后归一化；合法 int/bool 行为不变，数字字符串兼容，坏结构和非法数值回退到稳定默认。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 覆盖单页封面开关的 bool、字符串布尔、数字布尔、坏字符串、列表和 null。
- 同文件覆盖每屏图片数的 int、数字字符串、0、负数、过大值、坏字符串、列表和 null。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `readerMode` 和 `quickCollectImage` 等字符串/枚举类设置坏类型当前多数会落到 fallback 或比较失败，不作为本轮 P1 修复。
- `autoPageTurningInterval` 仍需单独确认触发路径和默认边界；本轮不扩大到自动翻页。

## 2026-06-05 第八十六轮全项目审查

本轮继续不限于未提交 diff 审查 reader 模式枚举入口。
确认的高置信风险在阅读器初始化和阅读器设置面板切换模式时的 `ReaderMode.fromKey`。

风险：

- `_ReaderState.initState()` 和 `ReaderSettings.onChanged` 都直接把 `getReaderSetting(..., 'readerMode')` 传给 `ReaderMode.fromKey(String key)`。
- `readerMode` 可能来自全局设置、漫画特定设置、设备特定设置、同步数据或旧版本数据；如果值漂移为数字、列表、null 等非 String，进入阅读器或切换阅读模式时会触发运行时类型错误。
- 触发点在 reader 初始化和设置变更热路径，可能表现为打开阅读器或在阅读器设置中修改模式后立即闪退。

新增修复：

- 将 `ReaderMode.fromKey` 入参从 `String` 收紧为可接收 `Object?` 的防御入口。
- 非字符串或未知字符串统一回退到既有默认 `galleryLeftToRight`；合法 key 行为不变。
- 该修复同时覆盖 reader 初始化和 reader 设置面板切换模式两条调用路径。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 覆盖合法模式、未知字符串、数字、列表和 null 的 reader mode 归一化。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `autoPageTurningInterval` 仍需单独处理数值边界，尤其是 0/负数进入 `Timer.periodic` 的路径。
- `quickCollectImage` 等字符串比较类设置坏类型仍不会直接 `if (dynamic)` 崩溃，本轮不改。

## 2026-06-05 第八十七轮全项目审查

本轮继续不限于未提交 diff 审查 reader 自动翻页操作路径中的数值 settings。
确认的高置信风险在自动翻页间隔恢复。

风险：

- `_ReaderLocation.autoPageTurning()` 之前直接把 `getReaderSetting(..., 'autoPageTurningInterval')` 赋给 `int interval`。
- `autoPageTurningInterval` 可能来自全局设置、漫画特定设置、设备特定设置、同步数据或旧版本数据；如果值漂移为字符串、列表、null、0 或负数，用户点击自动翻页时会触发运行时类型错误或让 `Timer.periodic` 拿到非法间隔。
- 触发点在阅读器底部工具栏的自动翻页按钮，是明确用户操作路径。

新增修复：

- 新增 `normalizeAutoPageTurningIntervalSeconds()`，复用 `normalizeNumSetting()`。
- 合法数值和数字字符串保持/兼容，0/负数夹到 1 秒，过大值按设置页 UI 上限夹到 20 秒，坏结构和 null 回退默认 5 秒。
- `autoPageTurning()` 创建 `Timer.periodic` 前统一归一化间隔。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 覆盖 int、数字字符串、0、负数、过大值、坏字符串、列表和 null 的自动翻页间隔归一化。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `checkUpdateOnStart` 仍是后台 update check 中的 direct dynamic bool；外层已有 catch，继续保持低优先观察。
- reader 字符串比较类设置坏类型不会直接 `if (dynamic)` 崩溃，本轮不改。

## 2026-06-05 第八十八轮全项目审查

本轮继续不限于未提交 diff 审查 reader 翻页热路径中的 bool settings。
确认的高置信风险在页面动画开关恢复。

风险：

- `_ReaderLocation.enablePageAnimation()` 之前声明返回 `bool`，但直接返回 `getReaderSetting(..., 'enablePageAnimation')`。
- `enablePageAnimation` 可能来自全局设置、漫画特定设置、设备特定设置、同步数据或旧版本数据；如果值漂移为字符串、数字、列表等非 bool，用户翻页、键盘连按翻页或自动翻页触发 `toPage()` 时会触发运行时类型错误。
- 触发点在 reader 翻页热路径，表现可能是阅读器内第一次翻页、连续翻页或恢复后翻页闪退。

新增修复：

- 新增 `shouldEnableReaderPageAnimation()`，复用 `normalizeBoolSetting()`，并按默认设置保持 fallback 为 true。
- `enablePageAnimation()` 读取设置后统一归一化；合法 bool 行为不变，字符串/数字布尔兼容，坏结构回退为启用页面动画。

新增/扩展测试：

- `test/reader_gesture_logic_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的页面动画开关归一化。

追加验证：

- `flutter test --no-pub test\reader_gesture_logic_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `checkUpdateOnStart` 仍是后台 update check 中的 direct dynamic bool；外层已有 catch，继续保持低优先观察。
- reader 字符串比较类设置坏类型不会直接 `if (dynamic)` 崩溃，本轮不改。

## 2026-06-05 第八十九轮全项目审查

本轮继续不限于未提交 diff 审查启动/后台更新路径中的动态 settings。
确认的高置信风险在启动后的自动更新检查开关恢复。

风险：

- `_checkAppUpdates()` 之前直接把 `appdata.settings['checkUpdateOnStart']` 放进 `if` 条件。
- `checkUpdateOnStart` 可能来自本地旧配置、导入数据或同步数据；如果值漂移为字符串、数字、列表或 null，启动后的更新检查路径会触发运行时类型错误。
- 外层已有 catch 能避免整条启动任务崩溃，但仍会产生启动阶段异常日志并跳过预期的更新检查路径；在久置恢复/启动后台任务治理中属于可低风险收紧的稳定性点。

新增修复：

- 新增 `shouldCheckUpdateOnStart()`，复用 `normalizeBoolSetting()`，默认仍保持 false。
- `_checkAppUpdates()` 读取该设置后统一归一化；合法 bool 行为不变，字符串/数字布尔兼容，坏结构和 null 回退为不检查。

新增/扩展测试：

- `test/bootstrap_hooks_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的启动更新检查开关归一化。

追加验证：

- `flutter test --no-pub test\bootstrap_hooks_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `lib/components/comic.dart` 的 PageStorage 恢复 casts 已由 `normalizeComicListStorageState()` 保证结构，暂不作为 P1。
- `lib/pages/explore_page.dart` 的 multipart PageStorage 恢复 casts 已由 `normalizeMultiPartExploreState()` 保证结构；`_loadingInFlight` 恢复语义需要 UI 场景复核，本轮不扩大。
- `lib/network/images.dart` 的图片 loading config casts 已有 `normalizeThumbnailLoadingConfig()` / `normalizeComicImageLoadingConfig()` 覆盖，继续保持观察。

## 2026-06-05 第九十轮全项目审查

本轮继续不限于未提交 diff 审查收藏操作路径中的动态 settings。
确认的高置信风险在批量加入收藏弹窗初始化。

风险：

- `addFavorite()` 之前直接把 `appdata.settings['quickFavorite']` 赋给 `String? selectedFolder`。
- `quickFavorite` 可能来自设置页、旧配置、导入数据或同步数据；如果值漂移为数字、列表等非 String，打开“加入收藏”弹窗时会触发运行时类型错误。
- 触发点是首页/列表/搜索结果等批量加入收藏操作的用户可达路径，属于可局部修复的 P1 稳定性问题。

新增修复：

- 新增 `normalizeQuickFavoriteFolder()`，只接受非空 String，其他结构统一回退为 null。
- `addFavorite()` 初始化选中文件夹前先归一化；合法字符串行为不变，坏结构只表现为未预选快速收藏文件夹。

新增/扩展测试：

- `test/network_favorites_page_test.dart` 覆盖字符串、空字符串、数字、列表和 null 的快速收藏文件夹归一化。

追加验证：

- `flutter test --no-pub test\network_favorites_page_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `lib/utils/data_sync.dart` 中的 `.cast<String>()` 当前有 `isUsableRemoteDataFileName` / `normalizeWebDavConfig` 前置过滤保护，暂不作为 P1。
- 字符串比较类设置如 `newFavoriteAddTo`、`moveFavoriteAfterRead`、`quickCollectImage` 坏类型通常会落入默认分支或比较失败，不会直接 `if (dynamic)` 崩溃，本轮继续观察。
- `SelectSetting` 的未知 key 显示 fallback 还可做 UX 收紧，但缺少崩溃证据，本轮不扩大。

## 2026-06-05 第九十一轮全项目审查

本轮继续不限于未提交 diff 审查启动首页和生命周期恢复鉴权路径中的动态 settings。
确认的高置信风险在 `authorizationRequired` 类型漂移。

风险：

- `didChangeAppLifecycleState()` 之前直接读取 `appdata.settings['authorizationRequired']` 并参与 `!authorizationRequired` 判断。
- `build()` 中首页选择也直接把 `appdata.settings['authorizationRequired']` 放进三元表达式。
- `authorizationRequired` 可能来自设置页、旧配置、导入数据或同步数据；如果值漂移为字符串、数字、列表或 null，启动首页构建或移动端久置恢复鉴权路径会触发运行时类型错误。
- 该路径正好覆盖本轮重点的 Android 启动/久置恢复稳定性。

新增修复：

- 新增 `shouldRequireAuthorization()`，复用 `normalizeBoolSetting()`，默认仍保持 false。
- 生命周期恢复和首页选择两个读取点统一先归一化；合法 bool 行为不变，字符串/数字布尔兼容，坏结构和 null 回退为无需鉴权。

新增/扩展测试：

- `test/app_lifecycle_stability_test.dart` 覆盖 bool、字符串布尔、数字布尔、坏字符串、列表和 null 的鉴权开关归一化。

追加验证：

- `flutter test --no-pub test\app_lifecycle_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `comicDisplayMode` / `comicListDisplayMode` 等显示模式坏类型当前多通过 switch/default 或后续分支兜底，缺少崩溃证据，本轮不扩大。
- `language`、`theme_mode`、`color` 等字符串设置已有 switch fallback 或 locale helper，继续保持观察。
- `searchSources`、`webdav`、`dnsOverrides` 已有初始化/normalizer 防护，暂不作为 P1。

## 2026-06-05 第九十二轮全项目审查

本轮继续不限于未提交 diff 审查首页/列表漫画卡片构建热路径中的动态 settings。
确认的高置信风险在漫画卡片收藏/历史状态徽标开关。

风险：

- `ComicTile.build()` 之前直接把 `appdata.settings['showFavoriteStatusOnTile']` 和 `appdata.settings['showHistoryStatusOnTile']` 放进三元条件。
- 这两个值可能来自设置页、旧配置、导入数据或同步数据；如果漂移为字符串、数字、列表或 null，打开首页、搜索结果、收藏导入结果等漫画列表页面时会触发运行时类型错误。
- 触发点在列表 item build 热路径，属于“打开页面即崩”的 P1 稳定性问题。

新增修复：

- 新增 `shouldShowFavoriteStatusOnTile()` 和 `shouldShowHistoryStatusOnTile()`，复用 `normalizeBoolSetting()`，默认保持 false。
- `ComicTile.build()` 查询收藏/历史前先归一化设置；合法 bool 行为不变，字符串/数字布尔兼容，坏结构和 null 回退为不显示额外状态徽标。

新增/扩展测试：

- `test/comic_list_state_test.dart` 覆盖两个开关的 bool、字符串布尔、数字布尔、坏字符串、列表和 null。

追加验证：

- `flutter test --no-pub test\comic_list_state_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `comicDisplayMode` 坏类型当前只会落入 brief mode，不会直接崩溃，本轮不扩大。
- `comicListDisplayMode` 坏类型当前只会落入 continuous mode，不会直接崩溃，本轮不扩大。
- `SelectSetting` 对未知 key 显示 `None`，属于 UX/配置修复候选，不作为本轮 P1。

## 2026-06-05 第九十三轮全项目审查

本轮继续不限于未提交 diff 审查设置页强类型 UI 入参。
确认的高置信风险在阅读器设置的自定义图片处理脚本编辑页。

风险：

- `_CustomImageProcessing.initState()` 之前直接把 `appdata.settings['customImageProcessing']` 赋给 `String current`。
- `CodeEditor.initialValue` 也直接读取同一个动态设置值。
- `customImageProcessing` 可能来自旧配置、导入数据或同步数据；如果值漂移为数字、列表或 null，打开“自定义图片处理”设置页时会触发运行时类型错误。
- 触发点是设置页打开路径，属于可局部修复的 P1 稳定性问题。

新增修复：

- 新增 `normalizeCustomImageProcessingScript()`，只接受 String，其他结构回退到 `defaultCustomImageProcessing`。
- `_CustomImageProcessing` 初始化和 `CodeEditor.initialValue` 统一使用归一化后的 `current`；合法字符串和空字符串行为不变。

新增/扩展测试：

- `test/settings_components_test.dart` 覆盖合法脚本、空字符串、数字、列表和 null 的脚本文本归一化。

追加验证：

- `flutter test --no-pub test\settings_components_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `authorizationRequired` 设置页回调在 `_SwitchSetting` 保存 bool 后才执行；复核后坏值直接进入 `if (current)` 的证据不足，本轮不作为 P1。
- `SelectSetting` 对未知 key 显示 `None` 仍偏 UX/配置一致性问题，本轮继续观察。
- `comicSourceListUrl?.toString()` 和 `autoAddLanguageFilter ?? 'none'` 对坏类型没有直接强类型崩溃证据，本轮不扩大。

## 2026-06-05 第九十四轮全项目审查

本轮继续不限于未提交 diff 审查外部漫画源数据进入详情页强类型 API 的路径。
确认的高置信风险在漫画详情信息区的时间字段格式化。

风险：

- `ComicPage` 信息区之前的局部 `formatTime()` 对包含 `T` 或 `Z` 的时间字符串直接调用 `DateTime.parse()`。
- `uploadTime` / `updateTime` 来自漫画源 JS 返回数据；如果源返回形似 ISO 但实际非法的字符串，例如 `badTtime`，打开详情页信息区会触发 `FormatException`。
- 触发点在详情页构建路径，属于外部数据导致的 P1 稳定性问题。

新增修复：

- 抽出 `formatComicDetailTime()`，保留原有秒/毫秒时间戳和合法 ISO 时间格式化行为。
- 对包含 `T` / `Z` 但无法解析的字符串改用 `DateTime.tryParse()` 后原样返回，避免详情页构建崩溃。

新增/扩展测试：

- `test/comic_page_favorite_status_test.dart` 覆盖毫秒时间戳、秒时间戳、合法 ISO、非法 ISO 样式字符串和普通字符串。

追加验证：

- `flutter test --no-pub test\comic_page_favorite_status_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `int.parse(next!)` 位于网络收藏导入分页路径，`next` 当前主要由本地分页计算和源返回 cursor 决定；需进一步确认源 cursor 语义，暂不作为本轮 P1。
- `comicSourceListUrl` 使用 `toString()` 后传入网络请求，坏类型会形成无效 URL 但不一定是打开即崩；继续观察。
- `autoAddLanguageFilter` 坏类型当前只会进入字符串比较分支失败，不作为本轮 P1。

## 2026-06-05 第九十五轮全项目审查

本轮继续不限于未提交 diff 审查网络收藏导入路径中外部漫画源数据进入强类型分页 API 的稳定性。
确认的高置信风险在收藏源 `loadComics` 返回的 `Res.subData` 和导入分页页码解析。

风险：

- `Res.subData` 是 `dynamic`，收藏源 `loadComics` 的 `maxPage` 直接来自 JS 漫画源返回值。
- 旧代码在旧到新排序导入时把 `res?.subData ?? 1` 直接赋给 `int maxPage`，源返回 `"10"`、`10.0`、坏字符串或列表时可能触发运行时类型错误。
- 同一路径用 `int.parse(next!)` 解析当前页，并用 `res.subData == page` 判断最后一页；字符串页数会导致最后一页判断失效，坏页码会直接抛 `FormatException`。
- 触发点在“网络收藏转本地收藏/更新本地收藏”流程，属于外部源数据可触发的 P1 稳定性问题。

新增修复：

- 新增 `normalizeFavoriteImportPage()`，把源返回的 int、num、数字字符串归一化为正整数，坏值回退到有效 fallback。
- 新增 `isFavoriteImportLastPage()`，统一用归一化后的页码判断最后一页，避免 `"3"` 和 `3` 比较失败。
- `importNetworkFolder()` 中旧到新排序的 `maxPage`、当前页解析和最后一页判断统一走归一化 helper；合法 int 行为保持不变。

新增/扩展测试：

- `test/network_favorites_page_test.dart` 覆盖收藏导入页码的 int、double、数字字符串、坏字符串、非正数、坏 fallback 和列表输入。
- 同文件覆盖最后一页判断对 int、double、数字字符串和坏值的行为。

追加验证：

- `flutter test --no-pub test\network_favorites_page_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `loadNext` 分支的 `next` 本来是字符串 cursor，源可以返回任意 cursor；强行数字化会破坏兼容，本轮不改。
- 其他 `Res.subData` 用于分类、搜索、评论、缩略图分页的路径仍需按页面语义分别审查，不能把收藏导入的页码规则直接外推。
- `comicSourceListUrl` 与 `autoAddLanguageFilter` 仍未形成打开即崩证据，本轮继续记录为后续低优先级配置韧性候选。

## 2026-06-05 第九十六轮全项目审查

本轮继续不限于未提交 diff 审查久置恢复和漫画源网络请求路径中的持久化账号数据。
确认的高置信风险在自动重登和漫画源页面“重新登录”按钮。

风险：

- `ComicSource.reLogin()` 之前只判断 `data["account"] != null`，随后直接把持久化/同步数据强转为 `List` 并访问 `accountData[0]`、`accountData[1]`。
- 多个漫画源请求在返回 `Login expired` 后会调用 `source.reLogin()`；如果账号数据被同步、旧版本、cookie 登录标记或损坏文件污染为短列表、非列表或非字符串元素，网络请求路径可能触发 `RangeError` / `TypeError`。
- 漫画源页面“Re-login”按钮也只判断 `source.data["account"] is List`，点击后直接索引 `[0]` / `[1]`；坏数据会导致用户操作即崩。
- 触发点覆盖恢复后网络刷新、详情/评论等请求重试和用户前台操作，属于可局部修复的 P1 稳定性问题。

新增修复：

- 新增 `normalizeStoredAccountCredentials()`，只接受至少两个字符串元素的账号列表，并返回 `(username, password)`；短列表、非列表、非字符串元素统一视为无可用凭据。
- `ComicSource.reLogin()` 通过 `storedAccountCredentials` 和 `account?.login` 做 guard，坏账号数据直接返回 false，交给既有 `Login expired` 流程处理。
- 漫画源页面“Re-login”按钮只在存在 List 数据且账号源提供用户名密码 `login` 函数时显示；点击时再次使用 `storedAccountCredentials`，坏数据展示 “No data” 而不是崩溃。
- 不改变 cookie/webview 登录标记的 `isLogged` 语义，避免破坏非用户名密码登录源。

新增/扩展测试：

- `test/comic_source_models_test.dart` 覆盖合法账号列表、带额外字段列表、null、字符串标记、短列表、非字符串元素和 Map 输入。

追加验证：

- `flutter test --no-pub test\comic_source_models_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `category.parts[].categories[0]` 对空分类列表会导致源解析失败，但外层源加载有捕获，影响更像单个漫画源不可用；本轮记录为后续源兼容性候选，不作为 P1 闪退修复。
- 动态分类 loader 返回坏结构会在分类页读取时抛错，可能需要按分类页渲染路径单独设计容错，不在本轮扩大。
- 搜索建议里的 `split(" ").last` 和 `substring` 已有长度 guard，未形成高置信崩溃证据。

## 2026-06-05 第九十七轮全项目审查

本轮继续不限于未提交 diff 审查列表卡片渲染热路径中外部漫画源数据进入字符串索引的稳定性。
确认的高置信风险在漫画卡片 badge / language 显示。

风险：

- `Comic.language` 来自漫画源 JS 返回数据，`Comic.fromJson()` 会把空字符串保留为 `String?`，不会归一化成 null。
- `ComicTile` brief mode 中 `badge ?? comic.language` 会传入 `_ComicInfo`，旧代码只判断 `badge != null` 就访问 `badge![0]` 和 `badge!.substring(1)`。
- 当漫画源返回 `language: ""`、空白字符串，或列表页 `badgeBuilder` 返回空串时，首页、搜索结果、详情推荐、收藏/历史等漫画列表构建会触发 `RangeError`。
- 触发点在列表 item build 热路径，属于外部数据导致的 P1 稳定性问题。

新增修复：

- 新增 `formatComicTileBadge()`，把 null、空串和纯空白串统一视为无 badge。
- `_ComicInfo.build()` 使用归一化后的 `badgeText` 控制渲染；合法非空 badge 仍保持首字母大写、剩余小写的原行为。

新增/扩展测试：

- `test/comic_list_state_test.dart` 覆盖 null、空串、空白串、单字符 badge、普通语言码和带空格字符串。

追加验证：

- `flutter test --no-pub test\comic_list_state_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- WebDAV 配置 `[0]/[1]/[2]` 已由 `normalizeWebDavConfig()` 保证空配置或完整三字符串，本轮复核后不作为 P1。
- `category.parts[].categories[0]` 仍是单个漫画源解析失败候选，但外层源加载有捕获，未按闪退修复扩大。
- `badgeBuilder` 的业务语义仍需按各页面来源继续审查；本轮只收敛空 badge 的渲染崩溃。

## 2026-06-05 第九十八轮全项目审查

本轮继续不限于未提交 diff 审查 reader / 详情页 grouped chapters 的强索引路径。
确认的高置信风险在 grouped chapters 空分组、空 grouped map 和详情页 tab 计数。

风险：

- `ComicChapters.grouped({})` 或包含空分组的 grouped chapters 可由测试、本地导入/迁移或异常源数据进入内部模型；旧 `length` 使用 `reduce`，空 grouped map 会直接抛异常。
- reader 章节抽屉、历史写入、首/尾分组判断都用 `getGroupByIndex()` 配合 `while` 强索引；遇到空分组会跳不过去或越界，可能在打开章节抽屉、滚动跨章、更新历史时崩溃。
- 详情页 grouped chapters 的 `TabController.length` 旧代码使用 `chapters.ids.length`，也就是总章节数；当分组数少于章节数时，tab index 可能超过真实 `chapters.groups`，导致详情页章节区构建越界。
- 章节抽屉的 `TabController` / `ScrollController` 旧代码缺少 dispose，反复打开章节抽屉会增加资源积累风险。

新增修复：

- `ComicChapters.getGroupByIndex()` 对空 grouped map、负数和越界 index 返回空 map；`length` 改用 `fold`，空 grouped map 返回 0。
- 新增 `resolveGroupedReaderChapterPosition()`，统一把全局章节号定位到非空分组内的 `(groupIndex, chapterInGroup)`，跳过空分组并对越界返回 null。
- reader 历史写入、分组首尾判断和 grouped chapter drawer 初始化统一走安全定位 helper；空 grouped map 时章节抽屉只显示标题和空内容，不再构建无效 tabs。
- grouped chapter drawer 补充 `TabController` / `ScrollController` dispose。
- 详情页新增 `comicDetailGroupedChapterTabCount()`，`TabController.length` 改为真实 `groupCount`；groupCount 变 0 时释放旧 controller。

新增/扩展测试：

- `test/comic_source_models_test.dart` 覆盖 grouped chapters 空 map、空分组、负数/越界 `getGroupByIndex()` 和 `length`。
- `test/reader_loading_test.dart` 覆盖 `resolveGroupedReaderChapterPosition()` 跳过空分组、越界章节和空 grouped map。
- `test/comic_page_favorite_status_test.dart` 覆盖详情页 grouped chapter tab count 使用分组数而不是章节数。

追加验证：

- `flutter test --no-pub test\comic_source_models_test.dart test\reader_loading_test.dart test\comic_page_favorite_status_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `components/menu.dart` 的 `_MenuRoute.buildPage()` 对空 entries 使用 `entries.first`，但当前主要调用点都有固定 entries 或默认项；尚未找到可触发空菜单的真实调用链。
- `category.parts[].categories[0]` 仍是源解析兼容性候选，但外层源加载会捕获，影响更接近单个源不可用而非全局闪退。
- `loadNext` 分页 cursor 仍不能强行数字化，否则可能破坏源自定义 cursor 语义；继续按具体页面语义逐项审查。

## 2026-06-05 第九十九轮全项目审查

本轮继续不限于未提交 diff 审查漫画源分类解析路径中的外部数据强索引。
确认的高置信风险在 `category.parts[].categories` 为空数组时的格式判定。

风险：

- 漫画源 JS 的 `category.parts[].categories` 来自外部源定义，旧 parser 只判断 `categories is List`，随后直接访问 `categories[0]` 判断新/旧格式。
- 当源定义返回 `categories: []` 时，解析阶段会触发 `RangeError`，导致该漫画源加载失败；用户刷新源、启动加载源或导入源时都可能被异常源数据击中。
- 空 fixed/random 分类本来在后续逻辑中会被跳过，不需要视为致命错误；当前崩溃只是格式判定过早索引造成。

新增修复：

- 新增 `isNewCategoryFormatList()`，把 null、空列表和首项为 Map 的列表归为新格式路径，避免空数组访问 `[0]`。
- `_loadCategoryData()` 使用该 helper 判定格式；空 fixed/random 分类继续被跳过，dynamic 分类仍保持 `categories == null` 才使用 loader 的既有语义。

新增/扩展测试：

- `test/comic_source_semver_test.dart` 覆盖 null、空列表、新格式 Map 列表和旧格式字符串列表的分类格式判定。

追加验证：

- `flutter test --no-pub test\comic_source_semver_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `showMenuX()` 的 `_MenuRoute.buildPage()` 仍对空 entries 使用 `entries.first`，但当前已审调用点要么固定传入菜单项，要么由业务条件保证至少一项；尚未找到真实空菜单触发链。
- 动态分类 loader 返回坏结构仍会在 getter 中抛错；这可能需要页面级错误隔离，不在本轮扩大到行为变化。
- 旧格式分类的 `c["name"]`、`c["type"]`、`c["itemType"]` 强类型读取仍是源兼容性候选，但需要逐项确认是否应跳过坏 part 还是让源加载失败。

## 2026-06-05 第一百轮全项目审查

本轮继续不限于未提交 diff 审查分类页动态分类 loader 的外部 JS 数据进入 UI build 路径。
确认的高置信风险在 `DynamicCategoryPart.categories` 直接抛错。

风险：

- 动态分类 loader 由漫画源 JS 实现，返回值在分类页 build 时通过 `part.categories` 读取。
- 旧代码要求 loader 必须返回 `List<Map>` 且每个 `label` 都必须是 `String`；非列表、混入坏 row 或 label 缺失时会直接 throw。
- 触发点在分类页 build 路径，不只是源解析阶段；异常源或源运行时临时返回坏数据会导致用户打开分类页即崩。

新增修复：

- 新增 `normalizeDynamicCategoryItems()`，把非列表返回归一为空列表，跳过非 Map row 和缺失 label 的 row。
- `DynamicCategoryPart.categories` 改为调用该 helper；合法项仍通过 `PageJumpTarget.parse()` 保留原跳转语义，非字符串 label 归一为字符串，和本轮已有源数据归一化策略保持一致。

新增/扩展测试：

- `test/category_random_test.dart` 覆盖动态分类 loader 非列表返回、混合坏 row、缺失 label、数字 label 和合法 search/category target。

追加验证：

- `flutter test --no-pub test\category_random_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- 旧格式分类的 `c["name"]`、`c["type"]`、`c["itemType"]` 强类型读取仍可能让坏源 part 影响源加载；需要下一轮按 parse 阶段语义确认是跳过坏 part 还是保留失败。
- `showMenuX()` 空 entries 仍未找到真实触发链，本轮继续不作为高置信 P1。
- 分类页本身目前没有对单个 part build 失败做 UI 级隔离；动态 loader 已先从数据入口降风险，页面级隔离留作后续候选。

## 2026-06-05 第一百零一轮全项目审查

本轮继续不限于未提交 diff 审查分类源解析阶段的外部数据强类型读取。
确认的高置信风险在 `category.parts` 和旧格式分类 part 的坏结构。

风险：

- 漫画源 JS 的 `category.parts` 由外部源定义，旧 parser 直接 `for (var c in doc["parts"])` 并假设每个 part 都是 Map。
- 新格式分类旧代码直接对每个 categories row 取 `e['label']` / `e['target']`；混入非 Map row 会在源解析阶段抛错。
- 旧格式分类旧代码直接 `List<String>.from(c["categories"])`，非字符串标签会抛 `TypeError`；`name`、`type`、`itemType`、`groupParam`、`randomNumber` 也依赖强类型。
- 触发点在源解析/启动加载/刷新源路径，异常源定义可导致单个源加载失败，属于外部数据可触发的 P1 稳定性问题。

新增修复：

- `category.parts` 非列表时按空 parts 处理；混入非 Map part 时跳过该 part。
- 新格式 fixed/random 分类复用 `normalizeDynamicCategoryItems()`，跳过坏 row，避免 `e['label']` 强索引。
- 新增 `normalizeLegacyCategoryTags()`，旧格式分类 tags 统一转字符串并跳过 null/空串；空 tags part 跳过。
- 新增 `normalizeCategoryRandomNumber()`，坏 `randomNumber` 回退到 1。
- `title`、`enableRankingPage`、`name`、`type`、`itemType`、`categoryParams`、`groupParam` 走既有源数据归一化 helper；合法源行为保持不变。

新增/扩展测试：

- `test/category_random_test.dart` 覆盖旧格式 tags 非列表、混合类型、null/空串，以及 randomNumber 的数字、数字字符串、坏值和 null。

追加验证：

- `flutter test --no-pub test\category_random_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `_loadCategoryData()` 的 dynamic part loader 不是函数时仍抛错；这是源声明错误，是否跳过需按源安装/调试语义单独确认。
- `showMenuX()` 空 entries 仍未找到真实触发链，本轮继续不作为高置信 P1。
- 分类页缺少对单个 part build 失败的 UI 级隔离；本轮已继续收紧数据入口，页面级隔离留给后续更明确场景。

## 2026-06-05 第一百零二轮全项目审查

本轮继续不限于未提交 diff 审查 `categoryComics` 选项配置的外部源数据解析。
确认的高置信风险在 `optionList`、动态 `optionLoader` 返回值和 ranking options 的强类型处理。

风险：

- `categoryComics.optionList` 与 `categoryComics.ranking.options` 来自漫画源 JS 定义，旧代码直接遍历并调用 `option.isEmpty`、`option.contains("-")`、`option.split("-")`。
- 当 option 项为数字、null、Map、无 `-` 字符或空 key 时，会在源解析/启动加载/刷新源时触发类型错误或产生无效 key。
- 动态 `optionLoader` 旧代码遇到单个非 Map row 会直接返回错误，且 `notShowWhen/showWhen` 用 `List.from` 保留坏类型，后续页面筛选可能继续踩类型问题。

新增修复：

- 新增 `parseCategoryOptionEntries()`，把 option 项统一转字符串，跳过 null、无分隔符、空 key 和坏项，保留带多个 `-` 的显示值。
- 新增 `normalizeCategoryComicsOptionsItem()`，跳过非 Map / 空 options 的 option item，并归一化 label、`notShowWhen`、`showWhen`。
- 静态 `categoryComics.optionList`、动态 `optionLoader` 和 `categoryComics.ranking.options` 统一使用上述 helper；合法源行为保持不变。

新增/扩展测试：

- `test/category_comics_page_test.dart` 覆盖 mixed option 项、空 key、无分隔符、数字/null 项，以及 option item 的 label、`notShowWhen`、`showWhen` 归一化。

追加验证：

- `flutter test --no-pub test\category_comics_page_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `categoryComics.optionLoader` 整体返回非 List 时仍返回 `Res.error`，这是可展示的加载错误，不按闪退修。
- ranking load/loadWithNext 的网络返回结构已由 `normalizeSourceComicListResult()` 保护，本轮不重复扩大。
- 分类页 UI 级单 part 隔离仍是后续候选，但本轮优先收紧启动解析和 option loader 数据入口。

## 2026-06-05 第一百零三轮全项目审查

本轮继续不限于未提交 diff 审查搜索页选项配置的外部源数据解析。
确认的高置信风险在 `search.optionList` 的强类型读取。

风险：

- `search.optionList` 来自漫画源 JS 定义，旧代码直接遍历 `element["options"]` 并调用 `option.isEmpty`、`option.contains("-")`、`option.split("-")`。
- 当 option 项为数字、null、Map、无 `-` 字符或空 key 时，会在源解析/启动加载/刷新源时触发类型错误或产生无效 key。
- 当 option element 本身不是 Map，或 `label/type/default` 类型异常时，旧代码可能把坏类型传入页面层，后续搜索选项渲染/默认值计算继续踩类型问题。

新增修复：

- 新增 `normalizeSearchOptionsItem()`，跳过非 Map / 空 options 的搜索 option item。
- 搜索 option 的 entries 复用 `parseCategoryOptionEntries()`，统一跳过 null、无分隔符、空 key 和坏项，保留带多个 `-` 的显示值。
- `label` 归一为字符串，`type` 限定为页面实际支持的 `select`、`multi-select`、`dropdown`，其它值回退为 `select`；`default` 保留原 `jsonEncode` 语义。
- `_loadSearchData()` 对 `search.optionList` 非列表按空列表处理；合法源行为保持不变。

新增/扩展测试：

- `test/search_options_test.dart` 覆盖非 Map option item、空 options、mixed option 项、空 key、无分隔符、数字/null 项、unsupported type 回退，以及 supported type 保留。

追加验证：

- `flutter test --no-pub test\search_options_test.dart --reporter=compact`
- `flutter test --no-pub test\category_comics_page_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- 搜索 loader 整体返回结构已经由 `normalizeSourceComicListResult()` 保护；本轮不扩大到搜索页面 UI 级错误隔离。
- `search.optionList` 的 unsupported type 当前回退到 `select`，避免页面无控件且默认值仍参与请求；若后续需要暴露源调试错误，应单独设计源诊断通道。

## 2026-06-05 第一百零四轮全项目审查

本轮继续不限于未提交 diff 审查详情页入口的外部源返回结构。
确认的高置信风险在 `comic.loadInfo` 返回值的强类型检查。

风险：

- `comic.loadInfo` 由漫画源 JS 实现，旧代码要求返回值运行时类型必须是 `Map<String, dynamic>`。
- JS/runtime 桥接或源实现返回普通 `Map`、非字符串 key Map、或其它坏结构时，打开详情页会直接走异常路径。
- 这是详情页核心入口，影响用户从搜索、分类、收藏、历史进入漫画详情，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `normalizeComicDetailsPayload()`，先用 `comicSourceMapOrNull()` 归一化外部源返回 Map，再补 `comicId/sourceKey`。
- `_parseLoadComicFunc()` 改为调用该 helper；非 Map 返回稳定 `Res.error("Invalid data")`，合法源行为保持不变。
- 保留 `ComicDetails.fromJson()` 既有字段归一化和可选字段容错策略。

新增/扩展测试：

- `test/comic_source_models_test.dart` 覆盖 `normalizeComicDetailsPayload()` 接受非字符串 key Map、补齐 `comicId/sourceKey`，以及非 Map 返回 `null`。

追加验证：

- `flutter test --no-pub test\comic_source_models_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `comic.loadInfo` 返回 Map 但字段语义缺失时仍由 `ComicDetails.fromJson()` 按空字符串/空列表策略兜底；是否把缺失 title/id 视为源错误需要单独产品语义判断。
- 详情页 UI 级错误隔离不在本轮扩展范围；本轮只修数据入口强类型崩溃。

## 2026-06-05 第一百零五轮全项目审查

本轮继续不限于未提交 diff 审查网络收藏文件夹入口的外部源返回结构。
确认的高置信风险在 `favorites.loadFolders` 返回值的强类型读取。

风险：

- `favorites.loadFolders` 由漫画源 JS 实现，旧代码直接读取 `res["favorited"]` 并 `List.from()`，再对 `res["folders"]` 做 `Map.from()`。
- 当源返回 root 非 Map、`folders` 非 Map、folder key/value 非字符串、`favorited` 混入数字/null/坏结构时，会在详情页收藏状态刷新或收藏弹层加载时抛异常。
- 这是详情页收藏状态和网络收藏操作的高频入口，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `normalizeFavoriteFoldersPayload()`，root 非 Map 返回 `null`，让调用侧稳定返回 `Res.error("Invalid data")`。
- `folders` 只保留非 null 值，并将 key/value 归一成字符串；`favorited` 复用 `comicSourceStringList()`，过滤 null 并保留源返回的字符串化 folder id。
- `_loadFavoriteData()` 的 `loadFolders` 改为调用该 helper；合法源行为保持不变。

新增/扩展测试：

- `test/comic_source_models_test.dart` 覆盖 mixed folders、mixed favorited、坏 folders/favorited 结构，以及 root 非 Map 返回 `null`。

追加验证：

- `flutter test --no-pub test\comic_source_models_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `favorited` 中空字符串目前会保留到下游，再由详情页 `normalizeFavoriteFolderIds()` 过滤；是否在 parser 层也过滤空 id 需要按源兼容性单独判断。
- `favorites.addFolder/deleteFolder/addOrDelFavorite` 的返回值目前只看是否抛异常；源若返回业务失败但不抛，需要单独定义协议语义后再处理。

## 2026-06-05 第一百零六轮全项目审查

本轮继续不限于未提交 diff 审查网络收藏配置字段的外部源解析。
确认的高置信风险在 `favorites.multiFolder`、`favorites.isOldToNewSort`、`favorites.singleFolderForSingleComic` 的强类型读取。

风险：

- 这些字段由漫画源 JS 定义，旧代码直接赋值给 `bool` / `bool?`。
- 当源使用 `"true"`、`1`、`"yes"` 等常见布尔表达，或返回坏值时，会在源解析阶段触发类型错误，导致整个源加载失败。
- `multiFolder` 还控制 `loadFolders/addFolder/deleteFolder` 是否挂载，解析失败会影响网络收藏页和详情收藏入口。

新增修复：

- 新增 `normalizeFavoriteDataFlags()`，复用 `comicSourceBool()` 解析 bool、数字和字符串。
- `multiFolder` 与 `singleFolderForSingleComic` 坏值回退为 `false`；`isOldToNewSort` 坏值保留为 `null`，沿用现有“null 当作从新到旧”的语义。
- `_loadFavoriteData()` 统一使用该 helper；合法源行为保持不变。

新增/扩展测试：

- `test/comic_source_models_test.dart` 覆盖字符串/数字布尔值、坏值回退和 null 语义。

追加验证：

- `flutter test --no-pub test\comic_source_models_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `favorites.addFolder/deleteFolder/addOrDelFavorite` 的返回值协议仍未收紧；需要先确认源 API 是否允许返回 false/错误对象。
- `favorites.multiFolder` 缺失时当前回退 false，符合本轮容错目标，但是否应对缺失字段发源诊断提示留给后续。

## 2026-06-05 第一百零七轮全项目审查

本轮继续不限于未提交 diff 审查评论模型的外部源时间字段。
确认的高置信风险在 `Comment.parseTime()` 对整数时间戳的越界处理。

风险：

- 评论数据由漫画源 JS 返回，`time` 字段可能是秒级/毫秒级整数，也可能是异常大的数值。
- 旧代码对整数时间戳直接调用 `DateTime.fromMillisecondsSinceEpoch()`，异常大整数会触发运行时异常。
- 该异常会击穿 `comic.loadComments` / `comic.loadChapterComments` 的评论列表构造，导致详情评论页或章节评论页加载失败，属于外部源可触发的 P1 稳定性问题。

新增修复：

- `Comment.parseTime()` 新增 `DateTime` 毫秒时间戳范围保护。
- 正常秒级/毫秒级时间戳继续格式化为 19 位时间字符串。
- 越界整数或不可构造的整数时间戳回退为原始字符串，避免单条坏评论时间击穿整页。

新增/扩展测试：

- `test/comic_source_models_test.dart` 覆盖 null、秒级/毫秒级时间戳一致性、越界大整数回退和普通字符串时间。

追加验证：

- `flutter test --no-pub test\comic_source_models_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- 负数时间戳当前仍按 `DateTime` 支持范围格式化；是否对负数直接展示原值属于展示语义，不作为本轮稳定性修复。
- 评论 loader root 非 Map 目前返回空评论列表而不是 `Res.error`；这是体验/诊断语义问题，本轮不改。

## 2026-06-05 第一百零八轮全项目审查

本轮继续不限于未提交 diff 审查漫画源可选正则配置。
确认的高置信风险在 `comic.idMatch` 的强正则构造。

风险：

- `comic.idMatch` 是漫画源 JS 的可选正则字符串配置，旧代码直接 `RegExp(_getValue("comic.idMatch"))`。
- 当源配置坏正则、空字符串或非字符串值时，会在源解析阶段抛异常，导致整个源加载失败。
- 该字段只是可选的 ID 匹配器，坏值禁用该匹配器比击穿源加载更符合稳定性优先策略，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `parseComicIdMatch()`，对 null、空字符串、坏正则返回 `null`。
- `_parseIdMatch()` 改为调用该 helper；合法正则行为保持不变。

新增/扩展测试：

- `test/comic_source_semver_test.dart` 覆盖 null、空字符串、坏正则和合法正则匹配行为。

追加验证：

- `flutter test --no-pub test\comic_source_semver_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- 坏 `comic.idMatch` 当前不会发源诊断提示；是否需要在源管理 UI 显示配置错误，留给后续诊断通道设计。
- `settings` 里的用户输入 validator 已在 UI 层 try/catch，本轮不重复扩大到设置页展示语义。

## 2026-06-05 第一百零九轮全项目审查

本轮继续不限于未提交 diff 审查图片加载配置回调的外部源返回值。
确认的高置信风险在 `comic.onImageLoad` / `comic.onThumbnailLoad` 返回非 Map 时的运行时类型崩溃。

风险：

- `comic.onImageLoad` 与 `comic.onThumbnailLoad` 由漫画源 JS 实现，旧 parser 对 `onImageLoad` 返回值原样交给 `Future<Map<String, dynamic>>`，对 `onThumbnailLoad` 非 Map 直接 throw。
- 当源临时返回字符串、数字、null 或混入非字符串 key 的 Map 时，reader 图片加载或缩略图刷新可能在热路径抛异常。
- 图片加载配置是可选增强项，坏配置回退空配置继续按原 URL 加载，比击穿阅读/缩略图加载路径更符合稳定性优先策略，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `normalizeImageLoadingConfigResult()`，只接受 Map，并只保留原始字符串 key；非 Map 返回空配置。
- `_parseImageLoadingConfigFunc()` 对同步/异步返回值都调用该 helper。
- `_parseThumbnailLoadingConfigFunc()` 非 Map 不再 throw，改为空配置回退；合法 Map 行为保持不变。

新增/扩展测试：

- `test/reader_image_cache_strategy_test.dart` 覆盖非 Map 返回、非字符串 key 过滤和合法字段保留。

追加验证：

- `flutter test --no-pub test\reader_image_cache_strategy_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `onResponse` / `onLoadFailed` 的业务返回语义仍由网络图片层处理；本轮只收紧 parser 回调返回结构。
- 坏图片配置目前不会发源诊断提示；是否需要源调试日志分级留给后续诊断通道设计。

## 2026-06-05 第一百一十轮全项目审查

本轮继续不限于未提交 diff 审查漫画源 `explore` 页面配置。
确认的高置信风险在 `explore[i].title/type` 解析阶段的强类型转换和未知 type 抛错。

风险：

- `explore` 页面定义由漫画源 JS 提供，旧代码把 `title` 和 `type` 强转为 `String`，并对未知 `type` 直接抛 `ComicSourceParseException`。
- 当源临时返回数字标题、空标题、null type 或未来/错误 type 时，会在源解析阶段中断整个源加载。
- 单个 `explore` 页只是源内的可选展示入口，坏配置跳过该页比击穿源加载更符合稳定性优先策略，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `normalizeExplorePageDefinition()`，将合法标题转为字符串，识别现有四种页面类型。
- `multiPartPage` 继续归一到 `singlePageWithMultiPart`，保持现有语义。
- 空标题、null type 或未知 type 返回 `null`，`_loadExploreData()` 跳过该条坏配置，不再抛异常。

新增/扩展测试：

- `test/comic_source_models_test.dart` 覆盖数字标题、`multiPartPage` 别名、`singlePageWithMultiPart`、`multiPageComicList`、`mixed`，以及空标题、null type、未知 type。

追加验证：

- `flutter test --no-pub test\comic_source_models_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- 坏 `explore` 配置目前静默跳过；是否需要在源调试 UI 暴露诊断信息，留给后续诊断通道设计。
- `explore.length` 若由源返回非数字，当前 JS 侧 for 循环不会进入或由 JS 运行时行为决定；尚未证明会造成 Dart 侧 P1 崩溃，本轮不改。

## 2026-06-05 第一百一十一轮全项目审查

本轮继续不限于未提交 diff 审查账号与 Cookie 登录相关的漫画源配置边界。
确认的高置信风险在 `account.loginWithCookies.fields` 的强 Iterable 转换。

风险：

- `account.loginWithCookies.fields` 由漫画源 JS 配置，旧代码通过 `ListOrNull.from(_getValue(...))` 直接要求返回值是 `Iterable`。
- 当源配置临时返回字符串、数字、对象或其他非 Iterable 值时，会在源解析阶段抛类型异常，导致整个源加载失败。
- Cookie 登录字段只是可选的账号输入提示，坏值回退为空比击穿源加载和鉴权恢复路径更符合稳定性优先策略，属于外部源可触发的 P1 稳定性问题。

新增修复：

- `_loadAccountConfig()` 改用 `comicSourceStringListOrNull()` 解析 `account.loginWithCookies.fields`。
- `null` 仍保持 `null`；合法列表继续按字符串列表传递；非 Iterable 坏值回退为空列表，不再抛异常。
- 不改变账号登录协议、Cookie 校验回调、用户可见设置或漫画源 JS API。

新增/扩展测试：

- `test/comic_source_models_test.dart` 覆盖 `comicSourceStringListOrNull()` 对 null、非 Iterable、混合列表的归一化行为。

追加验证：

- `flutter test --no-pub test\comic_source_models_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `account.loginWithCookies.validate` 若返回非 bool，目前 Dart 闭包的返回类型可能在运行时抛错，但语义上可能应允许源用 truthy/falsy 或错误对象；需要先确认源 API 约定，本轮不改。
- WebView 登录的 `checkStatus` 返回非 bool 也可能存在类似语义问题，暂未证明是 P1 崩溃高发点。

## 2026-06-05 第一百一十二轮全项目审查

本轮继续不限于未提交 diff 审查账号恢复与登录回调的 bool 返回边界。
确认的高置信风险在 `account.loginWithWebview.checkStatus` 和 `account.loginWithCookies.validate` 的动态返回值直接进入 Dart `bool` 返回位。

风险：

- `checkStatus` 与 `validate` 都由漫画源 JS 实现，旧代码直接返回 `JsEngine().runCode(...)` 的动态结果。
- 当源返回 `1/0`、`"true"/"false"`、`"yes"/"no"` 或异常对象时，Dart 闭包声明的 `bool` / `Future<bool>` 返回位可能触发运行时类型异常。
- 这两个回调位于 WebView 导航、Cookie 登录和久置后鉴权恢复路径；坏返回值不应导致页面回调崩溃或恢复后操作闪退，属于外部源可触发的 P1 稳定性问题。

新增修复：

- `account.loginWithWebview.checkStatus` 现在用 `comicSourceBool()` 归一化返回值，坏值回退 `false`，并捕获 JS 异常。
- `account.loginWithCookies.validate` 现在同样归一化 bool-like 返回值，坏值或异常回退 `false`。
- 不改变登录成功后的数据写入、Cookie 保存、WebView 导航或漫画源 JS API。

新增/扩展测试：

- `test/comic_source_models_test.dart` 覆盖 `comicSourceBool()` 对 bool、数字、字符串和坏值的归一化行为。

追加验证：

- `flutter test --no-pub test\comic_source_models_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `account.loginWithWebview.url` / `account.registerWebsite` 当前仍可能接收非字符串值；它们主要影响按钮显示和 `launchUrlString` 语义，暂未证明是 P1 崩溃高发点。
- `account.logout` 未捕获异常；若源 logout 抛错会影响用户手动退出流程，但是否应该吞掉错误涉及账号状态一致性，本轮不改。

## 2026-06-05 第一百一十三轮全项目审查

本轮继续不限于未提交 diff 审查 reader/thumbnail 图片加载回调的外部源返回值。
确认的高置信风险在 reader 图片 `onResponse` 对坏返回值直接抛错。

风险：

- `comic.onImageLoad` / `comic.onThumbnailLoad` 的配置 Map 已经过 parser 归一化，但 `onResponse` 仍由漫画源 JS 提供。
- 缩略图路径遇到坏 `onResponse` 返回值会记录 warning 并保留原始响应体；reader 路径旧逻辑则会直接抛 `Error: Invalid onResponse result.`。
- reader 图片加载是高频热路径，单个源回调临时返回字符串、空 Iterable 或混合列表时，不应击穿当前页图片加载；保留原始响应体比失败更符合稳定性优先策略，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `normalizeImageOnResponseBytes()`，统一接受 `Uint8List`、`List<int>` 和非空 `Iterable<int>`。
- 缩略图路径改用同一 helper，语义保持“坏值忽略并继续”。
- reader 路径遇到坏 `onResponse` 结果不再 throw，改为记录 warning 并保留原始响应体继续解码/缓存。

新增/扩展测试：

- `test/reader_image_cache_strategy_test.dart` 覆盖 `Uint8List`、`List<int>`、混合 Iterable、空坏 Iterable、字符串和 null 的归一化行为。

追加验证：

- `flutter test --no-pub test\reader_image_cache_strategy_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `onLoadFailed` 坏返回值当前会终止 retry 并回到原异常；是否要记录更细粒度源诊断，留给后续日志/诊断通道设计。
- `modifyImage` 脚本失败仍会导致 reader 图片失败；这是主动修改图片的源脚本语义，暂不按坏 `onResponse` 的降级策略处理。

## 2026-06-05 第一百一十四轮全项目审查

本轮继续不限于未提交 diff 审查图片 `onResponse` 回调异常与资源释放路径。
确认的高置信风险在 thumbnail `onResponse` 回调抛错时既击穿刷新，又可能跳过 `JSInvokable.free()`。

风险：

- thumbnail `onResponse` 与 reader `onResponse` 都由漫画源 JS 提供，可能同步抛错、异步抛错或返回坏数据。
- reader 路径上一轮已在 `finally` 中释放 JS 回调；thumbnail 路径旧代码直接调用后再 `free()`，一旦回调抛错会跳过释放，并导致缩略图刷新失败。
- 缩略图/封面加载是列表页高频路径，单个源回调异常不应导致刷新崩溃或资源泄漏；保留原始响应体继续更符合稳定性优先策略，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `runImageOnResponseCallback()`，统一执行同步/异步 `onResponse`，将结果交给 `normalizeImageOnResponseBytes()`，异常时返回 `null`。
- `release` 回调固定在 `finally` 执行，保证 `JSInvokable.free()` 不会因为源回调异常被跳过。
- thumbnail 和 reader `onResponse` 均改用该 helper；坏返回或回调异常时记录 warning 并保留原始响应体继续。

新增/扩展测试：

- `test/reader_image_cache_strategy_test.dart` 覆盖同步返回、异步返回、同步抛错仍释放资源并返回 `null`。

追加验证：

- `flutter test --no-pub test\reader_image_cache_strategy_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `onResponse` 抛错目前只记录 warning，不暴露到源调试 UI；是否需要源级错误面板留给诊断通道设计。
- `modifyImage` 仍按强语义处理，脚本失败会导致 reader 图片失败；暂不把主动图像修改错误降级为原图继续。

## 2026-06-05 第一百一十五轮全项目审查

本轮继续不限于未提交 diff 审查 JS 引擎消息桥接的外部源输入边界。
确认的高置信风险在 `load_data` / `save_data` / `delete_data` / `load_setting` 消息字段的强字符串赋值。

风险：

- JS 消息由漫画源代码触发，`key`、`data_key`、`setting_key` 旧代码直接赋给 Dart `String`。
- 当源传入 null、数字、列表或空字符串时，`_messageReceiver()` 会抛类型异常并 rethrow，击穿 JS bridge 调用链。
- 这些消息用于源数据读写、设置读取和恢复期状态判断；坏消息应被忽略而不是导致引擎回调崩溃，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `normalizeJsMessageString()`，只接受非空字符串。
- `load_data` / `save_data` / `delete_data` / `load_setting` 统一使用该 helper；字段坏值直接返回 `null`，不再抛类型异常。
- 保留 `save_data` 禁止写 `setting` 的现有安全语义；不改变合法 JS API 行为。

新增/扩展测试：

- `test/js_engine_stability_test.dart` 覆盖非空字符串、空字符串、null、数字和列表的归一化行为。

追加验证：

- `flutter test --no-pub test\js_engine_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `http` / `html` / `convert` / `cookie` 等消息仍通过 `Map.from(message)` 进入各自处理器；这些处理器已有局部容错，是否继续统一消息 schema 需要更大范围设计。
- `load_setting` 的设置项结构来自已归一化的 source settings，本轮不额外改 `configValue` 读取逻辑。

## 2026-06-05 第一百一十六轮全项目审查

本轮继续不限于未提交 diff 审查 JS 引擎 `log` 消息的外部源输入边界。
确认的高置信风险在 `log.level` 和 `log.title` 的强类型/隐式类型使用。

风险：

- `log` 消息由漫画源 JS 触发，旧代码把 `message["level"]` 直接赋给 Dart `String`，并把 `message["title"]` 原样传给 `Log.addLog(String title, ...)`。
- 当源传入 null、数字、列表或其他坏值时，`_messageReceiver()` 会抛类型异常并 rethrow，击穿 JS bridge 调用链。
- 日志消息是非关键副作用，坏日志字段不应导致源逻辑崩溃，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `normalizeJsLogLevel()`，合法 `error/info` 保持原语义，其余值回退 `warning`。
- `log.title` 改为 `message["title"]?.toString() ?? ""`，坏标题不再触发类型异常。
- 合法 `warning` 和未知级别仍按 warning 记录，不改变正常日志 API 行为。

新增/扩展测试：

- `test/js_engine_stability_test.dart` 覆盖 `error`、`warning`、`info`、null、数字和未知字符串的日志级别归一化。

追加验证：

- `flutter test --no-pub test\js_engine_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `log.content` 仍通过 `.toString()` 处理，null 会显示为 `"null"`；这是日志展示语义，不作为稳定性修复。
- 其他 JS bridge 消息入口仍需逐项审查，但不做一次性大规模 schema 重构。

## 2026-06-05 第一百一十七轮全项目审查

本轮继续不限于未提交 diff 审查 JS bridge 的非关键副作用消息。
确认的高置信风险在 `delay.time` 和 `setClipboard.text` 的动态字段直接传入 Flutter API。

风险：

- `delay` 与 `setClipboard` 消息由漫画源 JS 触发，旧代码把 `message["time"]` 直接传给 `Duration(milliseconds: ...)`，把 `message["text"]` 直接传给 `ClipboardData(text: ...)`。
- 当源传入 null、负数、字符串、对象或其他坏值时，可能触发运行时类型异常并 rethrow，击穿 JS bridge 调用链。
- 延迟和剪贴板写入属于非关键副作用，坏字段应被归一化而不是导致源逻辑崩溃，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `normalizeJsDelayMilliseconds()`，支持 int、num 和可解析字符串，负数/坏值回退 0。
- 新增 `normalizeJsClipboardText()`，坏值安全转为空字符串或 `toString()`。
- `delay` / `setClipboard` 分支改用上述 helper；合法行为保持不变。

新增/扩展测试：

- `test/js_engine_stability_test.dart` 覆盖数字、浮点、字符串、负数、坏值和 null 的 delay 归一化，以及剪贴板文本归一化。

追加验证：

- `flutter test --no-pub test\js_engine_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `random` 消息动态 `min/max/type` 边界已在第一百一十八轮修复。
- `compute` 消息坏参数仍主动抛错，属于 JS API 参数约束，暂不按非关键副作用降级。

## 2026-06-05 第一百一十八轮全项目审查

本轮继续不限于未提交 diff 审查 JS bridge 的随机数工具消息。
确认的高置信风险在 `random.min/max/type` 动态字段直接进入 `_random(num, num, String)`。

风险：

- `random` 消息由漫画源 JS 触发，旧代码把 `message["min"]`、`message["max"]` 和 `message["type"]` 直接传入强类型 `_random(num, num, String)`。
- 当源传入 null、字符串数字、坏字符串、对象、列表或 max 小于 min 时，可能触发运行时类型异常或生成异常区间，击穿 JS bridge 调用链。
- 随机数工具是非关键辅助 API，坏字段应归一化到安全默认值而不是导致源逻辑崩溃，属于外部源可触发的 P1 稳定性问题。

新增修复：

- 新增 `normalizeJsRandomRequest()`，支持数字和可解析字符串边界，坏值回退 `0/1`。
- 当 `max < min` 时自动交换边界，避免异常区间。
- `type` 只保留合法 `double`，其余回退 `int`；合法行为保持不变。

新增/扩展测试：

- `test/js_engine_stability_test.dart` 覆盖数字边界、字符串边界、坏值回退和上下界反转归一化。

追加验证：

- `flutter test --no-pub test\js_engine_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `compute` 消息坏参数仍主动抛错，属于 JS API 参数约束，暂不按非关键副作用降级。
- `convert` 消息包含加密/编码参数，错误输入应返回错误还是降级需要按 API 语义单独审查，不在本轮合并处理。

## 2026-06-05 第一百一十九轮全项目审查

本轮继续不限于未提交 diff 审查 JS bridge 的 `convert` 工具消息。
确认的高置信风险在 `convert.type` 与 `convert.isEncode` 的控制字段强类型读取发生在 `_convert()` 的内部 `try` 之前。

风险：

- `convert` 消息由漫画源 JS 触发，旧代码在进入编码/加密转换前直接执行 `String type = data["type"]` 与 `bool isEncode = data["isEncode"]`。
- 当源传入 null、数字、字符串布尔、列表或对象等坏控制字段时，类型异常会绕过 `_convert()` 现有失败兜底，继续被 `_messageReceiver()` rethrow，击穿 JS bridge 调用链。
- 具体编码/加密参数错误仍应由各转换分支按现有语义处理；但控制字段畸形属于外部源输入边界，应该稳定返回失败而不是崩溃。

新增修复：

- 新增 `normalizeJsConvertType()` 与 `normalizeJsConvertIsEncode()`，仅接受合法 `String` / `bool` 控制字段。
- `_convert()` 在控制字段畸形时记录 `Log.error` 并返回 null，使坏消息进入现有转换失败语义。
- 不改合法 `utf8/gbk/base64/hash/hmac/aes/rsa` 行为，也不放宽字符串布尔等非 API 输入。

新增/扩展测试：

- `test/js_engine_stability_test.dart` 覆盖合法与畸形的 `convert.type`、`convert.isEncode` 控制字段归一化。

追加验证：

- `flutter test --no-pub test\js_engine_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `convert` 的具体 `value/key/iv/blockSize/hash` 输入错误仍由转换分支内部 `try/catch` 处理；是否需要更细 schema 要结合漫画源 API 语义，不在本轮扩大。
- `compute` 坏参数仍主动抛错，维持为 JS API 参数约束。

## 2026-06-05 第一百二十轮全项目审查

本轮继续不限于未提交 diff 做全项目稳定性审查，但没有发现新的高置信、可小范围验证的 P0/P1 修复点，因此不做代码改动。

已审范围：

- `lib/network/images.dart` 图片加载配置归一化：确认 `normalizeThumbnailLoadingConfig()` / `normalizeComicImageLoadingConfig()` 已覆盖非 Map 配置、非字符串 `url/method` 和非字符串 header key；已有 `reader_image_cache_strategy_test.dart` 覆盖。
- `lib/network/app_dio.dart` prevent-parallel 请求 key：确认 URI 解析异常、坏百分号编码、query/header 归一化、非 GET 跳过、BaseOptions header 不污染等已有 helper 和 `network_init_guard_test.dart` 覆盖。
- `lib/network/cache.dart` HTTP 内存缓存：确认 cache key/header 归一化、HEAD 合并、HEAD 失败 fallback、cache-time header 移除和 size 上限已有测试覆盖。
- `lib/utils/app_links.dart` / `lib/utils/io.dart` / `lib/network/cloudflare.dart`：确认 app link、file URI、Cloudflare challenge URL 都已使用安全解析 helper，并有对应测试覆盖畸形 URL。
- `lib/utils/data_sync.dart` / `lib/utils/data.dart` / `lib/foundation/local.dart`：确认 WebDAV 配置、远程同步文件名、导入队列、下载任务快照恢复已有边界处理和测试。
- `lib/foundation/comic_details_repository.dart` / `lib/foundation/chapter_pages_repository.dart`：确认坏缓存 payload/timestamp 行已在 `_findCache()` 中捕获、删除并回退网络加载。
- `lib/foundation/appdata.dart` / `lib/main.dart` / `lib/foundation/bootstrap.dart`：确认设置读取、生命周期恢复 flush/鉴权/遮罩、启动后台任务 quiet window 已有 helper 和测试覆盖。

本轮未改原因：

- 未找到“外部输入可直接稳定触发崩溃，且修复不改变业务语义”的新增点。
- 对若干候选继续保持低置信观察，避免把 API 参数约束、同步语义或压缩包第三方行为误判为本轮必须修复。

低置信候选：

- `DataSync.uploadData()` / `downloadData()` 的 `_haveWaitingTask` 语义在并发同步期间会让后续请求快速返回成功；是否应改成排队执行需要产品同步语义确认。
- app data / CBZ / archive 解压仍可继续审计 zip-slip 类风险，但需要构造真实压缩包行为验证，不能仅凭调用 `openAndExtract` 直接判定。
- `convert` 的具体 crypto 参数 schema 可继续细化，但当前已有内部 `try/catch`，坏输入返回 null 的行为是否足够需按漫画源 JS API 语义判断。

追加验证：

- 本轮无代码改动，未新增聚焦测试。
- `git diff -- pubspec.lock` 为空。

## 2026-06-05 第一百二十一轮全项目审查

本轮继续不限于未提交 diff 审查 JS UI 消息边界。
确认的高置信风险在 `UI.launchUrl` 对漫画源传入的动态 `url` 字段直接 `.toString()` 并发起平台 URL 打开。

风险：

- `launchUrl` 属于漫画源 JS 可触发的非关键 UI 副作用，旧代码会把 null、数字、列表或对象转成字符串，例如 `"null"`、`"1"`，再调用 `launchUrlString()`。
- 平台 URL 打开失败返回的是 Future；旧代码没有等待或兜底，失败可能成为未处理异步异常，并污染用户恢复/操作阶段的稳定性。
- 坏 URL 字段不应触发平台 URL 打开，也不应影响 JS UI 调用链。

新增修复：

- 新增 `normalizeJsLaunchUrl()`，仅接受非空字符串 URL，并 trim 两端空白。
- `UI.launchUrl` 对坏值直接跳过；合法 URL 继续调用 `launchUrlString()`。
- 为 `launchUrlString()` 的 Future 增加 `catchError` 日志兜底，避免平台打开失败形成未处理异步异常。

新增/扩展测试：

- `test/js_ui_stability_test.dart` 覆盖合法 URL、空字符串、空白、null、数字和列表输入。

追加验证：

- `flutter test --no-pub test\js_ui_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `UI.showMessage` 仍会把任意非空动态值转成字符串展示；这是展示语义，不作为稳定性修复。
- `showInputDialog` / `showSelectDialog` 的进一步 schema 化可继续审查，但当前已有 title/options/validator/image 边界。

## 2026-06-05 第一百二十二轮全项目审查

本轮继续不限于未提交 diff 审查 JS UI 用户操作回调边界。
确认的高置信风险在 `UI.showLoading` 的 `onCancel` 回调直接执行漫画源 JS function，未捕获同步/异步异常。

风险：

- `showLoading.onCancel` 由漫画源 JS 提供，用户点击取消 loading 弹窗时会执行该回调。
- 旧代码直接 `func?.call([])`，如果源回调同步抛错或返回失败 Future，异常可能沿 UI 操作链冒泡，造成恢复后首次操作或取消弹窗时闪退/未处理异常。
- 取消 loading 是非关键副作用，坏回调不应影响宿主 UI 稳定性。

新增修复：

- 新增 `runJsUiCallbackSafely()`，统一捕获同步异常，并为返回的 Future 增加 `catchError` 日志兜底。
- `showLoading.onCancel` 改为通过该 helper 执行回调；合法回调行为保持不变。

新增/扩展测试：

- `test/js_ui_stability_test.dart` 覆盖正常返回、同步抛错、异步失败 Future 都不会向外抛出。

追加验证：

- `flutter test --no-pub test\js_ui_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `showInputDialog.validator` 回调仍可继续审查；当前其返回值直接用于输入校验文本，异常处理需要兼顾校验语义。
- `_JSCallbackButton.onClick` 已有 try/catch 和 mounted guard，本轮不重复修改。

## 2026-06-05 第一百二十三轮全项目审查

本轮继续不限于未提交 diff 审查 JS UI 输入弹窗 validator 边界。
确认的高置信风险在 `UI.showInputDialog.validator` 回调直接执行漫画源 JS function，未捕获同步/异步异常。

风险：

- `showInputDialog.validator` 由漫画源 JS 提供，用户点击确认时会执行该回调。
- 旧代码直接 `func.call([v])`，如果源 validator 同步抛错或返回失败 Future，异常会穿透输入弹窗确认流程，可能造成用户首次操作、恢复后确认弹窗时崩溃。
- validator 的原语义是返回 `null` 表示通过、非 null 表示错误文本；坏回调应显示校验失败而不是崩溃或错误接受输入。

新增修复：

- 新增 `runJsInputValidatorSafely()`，保留 `null` / 非 null 校验语义，并捕获同步异常和异步 Future 失败。
- 异常路径记录 `Log.error` 并返回固定错误文本 `Validation failed`，让弹窗留在原处。
- `_showInputDialog()` 的 JS validator 路径改用该 helper；合法同步/异步 validator 行为保持不变。

新增/扩展测试：

- `test/js_ui_stability_test.dart` 覆盖 validator 正常通过、返回错误文本、数字错误值转字符串、异步通过、异步错误、同步抛错和异步失败。

追加验证：

- `flutter test --no-pub test\js_ui_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `_InputDialogState._confirm()` 对非 JS onConfirm 仍不捕获调用方异常；这涉及通用组件调用约束，需按具体页面逐项审查。
- `showSelectDialog` 的 options 已过滤为字符串，进一步 UI 行为风险暂未发现高置信崩溃点。

## 2026-06-05 第一百二十四轮全项目审查

本轮继续不限于未提交 diff 审查通用输入弹窗确认回调边界。
确认的高置信风险在 `showInputDialog()` 的 `_InputDialogState._confirm()` 直接调用并等待业务方 `onConfirm`，未捕获同步/异步异常。

风险：

- `showInputDialog()` 是通用用户操作入口，页面保存、重命名、导入、配置等确认动作都可能复用。
- 旧代码直接执行 `widget.onConfirm(_controller.text)`；如果调用方同步抛错或返回失败 Future，异常会穿透按钮点击链，恢复后首次操作时更容易表现为闪退或未处理异常。
- 弹窗确认失败应留在当前弹窗并展示错误，而不是让调用方异常击穿 Flutter 事件处理。

新增修复：

- `_InputDialogState._confirm()` 对同步异常和异步 Future 失败统一 `try/catch`，记录 `Log.error`。
- 异常路径恢复 loading 状态并显示固定错误文本 `Operation failed`，让用户可继续编辑或关闭弹窗。
- 在确认结果处理前补 `mounted` guard，覆盖回调期间弹窗被关闭后又返回错误文本的边界。

新增测试：

- 新增 `test/input_dialog_stability_test.dart`。
- 覆盖成功确认正常关闭、同步抛错不冒泡且显示 `Operation failed`、异步失败不冒泡且显示 `Operation failed`。

追加验证：

- `flutter test --no-pub test\input_dialog_stability_test.dart --reporter=compact`
- `flutter analyze --no-pub`
- `git diff -- pubspec.lock` 为空。
- `git diff --check` 仍只有该 worktree 已知 LF/CRLF 提示。

继续观察但本轮不改的低置信风险：

- `showConfirmDialog()` 的 `onConfirm` 仍是普通同步回调；是否应吞掉调用方异常需要结合具体确认动作语义逐页审查，不能一刀切改变错误传播。
- 其他 `ContentDialog` 自定义 action 回调仍可继续按页面语义审查。

## 2026-06-05 Android profile/logcat 验收流程转向

本轮停止继续无限全项目静态扫代码，改为以 Android 实机/模拟器 profile/logcat
证据决定后续 P0/P1 修复。

Harness 补齐：

- `tools/android_profile_harness.ps1` 默认场景窗口改为 180 秒，后台久置默认 600 秒；
  直接运行时覆盖阅读器 2-3 分钟和后台久置恢复。
- 场景拆分为 `cold-start`、`home-scroll`、`detail-open`、`reader-scroll`、
  `download-sync-while-active`、`resume-first-operation`。
- 每个场景独立生成 `logcat.txt`、`perf-log-lines.txt`、`perf-summary.txt`、
  `crash-markers.txt`、`gfxinfo.txt`、`gfxinfo-framestats.txt`、
  `gfxinfo-headlines.txt`、`meminfo.txt` 和 `summary.md`。
- 无 adb 或无 Android 设备时继续退出码 0 跳过，并在 `summary.md` 写明原因。
- 修正 crash marker 误报：不再把 Android `monkey` 自身正常 `AndroidRuntime`
  启动/退出日志算作 crash。
- 修正 PowerShell native stderr 处理：`monkey` 正常写 stderr 不再中断采集。
- 顶层 `summary.md` 会直接列出每个场景的 crash marker 数量、`[perf]`
  行数和前几条关键耗时。
- 顶层 `summary.md` 会按证据自动列出最多 3 个 `Next Fix Candidates`：
  优先 crash marker，其次明确超阈值的 `[perf]` 耗时，再看足够帧数的 gfxinfo jank。

本地快速采集验证：

- 命令：
  `powershell -NoProfile -ExecutionPolicy Bypass -File tools\android_profile_harness.ps1 -DurationSeconds 1 -ResumeIdleSeconds 1`
- 设备：`emulator-5554`。
- 产物：
  `build\android-profile\20260605-212948\summary.md`。
- 覆盖：冷启动、首页窗口、详情窗口、阅读器窗口、下载/同步窗口、后台 1 秒后恢复首次操作窗口。
- crash marker：所有场景均为 0。
- 关键 `[perf]` 摘要：
  - `home-scroll`: first Flutter frame 2700ms, phaseA ready 2844ms,
    phaseB ready 3558ms, main page visible 4768ms。
  - `detail-open`: scheduled maintenance complete 1165ms。
- gfxinfo 快速样本：
  - 本轮 1 秒快速窗口主要验证 harness 产物结构；多数场景 0-1 帧，不能作为正式
    流畅度结论。
  - 正式验收仍需直接运行默认 180 秒场景窗口和 600 秒后台恢复窗口。

`summary.md` 自动给出的下一批证据优先候选，最多 3 个：

- P1 候选 1：冷启动到首页可交互偏慢。快速样本中 `main page visible 4768ms`，
  需要正式 180 秒窗口或多次 cold-start 复测后，优先定位 phaseA/phaseB 与首屏数据加载。
- P1 候选 2：首个 Flutter frame 偏慢。快速样本中 `first Flutter frame 2700ms`，
  后续正式采集若复现，应先定位 Android 启动、Flutter bootstrap 和首屏前初始化。

本轮不直接修代码的原因：

- 最新采集没有 Venera crash marker。
- 1 秒快速窗口主要验证 harness 结构，不足以证明 reader 连续滚动、后台 10 分钟恢复、
  下载/同步并发恢复的具体代码根因。
- `resume-first-operation` 的 77ms 单帧 jank 是线索但样本太短，不满足“能被 trace/profile
  证明”的修复门槛。

## 参考依据

- Flutter performance best practices:
  <https://docs.flutter.dev/perf/best-practices>
- Flutter `PageController`:
  <https://api.flutter.dev/flutter/widgets/PageController-class.html>
- Flutter `ChangeNotifier.notifyListeners()`:
  <https://api.flutter.dev/flutter/foundation/ChangeNotifier/notifyListeners.html>
- Flutter `NavigatorObserver.didPop()`:
  <https://api.flutter.dev/flutter/widgets/NavigatorObserver/didPop.html>
- Flutter `Image` memory usage and `cacheWidth`/`cacheHeight`:
  <https://api.flutter.dev/flutter/widgets/Image-class.html>
- Flutter `OverlayEntry.remove()`:
  <https://api.flutter.dev/flutter/widgets/OverlayEntry/remove.html>
- Flutter `OverlayEntry.dispose()`:
  <https://api.flutter.dev/flutter/widgets/OverlayEntry/dispose.html>
- Flutter `State.mounted`:
  <https://api.flutter.dev/flutter/widgets/State/mounted.html>
- Android `dumpsys gfxinfo` / `framestats`:
  <https://developer.android.com/tools/dumpsys>
