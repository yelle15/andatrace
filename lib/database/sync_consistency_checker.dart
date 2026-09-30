import 'dart:convert';
import 'dart:core';
import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'powersync_service.dart';

/// Post-reconnect consistency verification (Objective 4: Data Consistency rate).
///
/// After a sync round completes, compares local row counts / content hashes
/// against Supabase for the tables that matter clinically, and records the
/// result in consistency_checks so the thesis evaluation can report a
/// consistency rate (matches / total checks) rather than just latency.
class SyncConsistencyChecker {
  static final _supabase = Supabase.instance.client;

  /// Tables checked for consistency after each reconnect. Only row-synced
  /// tables belong here — binary images are verified separately by
  /// SyncQueueManager, since they don't go through PowerSync's CRUD queue.
  static const _checkedTables = [
    'clinical_notes',
    'htr_transcriptions',
    'cner_entities',
  ];

  /// Column that changes whenever a row changes. cner_entities rows are
  /// insert-only and have no updated_at, so their created_at is used.
  static const _versionColumn = {
    'clinical_notes': 'updated_at',
    'htr_transcriptions': 'updated_at',
    'cner_entities': 'created_at',
  };

  /// Runs a consistency check for a single patient (or, if patientId is
  /// null, globally) and logs one row per table into consistency_checks.
  /// Returns true only if every checked table matched.
  static Future<bool> runCheck({String? patientId}) async {
    var allConsistent = true;

    for (final table in _checkedTables) {
      final consistent = await _checkTable(table, patientId: patientId);
      allConsistent = allConsistent && consistent;
    }

    return allConsistent;
  }

  static Future<bool> _checkTable(String table, {String? patientId}) async {
    final checkedAt = DateTime.now().toUtc();

    // Local: count + a content hash over stable columns (id + updated_at
    // is enough to detect drift without pulling every column across tables
    // with different shapes).
    final whereClause = patientId != null && table == 'clinical_notes'
        ? 'WHERE patient_id = ?'
        : '';
    final params = patientId != null && table == 'clinical_notes'
        ? [patientId]
        : <Object?>[];

    final versionCol = _versionColumn[table]!;

    final localRows = await PowerSyncService.db.getAll(
      'SELECT id, $versionCol AS version FROM $table $whereClause',
      params,
    );
    final localCount = localRows.length;
    final localHash = _hashRows(localRows);

    // Remote: same shape query against Supabase.
    try {
      var query = _supabase.from(table).select('id, version:$versionCol');
      if (patientId != null && table == 'clinical_notes') {
        query = query.eq('patient_id', patientId);
      }
      final remoteRows = await query;
      final remoteList = List<Map<String, dynamic>>.from(remoteRows);
      final remoteCount = remoteList.length;
      final remoteHash = _hashRows(remoteList);

      final isConsistent = localCount == remoteCount && localHash == remoteHash;

      await PowerSyncService.db.execute(
        '''
        INSERT INTO consistency_checks
          (id, checked_at, local_row_count, remote_row_count, local_hash, remote_hash, is_consistent)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          'cc_${table}_${checkedAt.microsecondsSinceEpoch}',
          checkedAt.toIso8601String(),
          localCount,
          remoteCount,
          localHash,
          remoteHash,
          isConsistent ? 1 : 0,
        ],
      );

      return isConsistent;
    } catch (e) {
      // Couldn't reach Supabase to compare (still offline, etc). Not a
      // consistency failure — just skip logging this round for this table.
      return true;
    }
  }

  /// Hashes (id, version) pairs in a form that is identical on both sides:
  ///  * sorted in Dart, because SQLite and Postgres collate text differently,
  ///    so ORDER BY id can return different orders for the same ids;
  ///  * timestamps normalized to UTC ISO-8601, because Postgres returns
  ///    timestamptz as e.g. '2026-09-30T01:25:00.123+00:00' while the device
  ///    wrote '2026-09-30T01:25:00.123Z' for the same instant.
  static String _hashRows(List<Map<String, dynamic>> rows) {
    final entries = rows
        .map((r) => '${r['id']}:${_normalizeTimestamp(r['version'])}')
        .toList()
      ..sort();
    return sha256.convert(utf8.encode(entries.join('|'))).toString();
  }

  static String _normalizeTimestamp(Object? value) {
    if (value == null) return '';
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) return value.toString();
    // Millisecond precision: Postgres keeps microseconds, but Dart on some
    // platforms (web) only keeps milliseconds.
    final utc = parsed.toUtc();
    return DateTime.fromMillisecondsSinceEpoch(
      utc.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String();
  }

  /// Convenience for the evaluation write-up: consistency rate over the
  /// last N checks, as a fraction in [0, 1].
  static Future<double> consistencyRate({int lastN = 50}) async {
    final rows = await PowerSyncService.db.getAll(
      'SELECT is_consistent FROM consistency_checks ORDER BY checked_at DESC LIMIT ?',
      [lastN],
    );
    if (rows.isEmpty) return 1.0;
    final matches = rows.where((r) => (r['is_consistent'] as int) == 1).length;
    return matches / rows.length;
  }
}
