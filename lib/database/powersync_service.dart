import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

// ── 1. PowerSync Local Database Schema Definition (Section 3.3.7.2) ─────────
//
// Four SYNCED tables (patients, clinical_notes, htr_transcriptions,
// cner_entities) mirror supabase/migrations/*_andatrace_schema.sql.
//
// Three LOCAL-ONLY tables (sync_queue_log, sync_metrics, consistency_checks)
// hold device bookkeeping and evaluation data. They are never uploaded:
// writes to them do not enter PowerSync's upload queue. This also prevents a
// feedback loop where recording a sync metric would itself need syncing.
const appSchema = Schema([
  Table('patients', [
    Column.text('mrn'),
    Column.text('first_name'),
    Column.text('last_name'),
    Column.text('dob'),
    Column.text('gender'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  Table('clinical_notes', [
    Column.text('patient_id'),
    Column.text('author_id'),
    Column.text('local_image_path'),
    // Object path inside the private Supabase Storage bucket, set after the
    // deferred image upload succeeds (Section 3.3.7.3.3).
    Column.text('remote_image_url'),
    Column.text('note_date'),
    // Image upload status only: 'PENDING' | 'SYNCED'.
    Column.text('sync_status'),
    // ── Append-only revision lineage (Section 3.3.7.3.2) ──
    // 'DRAFT'      -> still owned by the creating device, editable in place.
    // 'CONFIRMED'  -> immutable; no further in-place edits to clinical content.
    // 'AMENDED' is derived, not stored: a note is superseded when another
    // row's amends_note_id points to it. Corrections insert a NEW row instead
    // of mutating the confirmed one, so concurrent offline edits cannot
    // overwrite each other and the audit trail is preserved.
    Column.text('entry_status'), // 'DRAFT' | 'CONFIRMED'
    Column.text('amends_note_id'), // nullable FK to the note this amends
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  Table('htr_transcriptions', [
    Column.text('note_id'),
    Column.text('raw_predicted_text'),
    Column.text('edited_final_text'),
    Column.real('mean_confidence'),
    Column.real('cer_score'),
    Column.integer('is_verified'),
    Column.text('processed_at'),
    Column.text('updated_at'),
  ]),
  Table('cner_entities', [
    Column.text('transcription_id'),
    Column.text('entity_type'),
    Column.text('entity_text'),
    Column.real('confidence'),
    Column.integer('start_char_idx'),
    Column.integer('end_char_idx'),
    Column.text('created_at'),
  ]),
  // ── Local-only: deferred binary upload queue (Section 3.3.7.3.3) ──
  Table.localOnly('sync_queue_log', [
    Column.text('entity_id'),
    Column.text('entity_table'),
    Column.text('operation_type'),
    Column.text('payload_json'),
    Column.text('timestamp'),
    Column.integer('retry_count'),
    // Timestamp of the last failed attempt, used for exponential backoff.
    Column.text('last_attempt_at'),
    // Set once retry_count reaches the max and the job is parked
    // (dead-letter), so the UI can surface it instead of retrying forever.
    Column.integer('failed'),
  ]),
  // ── Local-only: sync performance / consistency instrumentation ──
  Table.localOnly('sync_metrics', [
    Column.text('entity_id'),
    Column.text('entity_table'),
    Column.text('operation_type'), // PUT | PATCH | DELETE | IMAGE_UPLOAD
    Column.text('local_committed_at'), // when the write landed in local SQLite
    Column.text('server_ack_at'), // when Supabase confirmed the write
    Column.integer('latency_ms'), // server_ack_at - local_committed_at
    Column.text('connectivity_state'), // 'offline_then_synced' | 'online'
  ]),
  Table.localOnly('consistency_checks', [
    Column.text('checked_at'),
    Column.integer('local_row_count'),
    Column.integer('remote_row_count'),
    Column.text('local_hash'),
    Column.text('remote_hash'),
    Column.integer('is_consistent'), // 1 = match, 0 = mismatch
  ]),
]);

// ── 2. PowerSync Service Implementation ──────────────────────────────────────
class PowerSyncService {
  static late final PowerSyncDatabase db;

  /// False when the app runs in local-only mode (no backend configured, or
  /// Supabase failed to initialize). Everything still works on-device.
  static bool syncEnabled = false;

  static SupabaseConnector? _connector;
  static Timer? _signInRetryTimer;
  static const _signInRetryInterval = Duration(seconds: 60);

  /// Opens the local SQLite database. This never needs the network, so the
  /// app is usable immediately even on first launch in a dead zone.
  ///
  /// If [enableSync] is true, Supabase must already be initialized. Sync
  /// then starts in the background as soon as the device has a session.
  static Future<void> init({required bool enableSync}) async {
    // On web there is no file system: the database lives in the browser
    // (IndexedDB / OPFS) and is addressed by name only.
    final String dbPath;
    if (kIsWeb) {
      dbPath = 'andatrace_local.db';
    } else {
      final dir = await getApplicationSupportDirectory();
      dbPath = p.join(dir.path, 'andatrace_local.db');
    }

    db = PowerSyncDatabase(schema: appSchema, path: dbPath);
    await db.initialize();

    syncEnabled = enableSync;
    if (!enableSync) return;

    final auth = Supabase.instance.client.auth;

    auth.onAuthStateChange.listen((data) async {
      switch (data.event) {
        case AuthChangeEvent.signedIn:
          _connect();
          break;
        case AuthChangeEvent.signedOut:
          // Disconnect but KEEP local data: unsynced notes must survive.
          _connector = null;
          await db.disconnect();
          break;
        case AuthChangeEvent.tokenRefreshed:
          _connector?.prefetchCredentials();
          break;
        default:
          break;
      }
    });

    if (auth.currentSession != null) {
      // Session restored from device storage; works offline.
      _connect();
    } else {
      unawaited(_ensureSignedIn());
    }
  }

  static void _connect() {
    _connector = SupabaseConnector();
    db.connect(connector: _connector!);
  }

  /// Prototype authentication: Supabase anonymous sign-in gives each device
  /// a stable identity so Row Level Security can admit it. Needs the network
  /// once; if offline, it retries in the background without blocking the UI.
  /// Replace with real nurse accounts before deployment.
  static Future<void> _ensureSignedIn() async {
    _signInRetryTimer?.cancel();
    final auth = Supabase.instance.client.auth;
    if (auth.currentSession != null) return;
    try {
      await auth.signInAnonymously();
      // onAuthStateChange(signedIn) connects PowerSync.
    } catch (e) {
      debugPrint('AndaTrace: sign-in unavailable (likely offline), retrying: $e');
      _signInRetryTimer = Timer(_signInRetryInterval, _ensureSignedIn);
    }
  }

  /// Id recorded as author_id on new notes. Before the device has ever
  /// signed in, notes are attributed to 'local-device'.
  static String get currentUserId {
    if (!syncEnabled) return 'local-device';
    return Supabase.instance.client.auth.currentUser?.id ?? 'local-device';
  }

  static Stream<SyncStatus> get syncStatusStream => db.statusStream;
}

// ── 3. Supabase Connector & Upstream Delta Sync ──────────────────────────────

/// Postgres error codes that retrying cannot fix. Without this list, one bad
/// row would block the upload queue forever and nothing after it would sync.
final List<RegExp> _fatalResponseCodes = [
  RegExp(r'^22...$'), // Class 22: data exception (e.g. type mismatch)
  RegExp(r'^23...$'), // Class 23: integrity constraint violation, including
  //                     the CONFIRMED-record guard triggers (23514)
  RegExp(r'^42501$'), // insufficient privilege, e.g. Row Level Security
];

class SupabaseConnector extends PowerSyncBackendConnector {
  Future<void>? _refreshFuture;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    await _refreshFuture;

    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return null;

    return PowerSyncCredentials(
      endpoint: AppConfig.powersyncUrl,
      token: session.accessToken,
      userId: session.user.id,
      expiresAt: session.expiresAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(session.expiresAt! * 1000),
    );
  }

  @override
  void invalidateCredentials() {
    // Called when PowerSync rejects the token, e.g. it expired while the
    // device was offline for a long shift. Refresh without blocking.
    _refreshFuture = Supabase.instance.client.auth
        .refreshSession()
        .timeout(const Duration(seconds: 5))
        .then((_) => null, onError: (_) => null);
  }

  /// Called by PowerSync whenever local changes are waiting and the device
  /// is connected. Throwing makes PowerSync retry later; the local data is
  /// untouched either way.
  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final transaction = await database.getNextCrudTransaction();
    if (transaction == null) return;

    final rest = Supabase.instance.client.rest;
    CrudEntry? lastOp;

    try {
      for (final op in transaction.crud) {
        lastOp = op;

        final localCommittedAt =
            op.opData?['updated_at'] as String? ??
            op.opData?['created_at'] as String? ??
            DateTime.now().toUtc().toIso8601String();

        final table = rest.from(op.table);

        switch (op.op) {
          case UpdateType.put:
            // opData does not include the primary key; add it back.
            final data = Map<String, dynamic>.of(op.opData!);
            data['id'] = op.id;
            await table.upsert(data);
            break;
          case UpdateType.patch:
            await table.update(op.opData!).eq('id', op.id);
            break;
          case UpdateType.delete:
            await table.delete().eq('id', op.id);
            break;
        }

        // Objective 4 instrumentation: local-commit-to-server-ack latency.
        await _recordSyncMetric(
          database: database,
          entityId: op.id,
          entityTable: op.table,
          operationType: op.op.name.toUpperCase(),
          localCommittedAt: localCommittedAt,
        );
      }

      await transaction.complete();
    } on PostgrestException catch (e) {
      final code = e.code;
      if (code != null && _fatalResponseCodes.any((re) => re.hasMatch(code))) {
        // Permanent rejection (e.g. an edit to a CONFIRMED note). Skip it so
        // the rest of the queue can sync. The row still exists locally, and
        // SyncConsistencyChecker will report the divergence.
        debugPrint(
          'AndaTrace: server rejected $lastOp permanently: ${e.message}',
        );
        await transaction.complete();
      } else {
        rethrow; // Transient (network, 5xx): PowerSync retries later.
      }
    }
  }

  /// Records local-commit-to-server-ack latency into the local-only
  /// sync_metrics table. Local write only, so it never blocks sync.
  Future<void> _recordSyncMetric({
    required PowerSyncDatabase database,
    required String entityId,
    required String entityTable,
    required String operationType,
    required String localCommittedAt,
  }) async {
    final ackAt = DateTime.now().toUtc();
    final committedAt = DateTime.tryParse(localCommittedAt)?.toUtc() ?? ackAt;
    final latencyMs = ackAt.difference(committedAt).inMilliseconds;

    await database.execute(
      '''
      INSERT INTO sync_metrics
        (id, entity_id, entity_table, operation_type, local_committed_at, server_ack_at, latency_ms, connectivity_state)
      VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        entityId,
        entityTable,
        operationType,
        localCommittedAt,
        ackAt.toIso8601String(),
        latencyMs < 0 ? 0 : latencyMs,
        'offline_then_synced',
      ],
    );
  }
}
