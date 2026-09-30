import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_config.dart';
import 'database/powersync_service.dart';
import 'database/sync_consistency_checker.dart';
import 'database/sync_queue_manager.dart';
import 'ui/digitalization_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 1. Backend client (optional) ─────────────────────────────────────────
  // Supabase.initialize restores any saved session from device storage and
  // does not need the network. If the backend is not configured, or init
  // fails, the app continues in local-only mode.
  var syncEnabled = false;
  if (AppConfig.isSyncConfigured) {
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: AppConfig.supabasePublishableKey,
      );
      syncEnabled = true;
    } catch (e) {
      debugPrint('AndaTrace: Supabase init failed, running local-only: $e');
    }
  } else {
    debugPrint(
      'AndaTrace: no backend configured (see config/app_config.example.json), '
      'running local-only.',
    );
  }

  // ── 2. Local database first (offline-first, Section 3.3.7) ───────────────
  await PowerSyncService.init(enableSync: syncEnabled);

  // ── 3. Background sync helpers, only when a backend exists ───────────────
  if (syncEnabled) {
    // Drain the deferred image-upload queue on each offline -> online edge.
    SyncQueueManager.startAutoSync();

    // Post-sync consistency check (Section 3.3.7.3.4): run once per
    // reconnect, only after pending uploads are flushed and a download has
    // completed, so unsent local rows are not counted as drift.
    var wasConnected = false;
    var checkPending = false;
    PowerSyncService.syncStatusStream.listen((status) {
      if (status.connected && !wasConnected) checkPending = true;
      wasConnected = status.connected;

      final settled =
          status.connected &&
          !status.uploading &&
          !status.downloading &&
          status.hasSynced == true;
      if (checkPending && settled) {
        checkPending = false;
        unawaited(
          SyncConsistencyChecker.runCheck().catchError((Object e) {
            debugPrint('AndaTrace: consistency check failed: $e');
            return false;
          }),
        );
      }
    });
  }

  runApp(const AndaTraceApp());
}

class AndaTraceApp extends StatelessWidget {
  const AndaTraceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AndaTrace',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const DigitalizationScreen(),
    );
  }
}
