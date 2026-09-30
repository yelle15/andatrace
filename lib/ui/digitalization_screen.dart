import 'dart:async';

import 'package:flutter/material.dart';
import 'package:powersync/powersync.dart';

import '../config/app_config.dart';
import '../database/local_database_service.dart';
import '../database/powersync_service.dart';
import '../processing/cner_service.dart';
import '../processing/htr_service.dart';
import '../processing/preprocessing.dart';

/// Minimal Working Example screen for the offline-first pipeline.
///
/// Everything on this screen reads from and writes to the local SQLite
/// database only. There is no "sync" button: PowerSync uploads and downloads
/// in the background whenever a connection exists, and the note list updates
/// itself through a live query (watchPatientNotes).
class DigitalizationScreen extends StatefulWidget {
  const DigitalizationScreen({super.key});

  @override
  State<DigitalizationScreen> createState() => _DigitalizationScreenState();
}

class _DigitalizationScreenState extends State<DigitalizationScreen> {
  static const _patientId = AppConfig.demoPatientId;

  bool _isProcessing = false;
  String _status = 'Ready to scan nursing note';

  Map<String, String>? _transcription;
  List<ClinicalEntity> _entities = [];

  late final Stream<List<Map<String, dynamic>>> _notesStream;

  @override
  void initState() {
    super.initState();
    _notesStream = LocalDatabaseService.watchPatientNotes(_patientId);
  }

  Future<void> _processSampleNote() async {
    setState(() {
      _isProcessing = true;
      _status = 'Preprocessing image (OpenCV deskewing & normalization)...';
    });

    try {
      // Placeholder path until the camera capture path is wired in. The
      // deferred image upload will retry and then park this job, since the
      // file does not exist; that is expected in the MWE.
      const imagePath = 'sample_nursing_note.png';

      await PreprocessingModule.preprocessImage(imagePath);

      setState(() => _status = 'Running Seq2Seq HTR model inference...');
      final htr = await HtrService.transcribeFdarNote(imagePath);

      final fdarText = _formatFdar(htr);

      setState(
        () => _status = 'Extracting clinical entities using BioBERT CNER...',
      );
      final entities = await CnerService.extractEntities(fdarText);

      setState(() => _status = 'Saving to local SQLite database...');
      await LocalDatabaseService.ensurePatient(
        patientId: _patientId,
        mrn: 'MWE-0001',
        firstName: 'Demo',
        lastName: 'Patient',
      );
      await LocalDatabaseService.saveDigitalizedNote(
        noteId: await LocalDatabaseService.newId(),
        patientId: _patientId,
        authorId: PowerSyncService.currentUserId,
        localImagePath: imagePath,
        rawText: fdarText,
        editedText: fdarText,
        meanConfidence: 1.0, // mock HTR has no confidence yet
        cnerEntities: _toEntityRows(fdarText, entities),
      );

      setState(() {
        _status =
            'Saved locally as DRAFT. It will sync automatically when online.';
        _transcription = htr;
        _entities = entities;
      });
    } catch (e) {
      setState(() => _status = 'Could not process note: $e');
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _confirm(String noteId) async {
    try {
      await LocalDatabaseService.confirmNote(noteId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not confirm: $e')));
    }
  }

  static String _formatFdar(Map<String, String> fdar) =>
      'F: ${fdar['focus'] ?? ''}\n'
      'D: ${fdar['data'] ?? ''}\n'
      'A: ${fdar['action'] ?? ''}\n'
      'R: ${fdar['response'] ?? ''}';

  /// Converts CNER output into cner_entities rows, locating each span in the
  /// text so start/end character offsets are real rather than 0.
  static List<Map<String, dynamic>> _toEntityRows(
    String text,
    List<ClinicalEntity> entities,
  ) {
    final lower = text.toLowerCase();
    return entities.map((e) {
      final start = lower.indexOf(e.text.toLowerCase());
      return <String, dynamic>{
        'type': e.category,
        'text': e.text,
        'confidence': 1.0,
        if (start >= 0) 'start': start,
        if (start >= 0) 'end': start + e.text.length,
      };
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AndaTrace: Digitalization Pipeline'),
        actions: const [_SyncIndicator(), SizedBox(width: 12)],
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
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
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
                    .map(
                      (e) => Chip(
                        avatar: const Icon(Icons.label, size: 16),
                        label: Text('${e.text} (${e.category})'),
                        backgroundColor: Colors.teal.shade100,
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 24),
            const Text(
              'Local SQLite Records',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _notesStream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text('Could not load notes: ${snapshot.error}');
                }
                final notes = snapshot.data;
                if (notes == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (notes.isEmpty) {
                  return const Text('No notes yet for this patient.');
                }
                return Column(children: notes.map(_buildNoteTile).toList());
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoteTile(Map<String, dynamic> note) {
    final id = note['id'] as String;
    final entryStatus = note['entry_status'] as String? ?? 'DRAFT';
    final superseded = (note['is_superseded'] as int? ?? 0) == 1;
    final imageSynced = note['sync_status'] == 'SYNCED';
    final text = (note['edited_final_text'] as String? ?? '').split('\n').first;
    final isAmendment = note['amends_note_id'] != null;

    final lifecycle = superseded ? 'AMENDED' : entryStatus;

    return Card(
      child: ListTile(
        leading: Icon(
          imageSynced ? Icons.cloud_done : Icons.cloud_upload_outlined,
          color: imageSynced ? Colors.green : Colors.orange,
        ),
        title: Text(text.isEmpty ? '(no transcription)' : text),
        subtitle: Text(
          '${isAmendment ? 'Amendment · ' : ''}'
          'Image ${imageSynced ? 'uploaded' : 'pending upload'}\n'
          'ID: ${id.length > 8 ? id.substring(0, 8) : id}',
        ),
        isThreeLine: true,
        trailing: entryStatus == 'DRAFT'
            ? TextButton(
                onPressed: () => _confirm(id),
                child: const Text('Confirm'),
              )
            : _LifecycleChip(lifecycle),
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
            TextSpan(
              text: '$label ',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            TextSpan(text: value ?? ''),
          ],
        ),
      ),
    );
  }
}

class _LifecycleChip extends StatelessWidget {
  const _LifecycleChip(this.state);

  final String state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      'CONFIRMED' => Colors.green,
      'AMENDED' => Colors.grey,
      _ => Colors.orange,
    };
    return Text(
      state,
      style: TextStyle(color: color, fontWeight: FontWeight.bold),
    );
  }
}

/// Read-only sync indicator. Sync is automatic; this only reports it.
class _SyncIndicator extends StatelessWidget {
  const _SyncIndicator();

  @override
  Widget build(BuildContext context) {
    if (!PowerSyncService.syncEnabled) {
      return const Tooltip(
        message: 'Local-only mode: no sync backend configured',
        child: Icon(Icons.phone_android),
      );
    }

    return StreamBuilder<SyncStatus>(
      stream: PowerSyncService.syncStatusStream,
      builder: (context, snapshot) {
        final status = snapshot.data;
        final (IconData icon, String label) = switch (status) {
          null => (Icons.cloud_off, 'Offline: saving locally'),
          SyncStatus(uploading: true) => (Icons.cloud_upload, 'Uploading changes'),
          SyncStatus(downloading: true) => (Icons.cloud_download, 'Downloading changes'),
          SyncStatus(connected: true) => (Icons.cloud_done, 'Synced'),
          SyncStatus(connecting: true) => (Icons.cloud_queue, 'Connecting'),
          _ => (Icons.cloud_off, 'Offline: saving locally'),
        };
        return Tooltip(message: label, child: Icon(icon));
      },
    );
  }
}
