import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:swipe_cards/swipe_cards.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  runApp(const GalleryCleanerApp());
}

class GalleryCleanerApp extends StatefulWidget {
  const GalleryCleanerApp({super.key});

  @override
  State<GalleryCleanerApp> createState() => _GalleryCleanerAppState();
}

class _GalleryCleanerAppState extends State<GalleryCleanerApp> {
  bool _isFirstRun = true;

  @override
  void initState() {
    super.initState();
    _loadFirstRun();
  }

  Future<void> _loadFirstRun() async {
    final prefs = await SharedPreferences.getInstance();
    final firstRun = prefs.getBool('first_run') ?? true;
    setState(() {
      _isFirstRun = firstRun;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gallery Cleaner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: _isFirstRun ? const OnboardingScreen() : const HomeScreen(),
    );
  }
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _photosPerSession = 20;
  bool _filterDuplicates = true;
  bool _filterBlur = false;
  bool _notificationsEnabled = true;

  Future<void> _saveAndContinue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('photos_per_session', _photosPerSession);
    await prefs.setBool('filter_duplicates', _filterDuplicates);
    await prefs.setBool('filter_blur', _filterBlur);
    await prefs.setBool('notifications_enabled', _notificationsEnabled);
    await prefs.setBool('first_run', false);

    if (_notificationsEnabled) {
      await scheduleHourlyNotifications();
    }

    if (context.mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Первый запуск — настройки'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            const Text('Сколько фото за сессию?'),
            Slider(
              value: _photosPerSession.toDouble(),
              min: 10,
              max: 50,
              divisions: 4,
              label: '$_photosPerSession',
              onChanged: (v) => setState(() => _photosPerSession = v.round()),
            ),
            SwitchListTile(
              title: const Text('Фильтровать дубликаты'),
              value: _filterDuplicates,
              onChanged: (v) => setState(() => _filterDuplicates = v),
            ),
            SwitchListTile(
              title: const Text('Фильтровать смазанные (упрощённо)'),
              value: _filterBlur,
              onChanged: (v) => setState(() => _filterBlur = v),
            ),
            SwitchListTile(
              title: const Text('Уведомления каждый час'),
              value: _notificationsEnabled,
              onChanged: (v) => setState(() => _notificationsEnabled = v),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _saveAndContinue,
              child: const Text('Продолжить'),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<AssetEntity> _photos = [];
  bool _loading = true;
  int _photosPerSession = 20;
  bool _filterDuplicates = true;
  
  bool _filterBlur = false;
  bool _notificationsEnabled = true;

  MatchEngine? _matchEngine;
  List<SwipeItem> _swipeItems = [];

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    await _loadSettings();
    await _requestPermissions();
    await _loadPhotos();
    await cancelNotificationsIfAny();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _photosPerSession = prefs.getInt('photos_per_session') ?? 20;
    _filterDuplicates = prefs.getBool('filter_duplicates') ?? true;
    _filterBlur = prefs.getBool('filter_blur') ?? false;
    _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
  }

  Future<void> _requestPermissions() async {
    final result = await PhotoManager.requestPermissionExtend();
    if (!result.isAuth) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нет доступа к фото')),
        );
      }
      setState(() => _loading = false);
      return;
    }
  }

  Future<void> _loadPhotos() async {
    setState(() => _loading = true);

    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);

    final List<AssetEntity> allPhotos = [];
    for (final album in albums) {
      final photos = await album.getAssetListPaged(page: 0, size: 1000);
      allPhotos.addAll(photos);
    }

    var filtered = allPhotos;

    if (_filterDuplicates) {
      filtered = await _filterDuplicatePhotos(filtered);
    }

    filtered.shuffle(Random());
    if (filtered.length > _photosPerSession) {
      filtered = filtered.sublist(0, _photosPerSession);
    }

    _photos = filtered;
    _buildSwipeItems();

    setState(() => _loading = false);
  }

  Future<List<AssetEntity>> _filterDuplicatePhotos(List<AssetEntity> photos) async {
    final Map<String, AssetEntity> unique = {};
    for (final photo in photos) {
      final file = await photo.file;
      if (file == null) continue;
      final key = '${file.lengthSync()}_${photo.width}_${photo.height}';
      if (!unique.containsKey(key)) {
        unique[key] = photo;
      }
    }
    return unique.values.toList();
  }

  void _buildSwipeItems() {
    _swipeItems = _photos
        .map(
          (photo) => SwipeItem(
            content: photo,
            likeAction: () {},
            nopeAction: () async {
              final file = await photo.file;
              if (file != null) {
                await PhotoManager.editor.deleteWithIds([photo.id]);
              }
            },
          ),
        )
        .toList();

    _matchEngine = MatchEngine(swipeItems: _swipeItems);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    await _initAll();
  }

  @override
  void dispose() {
    if (_notificationsEnabled) {
      scheduleHourlyNotifications();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _photos.isEmpty
            ? const Center(child: Text('Нет фото для обработки'))
            : Center(
                child: SizedBox(
                  height: MediaQuery.of(context).size.height * 0.7,
                  child: SwipeCards(
                    matchEngine: _matchEngine!,
                    itemBuilder: (context, index) {
                      final photo = _photos[index];
                      return FutureBuilder<File?>(
                        future: photo.file,
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          return Card(
                            margin: const EdgeInsets.all(16),
                            child: Image.file(snapshot.data!, fit: BoxFit.cover),
                          );
                        },
                      );
                    },
                    onStackFinished: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Сессия завершена')),
                      );
                    },
                  ),
                ),
              );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Чистка галереи'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadPhotos),
        ],
      ),
      body: body,
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _photosPerSession = 20;
  bool _filterDuplicates = true;
  bool _filterBlur = false;
  bool _notificationsEnabled = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _photosPerSession = prefs.getInt('photos_per_session') ?? 20;
      _filterDuplicates = prefs.getBool('filter_duplicates') ?? true;
      _filterBlur = prefs.getBool('filter_blur') ?? false;
      _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('photos_per_session', _photosPerSession);
    await prefs.setBool('filter_duplicates', _filterDuplicates);
    await prefs.setBool('filter_blur', _filterBlur);
    await prefs.setBool('notifications_enabled', _notificationsEnabled);

    if (_notificationsEnabled) {
      await scheduleHourlyNotifications();
    } else {
      await cancelNotificationsIfAny();
    }

    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            const Text('Сколько фото за сессию?'),
            Slider(
              value: _photosPerSession.toDouble(),
              min: 10,
              max: 50,
              divisions: 4,
              label: '$_photosPerSession',
              onChanged: (v) => setState(() => _photosPerSession = v.round()),
            ),
            SwitchListTile(
              title: const Text('Фильтровать дубликаты'),
              value: _filterDuplicates,
              onChanged: (v) => setState(() => _filterDuplicates = v),
            ),
            SwitchListTile(
              title: const Text('Фильтровать смазанные (упрощённо)'),
              value: _filterBlur,
              onChanged: (v) => setState(() => _filterBlur = v),
            ),
            SwitchListTile(
              title: const Text('Уведомления каждый час'),
              value: _notificationsEnabled,
              onChanged: (v) => setState(() => _notificationsEnabled = v),
            ),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: _save, child: const Text('Сохранить')),
          ],
        ),
      ),
    );
  }
}

Future<void> scheduleHourlyNotifications() async {
  const androidDetails = AndroidNotificationDetails(
    'hourly_channel',
    'Hourly Notifications',
    channelDescription: 'Reminds to clean gallery every hour',
    importance: Importance.max,
    priority: Priority.high,
  );

  const details = NotificationDetails(android: androidDetails);

  await flutterLocalNotificationsPlugin.cancelAll();

  await flutterLocalNotificationsPlugin.periodicallyShow(
    0,
    'Пора чистить память',
    'Зайди в приложение и разберись с фото',
    RepeatInterval.hourly,
    details,
    androidAllowWhileIdle: true,
  );
}

Future<void> cancelNotificationsIfAny() async {
  await flutterLocalNotificationsPlugin.cancelAll();
}
