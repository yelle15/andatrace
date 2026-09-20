import 'package:flutter/material.dart';
import '../processing/preprocessing.dart';
import '../processing/htr_service.dart';
import '../processing/cner_service.dart';
import '../database/local_database_service.dart';

class DigitalizationScreen extends StatefulWidget {
  const DigitalizationScreen({super.key});

  @override
  State<DigitalizationScreen> createState() => _DigitalizationScreenState();
}

class _DigitalizationScreenState extends State<DigitalizationScreen> {
  bool _isProcessing = false;
  String _status = 'Ready to scan nursing note';
  
  Map<String, String>? _transcription;
  List<ClinicalEntity> _entities = [];
  List<FdarRecord> _savedRecords = [];

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    final records = await LocalDatabaseService.getRecords();
    setState(() {
      _savedRecords = records;
    });
  }

  Future<void> _processSampleNote() async {
    setState(() {
      _isProcessing = true;
      _status = 'Preprocessing image (OpenCV deskewing & normalization)...';
    });

    await PreprocessingModule.preprocessImage('sample_nursing_note.png');

    setState(() {
      _status = 'Running Seq2Seq HTR model inference...';
    });

    final htrResult = await HtrService.transcribeFdarNote('sample_nursing_note.png');

    setState(() {
      _status = 'Extracting clinical entities using BioBERT CNER...';
    });

    final extractedEntities = await CnerService.extractEntities(
      '${htrResult['data']} ${htrResult['action']}',
    );

    final newRecord = FdarRecord(
      id: 'REC-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
      timestamp: DateTime.now(),
      focus: htrResult['focus'] ?? '',
      data: htrResult['data'] ?? '',
      action: htrResult['action'] ?? '',
      response: htrResult['response'] ?? '',
      isSynced: false,
    );

    await LocalDatabaseService.saveRecord(newRecord);
    final updatedRecords = await LocalDatabaseService.getRecords();

    setState(() {
      _isProcessing = false;
      _status = 'Digitalization Complete! Saved to local SQLite database.';
      _transcription = htrResult;
      _entities = extractedEntities;
      _savedRecords = updatedRecords;
    });
  }

  Future<void> _triggerSync() async {
    setState(() {
      _status = 'Syncing offline records via PowerSync...';
    });

    final count = await LocalDatabaseService.syncPendingRecords();
    final updatedRecords = await LocalDatabaseService.getRecords();

    setState(() {
      _status = 'PowerSync Delta-Sync finished: $count record(s) uploaded.';
      _savedRecords = updatedRecords;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AndaTrace: Digitalization Pipeline'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Trigger PowerSync Delta-Sync',
            onPressed: _triggerSync,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              color: Colors.teal.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pipeline Status',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text(_status, style: const TextStyle(fontSize: 14)),
                    if (_isProcessing) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isProcessing ? null : _processSampleNote,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Scan & Process Sample Nursing Note (MWE)'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            if (_transcription != null) ...[
              const SizedBox(height: 24),
              const Text(
                'Transcribed FDAR Record (Seq2Seq HTR)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              _buildFdarCard(_transcription!),
            ],
            if (_entities.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text(
                'Extracted Clinical Entities (BioBERT CNER)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _entities
                    .map((e) => Chip(
                          avatar: const Icon(Icons.label, size: 16),
                          label: Text('${e.text} (${e.category})'),
                          backgroundColor: Colors.teal.shade100,
                        ))
                    .toList(),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Local SQLite Records',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                TextButton(
                  onPressed: _triggerSync,
                  child: const Text('Sync All to Cloud'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._savedRecords.map((rec) => ListTile(
                  leading: Icon(
                    rec.isSynced ? Icons.cloud_done : Icons.cloud_off,
                    color: rec.isSynced ? Colors.green : Colors.orange,
                  ),
                  title: Text('Focus: ${rec.focus}'),
                  subtitle: Text('ID: ${rec.id} • ${rec.data}'),
                  trailing: Text(
                    rec.isSynced ? 'Synced' : 'Offline',
                    style: TextStyle(
                      color: rec.isSynced ? Colors.green : Colors.orange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildFdarCard(Map<String, String> fdar) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row('Focus (F):', fdar['focus']),
            _row('Data (D):', fdar['data']),
            _row('Action (A):', fdar['action']),
            _row('Response (R):', fdar['response']),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(color: Colors.black87, fontSize: 14),
          children: [
            TextSpan(text: '$label ', style: const TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: value ?? ''),
          ],
        ),
      ),
    );
  }
}
