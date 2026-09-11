import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../auth/presentation/auth_controller.dart';
import '../../../cloud_mail/probe/cloud_hash.dart';
import '../../download/domain/download_cancellation.dart';
import '../application/editor_save_repository.dart';

final class EditorPage extends StatefulWidget {
  const EditorPage({
    required this.preparedFile,
    required this.editorSaveService,
    this.authController,
    this.onSaved,
    super.key,
  });

  final PreparedEditorFile preparedFile;
  final EditorSaveService editorSaveService;
  final AuthController? authController;
  final Future<void> Function(EditorSaveResult result)? onSaved;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

final class _EditorPageState extends State<EditorPage> {
  late final TextEditingController _textController;
  late EditorSaveBaseline _baseline;
  late List<int> _baselineBytes;
  late List<int> _encodedBytes;
  late bool _hasUtf8Bom;

  EditorSaveCancellation? _saveCancellation;
  EditorSaveResult? _lastSaveResult;
  String? _progressMessage;
  String? _inlineMessage;
  bool _isSaving = false;
  bool _backDialogShowing = false;
  bool _forceClosing = false;

  bool get _isDirty => !listEquals(_encodedBytes, _baselineBytes);

  bool get _isOversize => _encodedBytes.length > editorMaxBytes;

  bool get _canSave => _isDirty && !_isSaving && !_isOversize;

  @override
  void initState() {
    super.initState();
    _baseline = widget.preparedFile.baseline;
    _baselineBytes = List<int>.unmodifiable(widget.preparedFile.bytes);
    _hasUtf8Bom = widget.preparedFile.hasUtf8Bom;
    _encodedBytes = _baselineBytes;
    _textController = TextEditingController(text: widget.preparedFile.text)
      ..addListener(_onTextChanged);
    widget.authController?.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.authController?.removeListener(_onAuthChanged);
    final cancellation = _saveCancellation;
    cancellation?.cancel();
    unawaited(cancellation?.close());
    _textController
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted || widget.authController?.status != AuthStatus.signedOut) {
      return;
    }
    setState(() => _forceClosing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    });
  }

  void _onTextChanged() {
    final wasOversize = _isOversize;
    final next = List<int>.unmodifiable(
      encodeEditorUtf8(_textController.text, hasUtf8Bom: _hasUtf8Bom),
    );
    if (listEquals(next, _encodedBytes)) {
      return;
    }
    setState(() {
      _encodedBytes = next;
      if (_isOversize) {
        _inlineMessage = _oversizeMessage(next.length);
      } else if (wasOversize) {
        _inlineMessage = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _basename(_baseline.path);
    return PopScope<void>(
      canPop: _forceClosing || (!_isDirty && !_isSaving),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _forceClosing) return;
        if (_isSaving) {
          _showMessage('Сохранение ещё выполняется.');
        } else {
          unawaited(_requestPop());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Назад',
            onPressed: _isSaving ? null : () => unawaited(_requestPop()),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_isDirty) ...[
                const SizedBox(width: 8),
                Semantics(
                  label: 'Есть несохранённые изменения',
                  child: Text(
                    '●',
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (_isSaving)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            IconButton(
              tooltip: 'Сохранить',
              onPressed: _canSave ? _save : null,
              icon: const Icon(Icons.save_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_isSaving && _progressMessage != null)
                _EditorProgress(message: _progressMessage!),
              if (_inlineMessage != null)
                _EditorInlineMessage(message: _inlineMessage!),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: TextField(
                    controller: _textController,
                    readOnly: _isSaving,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                    keyboardType: TextInputType.multiline,
                    smartDashesType: SmartDashesType.disabled,
                    smartQuotesType: SmartQuotesType.disabled,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: ['monospace'],
                      height: 1.45,
                      fontSize: 14,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Начните вводить текст',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: EdgeInsets.all(8),
                    ),
                    scrollPhysics: const ClampingScrollPhysics(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_canSave) {
      if (_isOversize) {
        setState(() => _inlineMessage = _oversizeMessage(_encodedBytes.length));
      }
      return;
    }
    await _saveWithChoice(EditorSaveChoice.unchanged);
  }

  Future<void> _saveWithChoice(EditorSaveChoice choice) async {
    if (!mounted || _isSaving || _isOversize || !_isDirty) return;
    final token = DownloadCancellationToken();
    _saveCancellation = token;
    setState(() {
      _isSaving = true;
      _inlineMessage = null;
      _progressMessage = _editorSavePhaseLabel(
        EditorSavePhase.checkingConflict,
      );
    });

    try {
      final result = await widget.editorSaveService.save(
        _baseline,
        List<int>.from(_encodedBytes),
        choice: choice,
        cancellation: token,
        onProgress: (progress) {
          if (!mounted || !identical(_saveCancellation, token)) return;
          setState(
            () => _progressMessage = _editorSavePhaseLabel(progress.phase),
          );
        },
      );
      if (!mounted || !identical(_saveCancellation, token)) return;
      await _applySuccessfulSave(result);
    } on EditorSaveFailure catch (failure) {
      if (!mounted || !identical(_saveCancellation, token)) return;
      if (failure.isConflict) {
        _finishSaving(token);
        final selected = await _showConflictDialog();
        if (selected != null && mounted) await _saveWithChoice(selected);
        return;
      }
      _showFailure(failure);
    } catch (_) {
      if (mounted && identical(_saveCancellation, token)) {
        _showFailure(
          const EditorSaveFailure(
            EditorSaveFailureType.service,
            'Не удалось выполнить сохранение.',
          ),
        );
      }
    } finally {
      _finishSaving(token);
    }
  }

  Future<void> _applySuccessfulSave(EditorSaveResult result) async {
    final bytes = List<int>.unmodifiable(_encodedBytes);
    final remote = result.remoteNode;
    final hash = remote.hash ?? calculateCloudHash(bytes);
    final size = remote.size ?? bytes.length;
    _baseline = EditorSaveBaseline(
      path: remote.path,
      hash: hash,
      size: size,
      modifiedAt: remote.modifiedAt,
      revision: remote.revision,
      globalRevision: remote.globalRevision,
    );
    _baselineBytes = bytes;
    _lastSaveResult = result;
    if (mounted) {
      setState(() {
        _encodedBytes = bytes;
        _inlineMessage = result.isPartialSuccess
            ? 'Файл сохранён в облаке, но локальная офлайн-связь не обновлена.'
            : null;
        _progressMessage = null;
      });
    }
    final onSaved = widget.onSaved;
    if (onSaved != null) {
      try {
        await onSaved(result);
      } catch (_) {
        // A listing refresh must not turn a verified cloud save into a false
        // editor failure.
      }
    }
  }

  void _finishSaving(EditorSaveCancellation token) {
    if (!identical(_saveCancellation, token)) return;
    _saveCancellation = null;
    if (!mounted) return;
    setState(() {
      _isSaving = false;
      _progressMessage = null;
    });
    unawaited(token.close());
  }

  Future<EditorSaveChoice?> _showConflictDialog() {
    return showDialog<EditorSaveChoice>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Удалённый файл изменился'),
        content: const Text(
          'Файл в облаке изменился после открытия. Выберите, как сохранить текущий текст.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(EditorSaveChoice.overwrite),
            child: const Text('Поверх'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(EditorSaveChoice.copy),
            child: const Text('Копия'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
        ],
      ),
    );
  }

  void _showFailure(EditorSaveFailure failure) {
    final message = _safeFailureMessage(failure);
    if (!mounted) return;
    setState(() {
      _inlineMessage =
          failure.type == EditorSaveFailureType.invalidRequest && _isOversize
          ? _oversizeMessage(_encodedBytes.length)
          : null;
      _progressMessage = null;
    });
    _showMessage(message);
  }

  Future<void> _requestPop() async {
    if (!mounted || _backDialogShowing) return;
    if (_isSaving) {
      _showMessage('Сохранение ещё выполняется.');
      return;
    }
    if (!_isDirty) {
      Navigator.of(context).pop(_lastSaveResult);
      return;
    }
    _backDialogShowing = true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Есть несохранённые изменения'),
        content: const Text('Выйти без сохранения текущего текста?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Не сохранять'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Остаться'),
          ),
        ],
      ),
    );
    _backDialogShowing = false;
    if (leave == true && mounted) Navigator.of(context).pop(_lastSaveResult);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

final class _EditorProgress extends StatelessWidget {
  const _EditorProgress({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(message, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          const SizedBox(width: 64, child: LinearProgressIndicator()),
        ],
      ),
    ),
  );
}

final class _EditorInlineMessage extends StatelessWidget {
  const _EditorInlineMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    color: Theme.of(context).colorScheme.errorContainer,
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
    ),
  );
}

String _basename(String path) {
  final separator = path.lastIndexOf('/');
  return separator < 0 ? path : path.substring(separator + 1);
}

String _oversizeMessage(int bytes) =>
    'Размер текста: $bytes байт. Лимит встроенного редактора — $editorMaxBytes байт (10 МиБ).';

String _editorSavePhaseLabel(EditorSavePhase phase) => switch (phase) {
  EditorSavePhase.checkingConflict => 'Проверка изменений в облаке…',
  EditorSavePhase.hashing => 'Проверка содержимого…',
  EditorSavePhase.preparingCache => 'Подготовка содержимого…',
  EditorSavePhase.resolvingShard => 'Подготовка сохранения…',
  EditorSavePhase.uploading => 'Загрузка в облако…',
  EditorSavePhase.registering => 'Регистрация файла…',
  EditorSavePhase.verifyingRemote => 'Проверка сохранённого файла…',
  EditorSavePhase.committingOwnership => 'Обновление офлайн-связи…',
  EditorSavePhase.completed => 'Сохранено',
};

String _safeFailureMessage(EditorSaveFailure failure) => switch (failure.type) {
  EditorSaveFailureType.invalidRequest => 'Содержимое не удалось сохранить.',
  EditorSaveFailureType.cancelled => 'Сохранение отменено.',
  EditorSaveFailureType.authRequired => 'Требуется вход в Mail.ru.',
  EditorSaveFailureType.network => 'Нет соединения с Mail.ru.',
  EditorSaveFailureType.timeout => 'Mail.ru не ответил вовремя.',
  EditorSaveFailureType.notFound => 'Удалённый файл недоступен.',
  EditorSaveFailureType.permissionDenied => 'Mail.ru не разрешил сохранение.',
  EditorSaveFailureType.conflict => 'Удалённый файл изменился.',
  EditorSaveFailureType.integrity => 'Проверка сохранения не пройдена.',
  EditorSaveFailureType.invalidResponse => 'Mail.ru вернул неизвестный ответ.',
  EditorSaveFailureType.service => 'Mail.ru временно недоступен.',
  EditorSaveFailureType.disk => 'Не удалось обновить локальный кэш.',
  EditorSaveFailureType.partialSuccess =>
    'Файл сохранён в облаке, но локальная офлайн-связь не обновлена.',
  EditorSaveFailureType.remoteOutcomeUnknown =>
    'Результат сохранения не удалось подтвердить. Повтор не выполнялся; проверьте файл в облаке.',
};
