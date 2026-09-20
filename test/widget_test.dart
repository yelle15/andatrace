import 'package:flutter_test/flutter_test.dart';
import 'package:andatrace/main.dart';
import 'package:andatrace/processing/preprocessing.dart';
import 'package:andatrace/processing/htr_service.dart';
import 'package:andatrace/processing/cner_service.dart';
import 'package:andatrace/database/local_database_service.dart';

void main() {
  testWidgets('AndaTrace UI Render Test', (WidgetTester tester) async {
    // 1. Build application widget
    await tester.pumpWidget(const AndaTraceApp());
    await tester.pumpAndSettle();

    // 2. Verify UI elements exist
    expect(find.text('AndaTrace: Digitalization Pipeline'), findsOneWidget);
    expect(find.text('Scan & Process Sample Nursing Note (MWE)'), findsOneWidget);
  });

  test('AndaTrace Pipeline Unit Tests', () async {
    // 1. Test Preprocessing
    final preprocessResult = await PreprocessingModule.preprocessImage('test_image.png');
    expect(preprocessResult['status'], equals('success'));
    expect(preprocessResult['isDeskewed'], isTrue);

    // 2. Test HTR Service
    final htrResult = await HtrService.transcribeFdarNote('test_image.png');
    expect(htrResult['focus'], contains('Pain'));
    expect(htrResult.containsKey('data'), isTrue);

    // 3. Test CNER Service
    final entities = await CnerService.extractEntities(htrResult['data']!);
    expect(entities.isNotEmpty, isTrue);

    // 4. Test Local Storage
    final initialRecords = await LocalDatabaseService.getRecords();
    final testRecord = FdarRecord(
      id: 'TEST-001',
      timestamp: DateTime.now(),
      focus: htrResult['focus']!,
      data: htrResult['data']!,
      action: htrResult['action']!,
      response: htrResult['response']!,
    );
    await LocalDatabaseService.saveRecord(testRecord);
    final updatedRecords = await LocalDatabaseService.getRecords();
    expect(updatedRecords.length, equals(initialRecords.length + 1));
  });
}
