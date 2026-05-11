import 'package:flutter/material.dart';

import '../ai/native_litert_lm.dart';
import '../ai/openrouter_ai_decision_provider.dart';
import '../ai/openrouter_settings_store.dart';
import '../domain/models.dart';
import '../domain/money.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({required this.onStart, super.key});

  final ValueChanged<TableConfig> onStart;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final TextEditingController _nameController = TextEditingController(
    text: 'Hero',
  );
  final TextEditingController _minBuyInController = TextEditingController(
    text: '40',
  );
  final TextEditingController _maxBuyInController = TextEditingController(
    text: '200',
  );
  final TextEditingController _startingStackController = TextEditingController(
    text: '100',
  );
  final TextEditingController _openRouterModelController =
      TextEditingController(text: OpenRouterConfig.defaultModel);
  final OpenRouterSettingsStore _openRouterSettingsStore =
      const OpenRouterSettingsStore();
  int _seats = 6;
  late AiBackend _aiBackend;
  LiteRtLmStatus? _localGemmaStatus;
  String _openRouterApiKey = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _aiBackend = AiBackend.localGemma;
    _loadOpenRouterSettings();
    NativeLiteRtLm().status().then((LiteRtLmStatus status) {
      if (!mounted) {
        return;
      }
      setState(() => _localGemmaStatus = status);
    });
  }

  Future<void> _loadOpenRouterSettings() async {
    final OpenRouterSettings settings = await _openRouterSettingsStore.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _openRouterApiKey = settings.apiKey;
      _openRouterModelController.text = settings.model;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _minBuyInController.dispose();
    _maxBuyInController.dispose();
    _startingStackController.dispose();
    _openRouterModelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Spacer(),
                    Text(
                      'Poker AI',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: const Color(0xFFE0B85C),
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0,
                          ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Settings',
                      onPressed: _showSettings,
                      icon: const Icon(
                        Icons.settings_outlined,
                        color: Color(0xFFE0B85C),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _SetupSection(
                  title: 'Table Setup',
                  icon: Icons.person,
                  children: <Widget>[
                    const _FieldLabel('Your Name'),
                    TextField(
                      controller: _nameController,
                      decoration: _compactInput(
                        'Your Name',
                        floatingLabelBehavior: FloatingLabelBehavior.never,
                        prefixIcon: const Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const _FieldLabel('Seat Count'),
                    _SeatSelector(
                      value: _seats,
                      onChanged: (int value) => setState(() => _seats = value),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        const Expanded(child: _FieldLabel('Buy-In Range')),
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ],
                    ),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _MoneyInput(
                            controller: _minBuyInController,
                            label: 'Min Buy-In',
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            '-',
                            style: TextStyle(color: Color(0xFF8FA69C)),
                          ),
                        ),
                        Expanded(
                          child: _MoneyInput(
                            controller: _maxBuyInController,
                            label: 'Max Buy-In',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const _FieldLabel('Starting Stack'),
                    _StackStepper(
                      controller: _startingStackController,
                      onChanged: _setStartingStack,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _SetupSection(
                  title: 'AI Backend',
                  icon: Icons.smart_toy_outlined,
                  children: <Widget>[
                    _AiBackendPicker(
                      backend: _aiBackend,
                      hasOpenRouterApiKey:
                          _openRouterApiKey.trim().isNotEmpty ||
                          OpenRouterConfig.hasEnvironmentApiKey,
                      localGemmaStatus: _localGemmaStatus,
                      modelController: _openRouterModelController,
                      onBackendChanged: (AiBackend value) {
                        setState(() => _aiBackend = value);
                      },
                    ),
                  ],
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 88),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: FilledButton.icon(
          onPressed: _start,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE0B85C),
            foregroundColor: const Color(0xFF15120C),
            minimumSize: const Size.fromHeight(50),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start Table'),
        ),
      ),
    );
  }

  void _setStartingStack(num wholeChips) {
    final int min =
        _parseMoney(_minBuyInController.text) ?? Chips.fromWhole(20);
    final int max =
        _parseMoney(_maxBuyInController.text) ?? Chips.fromWhole(500);
    final int next = Chips.fromWhole(wholeChips).clamp(min, max).toInt();
    _startingStackController.text = Chips.format(next);
  }

  void _start() {
    final int? minBuyIn = _parseMoney(_minBuyInController.text);
    final int? maxBuyIn = _parseMoney(_maxBuyInController.text);
    final int? startingStack = _parseMoney(_startingStackController.text);
    if (minBuyIn == null || maxBuyIn == null || startingStack == null) {
      setState(() => _error = 'Enter valid chip amounts.');
      return;
    }
    final TableConfig config = TableConfig(
      humanName: _nameController.text,
      seatCount: _seats,
      minBuyIn: minBuyIn,
      maxBuyIn: maxBuyIn,
      startingStack: startingStack,
      aiBackend: _aiBackend,
      openRouterModel: _openRouterModelController.text.trim(),
      openRouterApiKey: _openRouterApiKey.trim(),
    );
    final String? error = config.validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    if (_aiBackend == AiBackend.openRouter &&
        _openRouterApiKey.trim().isEmpty &&
        !OpenRouterConfig.hasEnvironmentApiKey) {
      setState(() {
        _error = 'Add an OpenRouter API key in Settings before starting.';
      });
      return;
    }
    if (_aiBackend == AiBackend.localGemma &&
        _localGemmaStatus?.available != true) {
      setState(() {
        _error =
            _localGemmaStatus?.reason ??
            'Local Gemma is not available yet. Install the LiteRT-LM runtime and bundled model first.';
      });
      return;
    }
    widget.onStart(config);
  }

  Future<void> _showSettings() async {
    final OpenRouterSettings? settings = await showDialog<OpenRouterSettings>(
      context: context,
      builder: (BuildContext context) => _OpenRouterSettingsDialog(
        initialApiKey: _openRouterApiKey,
        initialModel: _openRouterModelController.text,
      ),
    );
    if (settings == null) {
      return;
    }
    await _openRouterSettingsStore.save(settings);
    if (!mounted) {
      return;
    }
    setState(() {
      _openRouterApiKey = settings.apiKey;
      _openRouterModelController.text = settings.model;
      _error = null;
    });
  }

  int? _parseMoney(String value) {
    final double? parsed = double.tryParse(value.trim().replaceAll(',', ''));
    if (parsed == null || parsed <= 0) {
      return null;
    }
    return Chips.fromWhole(parsed);
  }
}

class _SetupSection extends StatelessWidget {
  const _SetupSection({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _SectionTitle(icon: icon, title: title),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 17, color: const Color(0xFFE0B85C)),
        const SizedBox(width: 8),
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFE7ECE8),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SeatSelector extends StatelessWidget {
  const _SeatSelector({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    const List<int> seats = <int>[2, 3, 4, 6, 9, 10];
    return Row(
      children: seats.map((int seat) {
        final bool selected = seat == value;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: seat == seats.last ? 0 : 8),
            child: OutlinedButton(
              onPressed: () => onChanged(seat),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 36),
                backgroundColor: selected
                    ? const Color(0xFFE0B85C)
                    : const Color(0xFF161F1D),
                foregroundColor: selected
                    ? const Color(0xFF141009)
                    : const Color(0xFFE6EDE8),
                side: BorderSide(
                  color: selected
                      ? const Color(0xFFE0B85C)
                      : const Color(0xFF344741),
                ),
              ),
              child: Text(
                '$seat',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _MoneyInput extends StatelessWidget {
  const _MoneyInput({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: _compactInput(label),
    );
  }
}

class _StackStepper extends StatelessWidget {
  const _StackStepper({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<num> onChanged;

  @override
  Widget build(BuildContext context) {
    final double current =
        double.tryParse(controller.text.trim().replaceAll(',', '')) ?? 100;
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _compactInput('Starting Stack'),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          tooltip: 'Decrease',
          onPressed: () => onChanged(current - 10),
          constraints: const BoxConstraints.tightFor(width: 42, height: 42),
          icon: const Icon(Icons.remove),
        ),
        const SizedBox(width: 6),
        IconButton.filledTonal(
          tooltip: 'Increase',
          onPressed: () => onChanged(current + 10),
          constraints: const BoxConstraints.tightFor(width: 42, height: 42),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

class _AiBackendPicker extends StatelessWidget {
  const _AiBackendPicker({
    required this.backend,
    required this.hasOpenRouterApiKey,
    required this.localGemmaStatus,
    required this.modelController,
    required this.onBackendChanged,
  });

  final AiBackend backend;
  final bool hasOpenRouterApiKey;
  final LiteRtLmStatus? localGemmaStatus;
  final TextEditingController modelController;
  final ValueChanged<AiBackend> onBackendChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SegmentedButton<AiBackend>(
          segments: const <ButtonSegment<AiBackend>>[
            ButtonSegment<AiBackend>(
              value: AiBackend.localGemma,
              icon: Icon(Icons.memory),
              label: Text('Gemma'),
            ),
            ButtonSegment<AiBackend>(
              value: AiBackend.openRouter,
              icon: Icon(Icons.cloud_outlined),
              label: Text('Router'),
            ),
            ButtonSegment<AiBackend>(
              value: AiBackend.testBot,
              icon: Icon(Icons.smart_toy_outlined),
              label: Text('Bot'),
            ),
          ],
          showSelectedIcon: false,
          selected: <AiBackend>{backend},
          onSelectionChanged: (Set<AiBackend> selected) =>
              onBackendChanged(selected.first),
        ),
        const SizedBox(height: 12),
        if (backend == AiBackend.localGemma) ...<Widget>[
          _BackendStatusLine(
            icon: localGemmaStatus?.available == true
                ? Icons.memory
                : Icons.warning_amber,
            color: localGemmaStatus?.available == true
                ? const Color(0xFFE0B85C)
                : Theme.of(context).colorScheme.error,
            text: localGemmaStatus == null
                ? 'Checking LiteRT-LM runtime...'
                : localGemmaStatus!.available
                ? 'Gemma 4 E2B mobile runtime ready'
                : 'LiteRT-LM C++ not linked',
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: 'Gemma 4 E2B Instruct (Q4_K_M)',
            isExpanded: true,
            decoration: _compactInput(
              'Model',
              prefixIcon: const Icon(Icons.auto_awesome),
            ),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: 'Gemma 4 E2B Instruct (Q4_K_M)',
                child: Text(
                  'Gemma 4 E2B Instruct Q4',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            onChanged: (_) {},
          ),
        ],
        if (backend == AiBackend.openRouter) ...<Widget>[
          DropdownButtonFormField<String>(
            initialValue:
                OpenRouterConfig.modelPresets.contains(modelController.text)
                ? modelController.text
                : OpenRouterConfig.modelPresets.first,
            isExpanded: true,
            decoration: _compactInput(
              'Model preset',
              prefixIcon: const Icon(Icons.auto_awesome),
            ),
            items: OpenRouterConfig.modelPresets.map((String model) {
              return DropdownMenuItem<String>(
                value: model,
                child: Text(model, overflow: TextOverflow.ellipsis),
              );
            }).toList(),
            onChanged: (String? value) {
              if (value != null) {
                modelController.text = value;
              }
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: modelController,
            decoration: _compactInput(
              'OpenRouter model id',
              prefixIcon: const Icon(Icons.edit_outlined),
            ),
          ),
          const SizedBox(height: 8),
          _BackendStatusLine(
            icon: hasOpenRouterApiKey ? Icons.key : Icons.key_off,
            color: hasOpenRouterApiKey
                ? const Color(0xFFE0B85C)
                : Theme.of(context).colorScheme.error,
            text: hasOpenRouterApiKey
                ? 'OpenRouter API key ready'
                : 'Add an API key from Settings',
          ),
        ],
        if (backend == AiBackend.testBot)
          const _BackendStatusLine(
            icon: Icons.science_outlined,
            color: Color(0xFFE0B85C),
            text: 'Deterministic test bot. No LLM calls.',
          ),
      ],
    );
  }
}

class _BackendStatusLine extends StatelessWidget {
  const _BackendStatusLine({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontSize: 11, height: 1.1),
          ),
        ),
      ],
    );
  }
}

InputDecoration _compactInput(
  String label, {
  Widget? prefixIcon,
  FloatingLabelBehavior? floatingLabelBehavior,
}) {
  return InputDecoration(
    labelText: label,
    prefixIcon: prefixIcon,
    floatingLabelBehavior: floatingLabelBehavior,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );
}

class _OpenRouterSettingsDialog extends StatefulWidget {
  const _OpenRouterSettingsDialog({
    required this.initialApiKey,
    required this.initialModel,
  });

  final String initialApiKey;
  final String initialModel;

  @override
  State<_OpenRouterSettingsDialog> createState() =>
      _OpenRouterSettingsDialogState();
}

class _OpenRouterSettingsDialogState extends State<_OpenRouterSettingsDialog> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: widget.initialApiKey);
    _modelController = TextEditingController(
      text: widget.initialModel.trim().isEmpty
          ? OpenRouterConfig.defaultModel
          : widget.initialModel,
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('OpenRouter Settings'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _apiKeyController,
              obscureText: _obscureKey,
              decoration:
                  _compactInput(
                    'API key',
                    prefixIcon: const Icon(Icons.key_outlined),
                  ).copyWith(
                    suffixIcon: IconButton(
                      tooltip: _obscureKey ? 'Show key' : 'Hide key',
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                      icon: Icon(
                        _obscureKey
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue:
                  OpenRouterConfig.modelPresets.contains(_modelController.text)
                  ? _modelController.text
                  : OpenRouterConfig.defaultModel,
              isExpanded: true,
              decoration: _compactInput(
                'Model preset',
                prefixIcon: const Icon(Icons.auto_awesome),
              ),
              items: OpenRouterConfig.modelPresets.map((String model) {
                return DropdownMenuItem<String>(
                  value: model,
                  child: Text(model, overflow: TextOverflow.ellipsis),
                );
              }).toList(),
              onChanged: (String? value) {
                if (value != null) {
                  _modelController.text = value;
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelController,
              decoration: _compactInput(
                'OpenRouter model id',
                prefixIcon: const Icon(Icons.edit_outlined),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              OpenRouterSettings(
                apiKey: _apiKeyController.text,
                model: _modelController.text,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
