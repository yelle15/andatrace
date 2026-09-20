import 'package:flutter/foundation.dart';

class FdarRecord {
  final String id;
  final DateTime timestamp;
  final String focus;
  final String data;
  final String action;
  final String response;
  final bool isSynced;

  FdarRecord({
    required this.id,
    required this.timestamp,
    required this.focus,
    required this.data,
    required this.action,
    required this.response,
    this.isSynced = false,
  });
}

/// Simulated Local SQLite & PowerSync Sync Service
class LocalDatabaseService {
  static final List<FdarRecord> _localStorage = [
    FdarRecord(
      id: 'REC-001',
      timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      focus: 'Fever',
      data: 'Temp 38.5 C, flushed skin',
      action: 'Given Paracetamol 500mg PO',
      response: 'Temp reduced to 37.1 C',
      isSynced: true,
    ),
  ];

  static Future<List<FdarRecord>> getRecords() async {
    return List.unmodifiable(_localStorage);
  }

  static Future<void> saveRecord(FdarRecord record) async {
    _localStorage.insert(0, record);
    if (kDebugMode) {
      print('Record saved to local SQLite DB: ${record.id}');
    }
  }

  static Future<int> syncPendingRecords() async {
    await Future.delayed(const Duration(milliseconds: 600));
    int syncedCount = 0;
    for (int i = 0; i < _localStorage.length; i++) {
      if (!_localStorage[i].isSynced) {
        _localStorage[i] = FdarRecord(
          id: _localStorage[i].id,
          timestamp: _localStorage[i].timestamp,
          focus: _localStorage[i].focus,
          data: _localStorage[i].data,
          action: _localStorage[i].action,
          response: _localStorage[i].response,
          isSynced: true,
        );
        syncedCount++;
      }
    }
    return syncedCount;
  }
}
