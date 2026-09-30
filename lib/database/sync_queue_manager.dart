import 'dart:async';
import 'dart:io';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';
import 'powersync_service.dart';

/// Manages deferred background binary file uploads (Section 3.3.7.3.3).
/// Large image captures are stored in device storage and synced out-of-band.
class SyncQueueManager {
  static final _supabase = Supabase.instance.client;
  static const int _maxRetries = 5;

  static StreamSubscription<SyncStatus>? _statusSub;
  static bool _isProcessing = false;

  /// Starts listening to PowerSync's connectivity status and automatically
  /// (re)triggers image upload processing whenever the device transitions
  /// from offline/disconnected to connected. Call this once, e.g. right
  /// after PowerSyncService.init() in main().
  static void startAutoSync() {
    _statusSub?.cancel();
    bool wasConnected = false;

    _statusSub = PowerSyncService.syncStatusStream.listen((status) {
      final isConnected = status.connected;
      if (isConnected && !wasConnected) {
        // Just came back online: drain the pending image upload queue.
        processPendingUploads();
      }
      wasConnected = isConnected;
    });
  }

  static void dispose() {
    _statusSub?.cancel();
    _statusSub = null;
  }

  /// Scans sync_queue_log in local SQLite for pending binary upload jobs.
  static Future<void> processPendingUploads() async {
    // Avoid overlapping runs if reconnect fires again mid-drain.
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      // 1. Fetch pending, non-dead-lettered uploads from local SQLite
      final pendingItems = await PowerSyncService.db.getAll(
        "SELECT * FROM sync_queue_log WHERE operation_type = 'INSERT' AND failed = 0 AND retry_count < ? ORDER BY timestamp ASC",
        [_maxRetries],
      );

      if (pendingItems.isEmpty) return;

      for (var item in pendingItems) {
        await _processOne(item);
      }
    } finally {
      _isProcessing = false;
    }
  }

  static Future<void> _processOne(Map<String, dynamic> item) async {
    final queueId = item['id'] as String;
    final noteId = item['entity_id'] as String;
    final retryCount = item['retry_count'] as int? ?? 0;
    final lastAttemptAt = item['last_attempt_at'] as String?;

    // Exponential backoff: skip this item if it hasn't waited long enough
    // since its last attempt (2^retryCount seconds, capped at 5 minutes).
    if (lastAttemptAt != null) {
      final last = DateTime.tryParse(lastAttemptAt);
      if (last != null) {
        final backoffSeconds = (1 << retryCount).clamp(1, 300);
        final readyAt = last.add(Duration(seconds: backoffSeconds));
        if (DateTime.now().isBefore(readyAt)) return;
      }
    }

    final startedAt = DateTime.now().toUtc();

    try {
      // Fetch the corresponding note to get the local image path
      final noteRows = await PowerSyncService.db.getAll(
        "SELECT local_image_path FROM clinical_notes WHERE id = ?",
        [noteId],
      );

      if (noteRows.isEmpty) {
        // Note was deleted locally; remove orphan queue item
        await PowerSyncService.db.execute(
          "DELETE FROM sync_queue_log WHERE id = ?",
          [queueId],
        );
        return;
      }

      final localPath = noteRows.first['local_image_path'] as String;
      final file = File(localPath);

      if (await file.exists()) {
        final fileName = 'note_$noteId.jpg';

        // 2. Upload high-res image binary to the PRIVATE Supabase Storage
        //    bucket. upsert: true makes a retry of a half-finished upload safe.
        await _supabase.storage
            .from(AppConfig.imageBucket)
            .upload(
              fileName,
              file,
              fileOptions: const FileOptions(upsert: true),
            );

        final ackAt = DateTime.now().toUtc();

        // 3. Record the storage object path (not a public URL: patient note
        //    images must not be publicly reachable; view them via signed
        //    URLs) and mark the image as synced. These are sync-bookkeeping
        //    columns, which the server guard allows even on CONFIRMED notes.
        await PowerSyncService.db.execute(
          "UPDATE clinical_notes SET remote_image_url = ?, sync_status = 'SYNCED', updated_at = ? WHERE id = ?",
          [fileName, ackAt.toIso8601String(), noteId],
        );

        // 4. Delete job from sync queue
        await PowerSyncService.db.execute(
          "DELETE FROM sync_queue_log WHERE id = ?",
          [queueId],
        );

        // ── Objective 4 instrumentation: image upload latency ──
        await PowerSyncService.db.execute(
          '''
          INSERT INTO sync_metrics
            (id, entity_id, entity_table, operation_type, local_committed_at, server_ack_at, latency_ms, connectivity_state)
          VALUES (?, ?, 'clinical_notes', 'IMAGE_UPLOAD', ?, ?, ?, 'offline_then_synced')
          ''',
          [
            'sm_img_${noteId}_${ackAt.microsecondsSinceEpoch}',
            noteId,
            startedAt.toIso8601String(),
            ackAt.toIso8601String(),
            ackAt.difference(startedAt).inMilliseconds,
          ],
        );
      } else {
        // File missing from local storage; flag retry count
        await _incrementRetryCount(queueId, retryCount);
      }
    } catch (e) {
      // Network timeout or offline state; increment retry counter
      await _incrementRetryCount(queueId, retryCount);
    }
  }

  static Future<void> _incrementRetryCount(
    String queueId,
    int currentRetryCount,
  ) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final nextCount = currentRetryCount + 1;
    final isDead = nextCount >= _maxRetries;

    await PowerSyncService.db.execute(
      "UPDATE sync_queue_log SET retry_count = ?, last_attempt_at = ?, failed = ? WHERE id = ?",
      [nextCount, now, isDead ? 1 : 0, queueId],
    );
  }

  /// Jobs that exhausted retries and are parked, for the UI to surface
  /// (e.g. "3 notes failed to sync their images — tap to retry").
  static Future<List<Map<String, dynamic>>> getFailedUploads() {
    return PowerSyncService.db.getAll(
      "SELECT * FROM sync_queue_log WHERE failed = 1 ORDER BY timestamp DESC",
    );
  }

  /// Resets a dead-lettered job so it's picked up again on the next drain.
  static Future<void> retryFailedUpload(String queueId) async {
    await PowerSyncService.db.execute(
      "UPDATE sync_queue_log SET retry_count = 0, failed = 0, last_attempt_at = NULL WHERE id = ?",
      [queueId],
    );
  }
}
