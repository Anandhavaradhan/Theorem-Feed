/// Backend base URL. Override at build time:
///   flutter run --dart-define=TF_API_BASE=http://192.168.1.20:8000
/// Default targets the host machine from the Android emulator.
const String apiBase = String.fromEnvironment('TF_API_BASE', defaultValue: 'http://10.0.2.2:8000');
