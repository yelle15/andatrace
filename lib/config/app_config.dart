/// Build-time configuration for the sync backend (Section 3.3.7).
///
/// Values are injected with `--dart-define-from-file`, so no keys are ever
/// committed to the repository:
///
///   flutter run --dart-define-from-file=config/app_config.json
///
/// Copy `config/app_config.example.json` to `config/app_config.json` (which
/// is git-ignored) and fill in your Supabase and PowerSync details.
///
/// If the values are left empty, the app runs in **local-only mode**: every
/// capture, inference result, and edit is still written to the on-device
/// SQLite database, and nothing is lost. Sync simply never starts. This is
/// the offline-first guarantee: the cloud is optional, the device is not.
class AppConfig {
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');

  /// The Supabase "publishable" (anon) key. Safe to ship in the app; access
  /// is enforced by Row Level Security in supabase/migrations.
  static const String supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  /// Your PowerSync instance URL, e.g. https://<id>.powersync.journeyapps.com
  static const String powersyncUrl = String.fromEnvironment('POWERSYNC_URL');

  /// Private Supabase Storage bucket for captured note images
  /// (Section 3.3.7.3.3). Created by the migration.
  static const String imageBucket = 'note-captures';

  /// Patient used by the MWE screen until a patient picker exists.
  /// Also seeded on the server by the migration.
  static const String demoPatientId = 'demo-patient-001';

  static bool get isSyncConfigured =>
      supabaseUrl.isNotEmpty &&
      supabasePublishableKey.isNotEmpty &&
      powersyncUrl.isNotEmpty;
}
