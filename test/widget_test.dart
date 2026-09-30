import 'package:flutter_test/flutter_test.dart';
import 'package:andatrace/config/app_config.dart';
import 'package:andatrace/processing/preprocessing.dart';
import 'package:andatrace/processing/htr_service.dart';
import 'package:andatrace/processing/cner_service.dart';

// These tests cover the on-device processing pipeline interfaces, which run
// without a database or network.
//
// The storage and sync layer (LocalDatabaseService, PowerSync) needs the
// native PowerSync SQLite extension, so it is exercised on a device or
// emulator with `flutter run`, not in this host-side `flutter test` run.

void main() {
  test('Backend is optional: app defaults to local-only mode', () {
    // With no --dart-define values, sync is not configured and the app must
    // still start and store everything locally (offline-first).
    expect(AppConfig.isSyncConfigured, isFalse);
  });

  test('AndaTrace pipeline interfaces (mock models)', () async {
    // 1. Preprocessing
    final preprocessResult = await PreprocessingModule.preprocessImage(
      'test_image.png',
    );
    expect(preprocessResult['status'], equals('success'));
    expect(preprocessResult['isDeskewed'], isTrue);

    // 2. HTR returns all four FDAR sections
    final htrResult = await HtrService.transcribeFdarNote('test_image.png');
    for (final key in ['focus', 'data', 'action', 'response']) {
      expect(htrResult.containsKey(key), isTrue, reason: 'missing $key');
    }
    expect(htrResult['focus'], contains('Pain'));

    // 3. CNER extracts entities from the transcribed text
    final entities = await CnerService.extractEntities(htrResult['data']!);
    expect(entities, isNotEmpty);
    expect(entities.every((e) => e.text.isNotEmpty && e.category.isNotEmpty),
        isTrue);
  });
}
