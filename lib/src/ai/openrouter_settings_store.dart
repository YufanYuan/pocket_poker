import 'package:shared_preferences/shared_preferences.dart';

import 'openrouter_ai_decision_provider.dart';

class OpenRouterSettings {
  const OpenRouterSettings({required this.apiKey, required this.model});

  final String apiKey;
  final String model;
}

class OpenRouterSettingsStore {
  const OpenRouterSettingsStore();

  static const String _apiKeyKey = 'openrouter.apiKey';
  static const String _modelKey = 'openrouter.model';

  Future<OpenRouterSettings> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String storedModel = prefs.getString(_modelKey) ?? '';
    return OpenRouterSettings(
      apiKey: prefs.getString(_apiKeyKey) ?? '',
      model: storedModel.trim().isEmpty
          ? OpenRouterConfig.defaultModel
          : storedModel,
    );
  }

  Future<void> save(OpenRouterSettings settings) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiKeyKey, settings.apiKey.trim());
    await prefs.setString(_modelKey, settings.model.trim());
  }
}
