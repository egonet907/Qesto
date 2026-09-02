import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/formatters/qesto_formatters.dart';
import '../../core/platform/qesto_command_line.dart';
import '../../core/theme/qesto_theme.dart';
import '../../core/platform/external_url_launcher.dart';
import '../../data/models/qesto_models.dart';
import '../../features/bank_browser/config/bank_connector_registry.dart';
import '../../features/bank_browser/data/browser_profile_manager.dart';
import '../../features/bank_browser/domain/bank_browser_models.dart';
import '../../features/bank_browser/runtime/browser_controller.dart';
import '../../features/bank_browser/dev/dev_browser_bridge.dart';
import '../../features/bank_browser/sber/sber_auth_manager.dart';
import '../../features/bank_browser/sber/sber_connector.dart';
import '../../features/bank_browser/sber/sber_connector_models.dart';
import '../../features/budget/state/budget_controller.dart';
import '../../features/budget/services/cash_flow_calculation_service.dart';
import '../widgets/desktop_components.dart';

class DesktopBankConnectionsPage extends StatefulWidget {
  const DesktopBankConnectionsPage({
    super.key,
    this.profileManager,
    this.controller,
  });

  final BrowserProfileManager? profileManager;
  final BudgetController? controller;

  @override
  State<DesktopBankConnectionsPage> createState() =>
      _DesktopBankConnectionsPageState();
}

class _DesktopBankConnectionsPageState
    extends State<DesktopBankConnectionsPage> {
  late final BrowserProfileManager _profiles =
      widget.profileManager ?? BrowserProfileManager();
  List<BankProfile> _items = const [];
  var _loading = true;
  var _busy = false;
  var _sberPinStored = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _reload();
    if (hasQestoCommandLineArgument('--qesto-bank-browser-open-sber')) {
      await _addSber();
    }
    if (hasQestoCommandLineArgument('--qesto-bank-browser-dev')) {
      for (final profile in _items) {
        if (profile.bankId == 'sber' && mounted) {
          await _openDev(profile, confirm: false);
          break;
        }
      }
    }
  }

  Future<void> _reload() async {
    final values = await _profiles.listProfiles();
    String? pin;
    try {
      pin = await const SberPinVault().read();
    } on MissingPluginException {
      // Secure storage is provided by the Windows host; widget tests and
      // unsupported hosts simply render the PIN as not configured.
    }
    if (!mounted) return;
    setState(() {
      _items = values;
      _loading = false;
      _sberPinStored = pin?.isNotEmpty == true;
    });
  }

  Future<void> _addSber() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final profile = await _profiles.createProfile(BankConnectorRegistry.sber);
      if (!mounted) return;
      await _open(profile);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  Future<void> _open(BankProfile profile) async {
    final config = BankConnectorRegistry.byId(profile.bankId);
    if (config == null || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BankBrowserPage(
          profile: profile,
          bank: config,
          profileManager: _profiles,
          budgetController: widget.controller,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _syncProfile(BankProfile profile) async {
    final config = BankConnectorRegistry.byId(profile.bankId);
    if (config == null || !mounted || _busy) return;
    final range = profile.bankId == 'sber'
        ? await _showSberSyncRangeDialog(context)
        : null;
    if (profile.bankId == 'sber' && range == null) return;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BankBrowserPage(
          profile: profile,
          bank: config,
          profileManager: _profiles,
          budgetController: widget.controller,
          autoSyncOnOpen: profile.bankId == 'sber',
          initialSyncRange: range,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _openDev(BankProfile profile, {bool confirm = true}) async {
    final config = BankConnectorRegistry.byId(profile.bankId);
    if (config == null || !mounted || _busy) return;
    if (confirm) {
      final enabled = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Режим разработки'),
          content: const Text(
            'Локальные инструменты смогут читать содержимое открытого банковского профиля, DOM и отображаемые финансовые данные для разработки коннектора.\n\n'
            'Финансовые действия через Dev Inspector блокируются. Сессия работает только на этом компьютере и завершается при закрытии браузера.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Включить'),
            ),
          ],
        ),
      );
      if (enabled != true || !mounted) return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BankBrowserPage(
          profile: profile,
          bank: config,
          profileManager: _profiles,
          budgetController: widget.controller,
          devMode: true,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _saveSberPin() async {
    final input = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('PIN быстрого входа Сбера'),
        content: TextField(
          controller: input,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          decoration: const InputDecoration(
            hintText: '4–8 цифр',
            helperText: 'Хранится только в защищённом хранилище Windows',
          ),
        ),
        actions: [
          if (_sberPinStored)
            TextButton(
              onPressed: () => Navigator.pop(context, '__delete__'),
              child: const Text('Удалить PIN'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    input.dispose();
    if (pin == null || pin.isEmpty) return;
    if (pin == '__delete__') {
      await const SberPinVault().delete();
      if (mounted) {
        setState(() => _sberPinStored = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN удалён с этого компьютера.')),
        );
      }
      return;
    }
    try {
      await const SberPinVault().write(pin);
      if (mounted) {
        setState(() => _sberPinStored = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN сохранён на этом компьютере.')),
        );
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _delete(BankProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Отключить банк?'),
        content: const Text(
          'Локальная сессия, cookie и все данные сайта в этом профиле будут полностью удалены. Финансовые данные Qesto не изменятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: QestoColors.negative,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить профиль'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _profiles.deleteProfile(profile.id);
      if (profile.bankId == 'sber') {
        // The PIN belongs to this device connection, not to the financial
        // history. Remove it together with the CEF profile on disconnect.
        await const SberPinVault().delete();
        _sberPinStored = false;
      }
      await _reload();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось удалить профиль. Закройте окно банка и попробуйте снова.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(26, 24, 26, 34),
      children: [
        DesktopSectionHeader(
          title: 'Подключения к банкам',
          subtitle:
              'Защищённый браузер хранит сессию только на этом компьютере. Qesto не видит логин, пароль или код подтверждения.',
          trailing: FilledButton.icon(
            key: const Key('bank-browser-add-sber'),
            onPressed: _busy ? null : _addSber,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Добавить банк'),
          ),
        ),
        const SizedBox(height: 18),
        DesktopCard(
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F8EE),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.account_balance_rounded,
                  color: Color(0xFF16A05D),
                  size: 27,
                ),
              ),
              const SizedBox(width: 15),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'СберБанк Онлайн',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Официальный сайт · отдельный профиль CEF/Chromium · HTTPS',
                      style: TextStyle(
                        color: QestoColors.secondaryText,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _addSber,
                icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                label: const Text('Подключить через веб-банк'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const DesktopSectionHeader(
          title: 'Локальные профили',
          subtitle:
              'Закрытие браузера не завершает банковскую сессию. Для полного выхода удалите профиль.',
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(34),
              child: CircularProgressIndicator(),
            ),
          )
        else if (_items.isEmpty)
          const DesktopEmptyState(
            title: 'Банки пока не подключены',
            message:
                'Создайте локальный профиль и войдите на официальном сайте банка.',
            icon: Icons.lock_outline_rounded,
          )
        else
          for (final profile in _items) ...[
            _BankProfileCard(
              profile: profile,
              onOpen: () => _open(profile),
              onSync: profile.bankId == 'sber'
                  ? () => _syncProfile(profile)
                  : null,
              onDev: profile.bankId == 'sber' ? () => _openDev(profile) : null,
              onSavePin: profile.bankId == 'sber' ? _saveSberPin : null,
              pinStored: profile.bankId == 'sber' && _sberPinStored,
              onDelete: _busy ? null : () => _delete(profile),
            ),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 18),
        DesktopCard(
          color: QestoColors.primarySoft,
          borderColor: QestoColors.primary.withValues(alpha: 0.18),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_outlined, color: QestoColors.primary),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Для СберБанка доступен локальный read-only коннектор: он читает только видимые страницы счетов и истории, не перехватывает запросы и не отправляет банковские данные в облако. Платежи, переводы и подтверждения операций заблокированы.',
                  style: TextStyle(fontSize: 11, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _SberPeriodChoice {
  currentMonth,
  last7Days,
  last30Days,
  last90Days,
  custom,
}

Future<SberSyncRange?> _showSberSyncRangeDialog(BuildContext context) async {
  var choice = _SberPeriodChoice.currentMonth;
  DateTimeRange? custom;
  final now = DateTime.now();
  return showDialog<SberSyncRange>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Период синхронизации'),
        content: SizedBox(
          width: 430,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Qesto загрузит операции только за выбранный период и остановит прокрутку, когда достигнет его начала.',
              ),
              const SizedBox(height: 14),
              for (final item in _SberPeriodChoice.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    choice == item
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: choice == item
                        ? QestoColors.primary
                        : QestoColors.secondaryText,
                  ),
                  title: Text(_sberPeriodChoiceLabel(item)),
                  subtitle: item == _SberPeriodChoice.custom && custom != null
                      ? Text(
                          '${_sberShortDate(custom!.start)}—${_sberShortDate(custom!.end)}',
                        )
                      : null,
                  onTap: () async {
                    if (item != _SberPeriodChoice.custom) {
                      setDialogState(() => choice = item);
                      return;
                    }
                    final selected = await showDateRangePicker(
                      context: dialogContext,
                      firstDate: DateTime(now.year - 5),
                      lastDate: now,
                      initialDateRange:
                          custom ??
                          DateTimeRange(
                            start: DateTime(now.year, now.month),
                            end: now,
                          ),
                      helpText: 'Выберите период операций Сбера',
                      cancelText: 'Отмена',
                      confirmText: 'Выбрать',
                    );
                    if (selected != null) {
                      setDialogState(() {
                        choice = item;
                        custom = selected;
                      });
                    }
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: choice == _SberPeriodChoice.custom && custom == null
                ? null
                : () => Navigator.pop(
                    dialogContext,
                    _sberRangeFor(choice, now: now, custom: custom),
                  ),
            child: const Text('Начать синхронизацию'),
          ),
        ],
      ),
    ),
  );
}

String _sberPeriodChoiceLabel(_SberPeriodChoice value) => switch (value) {
  _SberPeriodChoice.currentMonth => 'Текущий месяц',
  _SberPeriodChoice.last7Days => 'Последние 7 дней',
  _SberPeriodChoice.last30Days => 'Последние 30 дней',
  _SberPeriodChoice.last90Days => 'Последние 90 дней',
  _SberPeriodChoice.custom => 'Выбрать даты',
};

SberSyncRange _sberRangeFor(
  _SberPeriodChoice value, {
  required DateTime now,
  DateTimeRange? custom,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final toExclusive = today.add(const Duration(days: 1));
  return switch (value) {
    _SberPeriodChoice.currentMonth => SberSyncRange(
      from: DateTime(now.year, now.month),
      toExclusive: toExclusive,
      label: 'Текущий месяц',
    ),
    _SberPeriodChoice.last7Days => SberSyncRange(
      from: today.subtract(const Duration(days: 6)),
      toExclusive: toExclusive,
      label: 'Последние 7 дней',
    ),
    _SberPeriodChoice.last30Days => SberSyncRange(
      from: today.subtract(const Duration(days: 29)),
      toExclusive: toExclusive,
      label: 'Последние 30 дней',
    ),
    _SberPeriodChoice.last90Days => SberSyncRange(
      from: today.subtract(const Duration(days: 89)),
      toExclusive: toExclusive,
      label: 'Последние 90 дней',
    ),
    _SberPeriodChoice.custom => SberSyncRange(
      from: DateTime(custom!.start.year, custom.start.month, custom.start.day),
      toExclusive: DateTime(
        custom.end.year,
        custom.end.month,
        custom.end.day + 1,
      ),
      label: 'Выбранные даты',
    ),
  };
}

String _formatProfileDate(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}, ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

String _sberShortDate(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}';

class _BankProfileCard extends StatelessWidget {
  const _BankProfileCard({
    required this.profile,
    required this.onOpen,
    required this.onDelete,
    this.onSync,
    this.onSavePin,
    this.onDev,
    this.pinStored = false,
  });

  final BankProfile profile;
  final VoidCallback onOpen;
  final VoidCallback? onDelete;
  final VoidCallback? onSync;
  final VoidCallback? onSavePin;
  final VoidCallback? onDev;
  final bool pinStored;

  @override
  Widget build(BuildContext context) {
    final date = profile.lastOpenedAt;
    final opened =
        '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
    return DesktopCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: [
          const Icon(Icons.lock_rounded, color: Color(0xFF16A05D), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.displayName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Последний вход: $opened · данные только на устройстве',
                  style: const TextStyle(
                    color: QestoColors.secondaryText,
                    fontSize: 10,
                  ),
                ),
                if (profile.lastSyncAt != null)
                  Text(
                    'Последняя синхронизация: ${_formatProfileDate(profile.lastSyncAt!)}',
                    style: const TextStyle(
                      color: QestoColors.secondaryText,
                      fontSize: 10,
                    ),
                  ),
                if (profile.bankId == 'sber')
                  Text(
                    'PIN быстрого входа: ${pinStored ? 'сохранён' : 'не сохранён'}',
                    style: const TextStyle(
                      color: QestoColors.secondaryText,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.login_rounded, size: 17),
            label: const Text('Открыть'),
          ),
          if (onSavePin != null)
            IconButton(
              tooltip: 'Сохранить или изменить PIN Сбера',
              onPressed: onSavePin,
              icon: const Icon(Icons.password_rounded, size: 18),
            ),
          if (onSync != null)
            FilledButton.icon(
              onPressed: onSync,
              icon: const Icon(Icons.sync_rounded, size: 17),
              label: const Text('Синхронизировать'),
            ),
          if (onDev != null)
            IconButton(
              tooltip: 'Открыть локальный DEV Inspector',
              onPressed: onDev,
              icon: const Icon(Icons.developer_mode_rounded, size: 18),
            ),
          IconButton(
            tooltip: 'Отключить и удалить локальную сессию',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded, size: 19),
          ),
        ],
      ),
    );
  }
}

class BankBrowserPage extends StatefulWidget {
  const BankBrowserPage({
    required this.profile,
    required this.bank,
    required this.profileManager,
    this.budgetController,
    this.autoSyncOnOpen = false,
    this.devMode = false,
    this.initialSyncRange,
    super.key,
  });

  final BankProfile profile;
  final BankConnectorConfig bank;
  final BrowserProfileManager profileManager;
  final BudgetController? budgetController;
  final bool autoSyncOnOpen;
  final bool devMode;
  final SberSyncRange? initialSyncRange;

  @override
  State<BankBrowserPage> createState() => _BankBrowserPageState();
}

class _BankBrowserPageState extends State<BankBrowserPage> {
  late final BrowserController _controller = BrowserController(
    profile: widget.profile,
    bank: widget.bank,
    profileManager: widget.profileManager,
    onNotice: _showNotice,
  );
  late final SberConnector? _sberConnector = widget.bank.bankId == 'sber'
      ? SberConnector(browser: _controller)
      : null;
  StreamSubscription<SberSyncReport>? _sberSubscription;
  SberSyncReport? _sberReport;
  var _syncing = false;
  var _closing = false;

  @override
  void initState() {
    super.initState();
    final connector = _sberConnector;
    if (connector != null) {
      _sberSubscription = connector.listen((report) {
        if (mounted) setState(() => _sberReport = report);
      });
    }
    unawaited(_openAndMaybeSync());
  }

  Future<void> _openAndMaybeSync() async {
    await _controller.open();
    if (widget.devMode && _controller.isRuntimeReady) {
      await DevBrowserBridge.instance.start(
        browser: _controller,
        bank: widget.bank,
      );
    }
    if (!widget.autoSyncOnOpen || !mounted || !_controller.isRuntimeReady) {
      return;
    }
    try {
      await _controller
          .waitForLoadState(BankBrowserLoadState.finished)
          .timeout(const Duration(seconds: 20));
    } on Object {
      // Sync still produces an explicit auth/parser result if loading is
      // interrupted; it must never appear to do nothing.
    }
    if (mounted) {
      await _syncSber(
        requestedRange: widget.initialSyncRange,
        askForPeriod: false,
      );
    }
  }

  void _showNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    await _controller.stop();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (widget.devMode) await DevBrowserBridge.instance.stop();
    await _controller.disposeEnvironment();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _syncSber({
    SberSyncRange? requestedRange,
    bool askForPeriod = true,
  }) async {
    final connector = _sberConnector;
    if (connector == null || _syncing) return;
    var range = requestedRange;
    if (range == null && askForPeriod) {
      range = await _showSberSyncRangeDialog(context);
      if (range == null) return;
    }
    range ??= SberSyncRange.currentMonth();
    if (!mounted) return;
    setState(() => _syncing = true);
    try {
      final report = await connector.sync(range: range);
      final snapshot = report.snapshot;
      if (snapshot != null && widget.budgetController != null) {
        final imported = await widget.budgetController!.importSberSnapshot(
          snapshot,
        );
        if (mounted) {
          final diagnostic = widget.budgetController!.cashFlowForRange(
            from: range.from,
            toExclusive: range.toExclusive,
            currency: 'RUB',
          );
          final closingCashBalance = widget.budgetController!.accounts
              .where(
                (account) =>
                    account.currency == 'RUB' &&
                    account.type != AccountType.investment &&
                    account.type != AccountType.liability,
              )
              .fold<int>(0, (sum, account) => sum + account.balance);
          await _showSberResult(
            report,
            imported,
            period:
                '${_sberShortDate(range.from)}—${_sberShortDate(range.toExclusive.subtract(const Duration(days: 1)))}',
            diagnostic: diagnostic,
            closingCashBalance: closingCashBalance,
          );
        }
        await widget.profileManager.updateLastSync(
          _controller.profile,
          DateTime.now(),
        );
      } else if (mounted && report.message != null) {
        await _showSberFailure(report);
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _showSberResult(
    SberSyncReport report,
    SberImportSummary summary, {
    required String period,
    QestoCashFlowSummary? diagnostic,
    int? closingCashBalance,
  }) async {
    final snapshot = report.snapshot;
    if (!mounted || snapshot == null) return;
    final partial = report.state == SberConnectorState.syncPartial;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          partial ? 'Синхронизация завершена частично' : 'Сбер синхронизирован',
        ),
        content: SizedBox(
          width: 560,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 620),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _syncMetric('Найдено операций', summary.found),
                  _syncMetric('Новых', summary.newCount),
                  _syncMetric('Обновлено', summary.updatedCount),
                  _syncMetric(
                    'Категорий пересчитано',
                    summary.recategorizedCount,
                  ),
                  _syncMetric('Без изменений', summary.unchangedCount),
                  _syncMetric('Счетов найдено', summary.accountsFound),
                  _syncMetric('Балансов обновлено', summary.accountsUpdated),
                  if (summary.accountsMerged > 0)
                    _syncMetric(
                      'Дубликатов счетов объединено',
                      summary.accountsMerged,
                    ),
                  _syncMetric('В обработке', snapshot.pendingCount),
                  const SizedBox(height: 8),
                  Text('Период: $period'),
                  if (snapshot.historyRowsSeen > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'История: ${snapshot.historyRowsAccepted} денежных операций из ${snapshot.historyRowsSeen} записей',
                      style: const TextStyle(color: QestoColors.secondaryText),
                    ),
                    if (snapshot.historyHasMoreRows &&
                        !snapshot.historyRangeBoundaryReached)
                      const Text(
                        'История дочитана не полностью: на странице осталась кнопка «Показать ещё».',
                        style: TextStyle(color: QestoColors.warning),
                      ),
                    if (snapshot.historyRewardRows > 0)
                      Text(
                        'СберСпасибо: ${snapshot.historyRewardRows} неденежных операций',
                        style: const TextStyle(
                          color: QestoColors.secondaryText,
                        ),
                      ),
                    if (snapshot.historyRowsRejected > 0)
                      Text(
                        'Не распознано строк: ${snapshot.historyRowsRejected}. Результат нельзя считать полным.',
                        style: const TextStyle(color: QestoColors.warning),
                      ),
                    if (snapshot.historyLoyaltyRewards >
                        snapshot.historyRewardRows)
                      Text(
                        'Бонусных начислений в денежных операциях: ${snapshot.historyLoyaltyRewards - snapshot.historyRewardRows}',
                        style: const TextStyle(
                          color: QestoColors.secondaryText,
                        ),
                      ),
                    if (snapshot.historyServiceRows > 0)
                      Text(
                        'Служебные действия: ${snapshot.historyServiceRows} (не влияют на баланс)',
                        style: const TextStyle(
                          color: QestoColors.secondaryText,
                        ),
                      ),
                  ],
                  if (widget.devMode && diagnostic != null)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: const Text('DEV · Cash Flow diagnostic'),
                      subtitle: Text(
                        'Net: ${formatMoney(diagnostic.netCashFlow, 'RUB', showSign: true)}',
                      ),
                      children: [
                        _diagnosticMoneyRow(
                          'Внешние поступления',
                          diagnostic.externalInflows,
                        ),
                        _diagnosticMoneyRow(
                          'Внешние списания',
                          diagnostic.externalOutflows,
                        ),
                        _diagnosticMoneyRow(
                          'Внутренние переводы исключены',
                          diagnostic.internalTransfersExcluded,
                        ),
                        _syncMetric(
                          'Неденежных/неподтверждённых исключено',
                          diagnostic.ignoredTransactions,
                        ),
                        _syncMetric(
                          'СберСпасибо проигнорировано',
                          snapshot.historyLoyaltyRewards,
                        ),
                        if (closingCashBalance != null)
                          _diagnosticMoneyRow(
                            'Текущий денежный баланс',
                            closingCashBalance,
                          ),
                        const Padding(
                          padding: EdgeInsets.only(top: 6, bottom: 4),
                          child: Text(
                            'Сверка opening → closing недоступна: Сбер отдаёт текущий баланс, но не снимок баланса на начало выбранного периода.',
                            style: TextStyle(
                              color: QestoColors.secondaryText,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (summary.accounts.isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: Text('Счета (${summary.accounts.length})'),
                      subtitle: Text(
                        '${summary.accountsUpdated} добавлено или обновлено',
                      ),
                      children: summary.accounts
                          .map(_sberAccountResultRow)
                          .toList(growable: false),
                    ),
                  if (summary.transactions.isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: Text('Операции (${summary.transactions.length})'),
                      subtitle: Text(
                        '${summary.newCount} новых · ${summary.updatedCount} обновлено',
                      ),
                      children: summary.transactions
                          .map(_sberTransactionResultRow)
                          .toList(growable: false),
                    ),
                  if (report.message != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      report.message!,
                      style: const TextStyle(color: QestoColors.secondaryText),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSberFailure(SberSyncReport report) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Синхронизация Сбера не завершена'),
        content: Text(
          report.message ??
              'Сбер требует повторного входа или проверки страницы.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }

  Widget _syncMetric(String label, int value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text('$value', style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    ),
  );

  Widget _diagnosticMoneyRow(String label, int value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          formatMoney(value, 'RUB'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );

  Widget _sberAccountResultRow(SberAccountImportItem item) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(_sberChangeLabel(item.change)),
    trailing: Text(
      formatMoney(item.balance, item.currency),
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
  );

  Widget _sberTransactionResultRow(SberTransactionImportItem item) {
    final signedAmount = item.isIncome ? item.amount : -item.amount;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_sberShortDate(item.date)} · ${_sberChangeLabel(item.change)}',
      ),
      trailing: Text(
        formatMoney(signedAmount, item.currency, showSign: item.isIncome),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: item.isIncome ? const Color(0xFF16A05D) : null,
        ),
      ),
    );
  }

  String _sberChangeLabel(SberImportChange value) => switch (value) {
    SberImportChange.created => 'Добавлено',
    SberImportChange.updated => 'Обновлено',
    SberImportChange.unchanged => 'Без изменений',
  };

  Future<void> _saveSberPin() async {
    final input = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('PIN быстрого входа Сбера'),
        content: TextField(
          controller: input,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          decoration: const InputDecoration(
            hintText: '4–8 цифр',
            helperText: 'Хранится только в защищённом хранилище Windows',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    input.dispose();
    if (pin == null || pin.isEmpty) return;
    try {
      await const SberPinVault().write(pin);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PIN сохранён только на этом компьютере.'),
          ),
        );
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  @override
  void dispose() {
    unawaited(_sberSubscription?.cancel());
    unawaited(_sberConnector?.dispose());
    if (widget.devMode) unawaited(DevBrowserBridge.instance.stop());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: QestoColors.background,
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final state = _controller.state;
              return Column(
                children: [
                  _BankBrowserToolbar(
                    state: state,
                    devMode: widget.devMode,
                    onBack: state.canGoBack ? _controller.goBack : null,
                    onForward: state.canGoForward
                        ? _controller.goForward
                        : null,
                    onReload: state.lifecycle == BankBrowserLifecycle.loading
                        ? _controller.stop
                        : _controller.reload,
                    onHome: () => _controller.navigate(widget.bank.startUrl),
                    onClose: _close,
                    onSync: _sberConnector == null || _syncing
                        ? null
                        : () => _syncSber(),
                    onSavePin: _sberConnector == null ? null : _saveSberPin,
                    syncing: _syncing,
                    report: _sberReport,
                  ),
                  if (state.lifecycle == BankBrowserLifecycle.loading)
                    const LinearProgressIndicator(minHeight: 2),
                  Expanded(
                    child: _closing
                        ? const Center(child: CircularProgressIndicator())
                        : state.lifecycle == BankBrowserLifecycle.opening
                        ? const _BrowserStatus(
                            icon: Icons.shield_outlined,
                            title: 'Запускаем защищённый браузер',
                            message:
                                'Подготавливаем отдельный профиль CEF/Chromium…',
                            loading: true,
                          )
                        : state.lifecycle == BankBrowserLifecycle.error
                        ? _BrowserStatus(
                            icon: _controller.hasCertificateProblem
                                ? Icons.gpp_maybe_outlined
                                : Icons.error_outline_rounded,
                            title: _controller.hasCertificateProblem
                                ? 'Сертификат банка не доверен'
                                : 'Браузер не запустился',
                            message:
                                state.errorMessage ??
                                'Проверьте целостность компонентов CEF в папке Qesto.',
                            action: _controller.hasCertificateProblem
                                ? Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 10,
                                    runSpacing: 8,
                                    children: [
                                      FilledButton.icon(
                                        onPressed: () => unawaited(
                                          openExternalUrl(
                                            'https://www.gosuslugi.ru/crt',
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.open_in_new_rounded,
                                          size: 17,
                                        ),
                                        label: const Text(
                                          'Инструкция Госуслуг',
                                        ),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () =>
                                            unawaited(_controller.reload()),
                                        icon: const Icon(
                                          Icons.refresh_rounded,
                                          size: 17,
                                        ),
                                        label: const Text('Проверить снова'),
                                      ),
                                    ],
                                  )
                                : null,
                          )
                        : _controller.isRuntimeReady
                        ? _controller.buildWebView(
                            key: ValueKey('bank-webview-${widget.profile.id}'),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _BankBrowserToolbar extends StatelessWidget {
  const _BankBrowserToolbar({
    required this.state,
    required this.devMode,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onHome,
    required this.onClose,
    this.onSync,
    this.onSavePin,
    this.syncing = false,
    this.report,
  });

  final BankBrowserState state;
  final bool devMode;
  final Future<void> Function()? onBack;
  final Future<void> Function()? onForward;
  final Future<void> Function() onReload;
  final Future<void> Function() onHome;
  final Future<void> Function() onClose;
  final Future<void> Function()? onSync;
  final Future<void> Function()? onSavePin;
  final bool syncing;
  final SberSyncReport? report;

  @override
  Widget build(BuildContext context) {
    final safeUrl = state.currentUrl == null
        ? state.bank.startUrl.toString()
        : Uri(
            scheme: state.currentUrl!.scheme,
            host: state.currentUrl!.host,
            path: state.currentUrl!.path,
          ).toString();
    return Container(
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: QestoColors.surface,
        border: Border(bottom: BorderSide(color: QestoColors.border)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Назад',
            onPressed: onBack == null ? null : () => unawaited(onBack!()),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          IconButton(
            tooltip: 'Вперёд',
            onPressed: onForward == null ? null : () => unawaited(onForward!()),
            icon: const Icon(Icons.arrow_forward_rounded),
          ),
          IconButton(
            tooltip: state.lifecycle == BankBrowserLifecycle.loading
                ? 'Остановить'
                : 'Обновить',
            onPressed: () => unawaited(onReload()),
            icon: Icon(
              state.lifecycle == BankBrowserLifecycle.loading
                  ? Icons.close_rounded
                  : Icons.refresh_rounded,
            ),
          ),
          IconButton(
            tooltip: 'Начальная страница банка',
            onPressed: () => unawaited(onHome()),
            icon: const Icon(Icons.home_outlined),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                color: QestoColors.surfaceSecondary,
                border: Border.all(color: QestoColors.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.lock_rounded,
                    color: Color(0xFF16A05D),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      safeUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    state.bank.displayName,
                    style: const TextStyle(
                      color: QestoColors.secondaryText,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (devMode)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.orange.withValues(alpha: 0.45),
                ),
              ),
              child: const Text(
                'DEV MODE',
                style: TextStyle(
                  color: Colors.deepOrange,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          if (onSavePin != null)
            IconButton(
              tooltip: 'Сохранить PIN быстрого входа локально',
              onPressed: () => unawaited(onSavePin!()),
              icon: const Icon(Icons.password_rounded, size: 19),
            ),
          if (syncing && report != null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                _sberStageLabel(report!.state),
                style: const TextStyle(
                  color: QestoColors.secondaryText,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (onSync != null)
            FilledButton.icon(
              onPressed: syncing ? null : () => unawaited(onSync!()),
              icon: syncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded, size: 17),
              label: Text(syncing ? 'Синхронизация…' : 'Синхронизировать'),
            ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('bank-browser-close'),
            onPressed: () => unawaited(onClose()),
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  String _sberStageLabel(SberConnectorState state) => switch (state) {
    SberConnectorState.checkingAuth => 'Проверяем вход…',
    SberConnectorState.pinRequired => 'Нужен PIN…',
    SberConnectorState.fullLoginRequired => 'Нужен ручной вход…',
    SberConnectorState.syncingProducts => 'Читаем счета…',
    SberConnectorState.syncingTransactions => 'Читаем операции…',
    SberConnectorState.syncComplete => 'Готово',
    SberConnectorState.syncPartial => 'Частично',
    SberConnectorState.error => 'Ошибка',
    _ => 'Синхронизация…',
  };
}

class _BrowserStatus extends StatelessWidget {
  const _BrowserStatus({
    required this.icon,
    required this.title,
    required this.message,
    this.loading = false,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool loading;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: QestoColors.primary, size: 40),
        const SizedBox(height: 14),
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(message, style: const TextStyle(color: QestoColors.secondaryText)),
        if (loading) ...[
          const SizedBox(height: 18),
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 18), action!],
      ],
    ),
  );
}
