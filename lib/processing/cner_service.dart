class ClinicalEntity {
  final String text;
  final String category;

  const ClinicalEntity({required this.text, required this.category});
}

/// Simulated BioBERT Clinical Named Entity Recognition (CNER)
class CnerService {
  static Future<List<ClinicalEntity>> extractEntities(String clinicalText) async {
    await Future.delayed(const Duration(milliseconds: 300));
    
    return const [
      ClinicalEntity(text: 'Abdominal pain', category: 'Symptom'),
      ClinicalEntity(text: '8/10', category: 'Pain Score'),
      ClinicalEntity(text: '120/80', category: 'Vital Sign (BP)'),
      ClinicalEntity(text: '88 bpm', category: 'Vital Sign (HR)'),
      ClinicalEntity(text: 'Analgesics IV', category: 'Medication'),
    ];
  }
}
