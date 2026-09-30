import 'powersync_service.dart';

class LocalDatabaseService {
  /// Saves a complete digitalization result (Note, HTR Transcription, Entities) in a single local batch.
  /// New notes are always created as DRAFT: still owned by this device, so
  /// concurrent edits to a draft are safe under PowerSync's default
  /// last-write-wins, since only the creating device edits it.
  static Future<void> saveDigitalizedNote({
    required String noteId,
    required String patientId,
    required String authorId,
    required String localImagePath,
    required String rawText,
    required String editedText,
    required double meanConfidence,
    required List<Map<String, dynamic>> cnerEntities,
    String? amendsNoteId,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();

    // PowerSync handles transactions synchronously locally
    await PowerSyncService.db.writeTransaction((tx) async {
      // 1. Insert Clinical Note
      await tx.execute(
        '''
        INSERT INTO clinical_notes
          (id, patient_id, author_id, local_image_path, note_date, sync_status, entry_status, amends_note_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'PENDING', 'DRAFT', ?, ?, ?)
      ''',
        [
          noteId,
          patientId,
          authorId,
          localImagePath,
          now,
          amendsNoteId,
          now,
          now,
        ],
      );

      // 2. Insert HTR Transcription Output
      final transcriptionId = 'tx_$noteId';
      await tx.execute(
        '''
        INSERT INTO htr_transcriptions (id, note_id, raw_predicted_text, edited_final_text, mean_confidence, is_verified, processed_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 0, ?, ?)
      ''',
        [
          transcriptionId,
          noteId,
          rawText,
          editedText,
          meanConfidence,
          now,
          now,
        ],
      );

      // 3. Insert Extracted BioBERT Medical Entities
      for (var i = 0; i < cnerEntities.length; i++) {
        final entity = cnerEntities[i];
        await tx.execute(
          '''
          INSERT INTO cner_entities (id, transcription_id, entity_type, entity_text, confidence, start_char_idx, end_char_idx, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
          [
            'ent_${noteId}_$i',
            transcriptionId,
            entity['type'],
            entity['text'],
            entity['confidence'] ?? 1.0,
            entity['start'] ?? 0,
            entity['end'] ?? 0,
            now,
          ],
        );
      }

      // 4. Log job in sync_queue_log for deferred binary image upload
      await tx.execute(
        '''
        INSERT INTO sync_queue_log (id, entity_id, entity_table, operation_type, payload_json, timestamp, retry_count, last_attempt_at, failed)
        VALUES (?, ?, 'clinical_notes', 'INSERT', ?, ?, 0, NULL, 0)
      ''',
        ['sq_$noteId', noteId, '{"path": "$localImagePath"}', now],
      );
    });
  }

  /// Edits a note's transcription while it is still a DRAFT (pre-confirmation).
  /// Safe to call repeatedly from the same device: PowerSync's default
  /// last-write-wins is fine here because a draft is only ever touched by
  /// the device that created it.
  static Future<void> updateDraftTranscription({
    required String noteId,
    required String editedText,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final status = await _entryStatus(noteId);
    if (status != 'DRAFT') {
      throw StateError(
        'Note $noteId is $status, not DRAFT. Use amendNote() to correct a confirmed entry.',
      );
    }

    await PowerSyncService.db.execute(
      '''
      UPDATE htr_transcriptions
      SET edited_final_text = ?, updated_at = ?
      WHERE note_id = ?
      ''',
      [editedText, now, noteId],
    );
  }

  /// Marks a DRAFT note CONFIRMED after clinician verification, freezing it.
  /// Sets both entry_status = 'CONFIRMED' on the note and is_verified = 1 on
  /// its transcription (Section 3.3.7.3.2). After this call the note is
  /// immutable, locally and on the server (see the guard triggers in
  /// supabase/migrations); corrections must go through amendNote().
  static Future<void> confirmNote(String noteId) async {
    final status = await _entryStatus(noteId);
    if (status != 'DRAFT') {
      throw StateError('Note $noteId is already $status.');
    }

    final now = DateTime.now().toUtc().toIso8601String();
    await PowerSyncService.db.writeTransaction((tx) async {
      await tx.execute(
        '''
        UPDATE htr_transcriptions
        SET is_verified = 1, updated_at = ?
        WHERE note_id = ?
        ''',
        [now, noteId],
      );
      await tx.execute(
        '''
        UPDATE clinical_notes
        SET entry_status = 'CONFIRMED', updated_at = ?
        WHERE id = ?
        ''',
        [now, noteId],
      );
    });
  }

  /// Generates a globally unique id on-device, with no network needed.
  static Future<String> newId() async {
    final row = await PowerSyncService.db.get('SELECT uuid() AS id');
    return row['id'] as String;
  }

  /// Makes sure a patient row exists locally before notes reference it.
  /// The insert is synced like any other write, so the server's foreign key
  /// on clinical_notes.patient_id is satisfied when the note arrives.
  static Future<void> ensurePatient({
    required String patientId,
    String? mrn,
    String? firstName,
    String? lastName,
  }) async {
    final existing = await PowerSyncService.db.getOptional(
      'SELECT id FROM patients WHERE id = ?',
      [patientId],
    );
    if (existing != null) return;

    final now = DateTime.now().toUtc().toIso8601String();
    await PowerSyncService.db.execute(
      '''
      INSERT INTO patients (id, mrn, first_name, last_name, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [patientId, mrn, firstName, lastName, now, now],
    );
  }

  /// Corrects a CONFIRMED note by inserting a brand-new note row that points
  /// back to the original via amends_note_id, rather than mutating the
  /// original. This is what keeps the sync conflict-free: two devices can
  /// each amend the same confirmed note offline and both amendments land
  /// (as separate rows) with no last-write-wins collision, and the paper
  /// trail of corrections is preserved for medico-legal review.
  static Future<String> amendNote({
    required String originalNoteId,
    required String patientId,
    required String authorId,
    required String localImagePath,
    required String rawText,
    required String editedText,
    required double meanConfidence,
    required List<Map<String, dynamic>> cnerEntities,
  }) async {
    final status = await _entryStatus(originalNoteId);
    if (status != 'CONFIRMED') {
      throw StateError(
        'Note $originalNoteId is $status. Only CONFIRMED notes are amended; '
        'edit DRAFT notes directly with updateDraftTranscription().',
      );
    }

    final amendmentId =
        'amend_${originalNoteId}_${DateTime.now().microsecondsSinceEpoch}';
    await saveDigitalizedNote(
      noteId: amendmentId,
      patientId: patientId,
      authorId: authorId,
      localImagePath: localImagePath,
      rawText: rawText,
      editedText: editedText,
      meanConfidence: meanConfidence,
      cnerEntities: cnerEntities,
      amendsNoteId: originalNoteId,
    );
    return amendmentId;
  }

  /// Returns the full amendment chain for a note (original + any corrections),
  /// oldest first, for display as a single audit-trailed timeline in the UI.
  static Future<List<Map<String, dynamic>>> getAmendmentChain(
    String rootNoteId,
  ) async {
    return PowerSyncService.db.getAll(
      '''
      WITH RECURSIVE chain(id) AS (
        SELECT id FROM clinical_notes WHERE id = ?
        UNION ALL
        SELECT c.id FROM clinical_notes c
        JOIN chain ON c.amends_note_id = chain.id
      )
      SELECT cn.* FROM clinical_notes cn
      JOIN chain ON cn.id = chain.id
      ORDER BY cn.created_at ASC
      ''',
      [rootNoteId],
    );
  }

  static Future<String> _entryStatus(String noteId) async {
    final rows = await PowerSyncService.db.getAll(
      'SELECT entry_status FROM clinical_notes WHERE id = ?',
      [noteId],
    );
    if (rows.isEmpty) {
      throw StateError('Note $noteId not found');
    }
    return rows.first['entry_status'] as String;
  }

  /// Watch a patient's clinical notes in real time. The stream re-emits on
  /// every local write and every synced download, so the UI never needs a
  /// manual refresh or network call.
  ///
  /// Each row also carries its transcription text and an `is_superseded`
  /// flag (1 when a later amendment points to it): the derived AMENDED state
  /// of Section 3.3.7.3.2.
  static Stream<List<Map<String, dynamic>>> watchPatientNotes(
    String patientId,
  ) {
    return PowerSyncService.db.watch(
      '''
      SELECT cn.*,
             ht.edited_final_text,
             ht.mean_confidence,
             EXISTS (
               SELECT 1 FROM clinical_notes c2 WHERE c2.amends_note_id = cn.id
             ) AS is_superseded
      FROM clinical_notes cn
      LEFT JOIN htr_transcriptions ht ON ht.note_id = cn.id
      WHERE cn.patient_id = ?
      ORDER BY cn.created_at DESC
      ''',
      parameters: [patientId],
    );
  }
}
