import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../data/models/qesto_models.dart';
import '../services/budget_calculation_service.dart';
import '../services/budget_forecast_service.dart';
import '../services/cash_flow_calculation_service.dart';
import '../services/category_budget_calculation_service.dart';
import '../../../synoball/synoball.dart';
import '../../bank_screenshot_import/domain/bank_screenshot_models.dart';
import '../../bank_browser/sber/sber_connector_models.dart';
import '../../transaction_import/services/transaction_category_resolver.dart';

const _transactionCategoryResolver = TransactionCategoryResolver();

ResolvedTransactionCategory _sberCategory(SberTransactionFact value) =>
    _transactionCategoryResolver.resolve(
      '${value.merchant ?? ''} ${value.category ?? ''} '
      '${value.description} ${value.operationType ?? ''}',
    );

String _sberIdentityText(String value) => value
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'[^a-zа-я0-9]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _sberIdentityMoment(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}T'
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

String _sberFactIdentity(SberTransactionFact value) => [
  _sberIdentityMoment(value.date),
  value.amount.abs(),
  value.currency.toUpperCase(),
  value.isIncome ? 'in' : 'out',
  _sberIdentityText(value.merchant ?? value.description),
].join('|');

String _storedSberIdentity(BudgetTransaction value) => [
  _sberIdentityMoment(value.date),
  value.amount.abs(),
  value.currency.toUpperCase(),
  value.type == TransactionType.income ||
          value.type == TransactionType.refund ||
          value.transferDirection == TransferDirection.incoming
      ? 'in'
      : 'out',
  _sberIdentityText(
    value.merchant ?? value.title ?? value.description ?? value.comment ?? '',
  ),
].join('|');

bool _sameStringSet(List<String> left, List<String> right) =>
    left.length == right.length && left.toSet().containsAll(right);

class BudgetController extends ChangeNotifier {
  BudgetController({
    required BudgetConfiguration configuration,
    required UserFinancialData financialData,
    this.onChanged,
    this.calculationService = const BudgetCalculationService(),
    this.forecastService = const BudgetForecastService(),
    this.categoryCalculationService = const CategoryBudgetCalculationService(),
    this.cashFlowCalculationService = const CashFlowCalculationService(),
  }) : referenceDate = financialData.referenceDate,
       _userId = financialData.user.id,
       _ledgerCurrency = financialData.user.defaultCurrency,
       user = financialData.user,
       periods = _resolvedPeriods(financialData),
       _baseCategories = List.of(configuration.categories),
       categories = _resolvedCategories(
         configuration.categories,
         financialData.categoryCustomizations,
       ),
       _categoryCustomizations = List.of(financialData.categoryCustomizations),
       categoryBudgets = List.of(financialData.categoryBudgets),
       accountPreferences = List.of(financialData.accountPreferences),
       plannedCumulativePoints = List.of(financialData.plannedCumulativePoints),
       savingsGoals = List.of(financialData.savingsGoals),
       _upcomingExpenses = List.of(financialData.upcomingExpenses),
       _actions = List.of(financialData.actions) {
    final storedState = financialData.synoballState;
    _synoball = SynoballCore(
      initialState: storedState ?? const SynoballState(),
    );
    if (storedState == null) {
      final input = _legacyBridge.buildInput(financialData);
      _synoball.upsertEntity(input.entity);
      _synoball.ingest(LegacyQestoAdapter(), input);
    }
    final readModel = _readModels.build(_synoball.state);
    accounts = List.of(
      readModel.accounts.isEmpty
          ? _resolvedAccounts(financialData)
          : readModel.accounts,
    );
    _transactions = List.of(
      _applySberAdapterCompatibility(readModel.transactions),
    );
    _legacyTransactionIdentities = {
      for (final transaction in financialData.transactions)
        transaction.id: transaction,
    };
  }

  static List<BudgetPeriod> _resolvedPeriods(UserFinancialData data) {
    if (data.budgetPeriods.isNotEmpty) {
      return List.of(data.budgetPeriods);
    }

    final date = data.referenceDate;
    return [
      BudgetPeriod(
        id: 'local-${date.year}-${date.month.toString().padLeft(2, '0')}',
        userId: data.user.id,
        startDate: DateTime(date.year, date.month),
        endDate: DateTime(date.year, date.month + 1, 0),
        type: BudgetPeriodType.calendarMonth,
        totalPlan: 0,
        currency: data.user.defaultCurrency,
      ),
    ];
  }

  static List<QestoAccount> _resolvedAccounts(UserFinancialData data) {
    if (data.accounts.isNotEmpty) {
      return List.of(data.accounts);
    }

    return [
      QestoAccount(
        id: 'local-default-account',
        userId: data.user.id,
        title: 'Основной счёт',
        balance: 0,
        currency: data.user.defaultCurrency,
        type: AccountType.other,
      ),
    ];
  }

  static List<BudgetCategory> _resolvedCategories(
    List<BudgetCategory> base,
    List<BudgetCategoryCustomization> customizations,
  ) {
    final byId = {
      for (final customization in customizations)
        customization.categoryId: customization,
    };
    return [
      for (final category in base)
        if (byId[category.id] case final customization?)
          category.copyWith(
            name: customization.name,
            iconKey: customization.iconKey,
            colorValue: customization.colorValue,
          )
        else
          category,
    ];
  }

  static Iterable<BudgetTransaction> _applySberAdapterCompatibility(
    Iterable<BudgetTransaction> transactions,
  ) sync* {
    for (final transaction in transactions) {
      if (!transaction.tags.contains('sberbank')) {
        yield transaction;
        continue;
      }
      var compatible = transaction;
      final normalizedTransferText =
          '${transaction.merchant ?? ''} ${transaction.title ?? ''} '
                  '${transaction.description ?? ''} '
                  '${transaction.comment ?? ''} '
                  '${transaction.originalCategoryId ?? ''}'
              .toLowerCase()
              .replaceAll('ё', 'е');
      final ownAccountMovement = RegExp(
        r'между\s+(?:своими|собственными)|на\s+сво[юий]\s+(?:карт|счет)|со\s+своего\s+(?:счета|карт)',
      ).hasMatch(normalizedTransferText);
      final cashMovement =
          normalizedTransferText.contains('внесение наличных') ||
          normalizedTransferText.contains('выдача наличных');
      final hasTransferSemantics =
          transaction.type == TransactionType.transfer ||
          transaction.tags.contains(qestoInternalTransferTag) ||
          transaction.tags.contains(qestoExternalTransferTag);
      if (hasTransferSemantics) {
        final tags = transaction.tags.toSet();
        if (ownAccountMovement || cashMovement) {
          tags
            ..remove(qestoExternalTransferTag)
            ..add(qestoInternalTransferTag);
          compatible = compatible.copyWith(
            type: TransactionType.transfer,
            tags: tags.toList(growable: false),
          );
        } else {
          tags
            ..remove(qestoInternalTransferTag)
            ..add(qestoExternalTransferTag);
          compatible = compatible.copyWith(
            type:
                transaction.transferDirection == TransferDirection.incoming ||
                    transaction.type == TransactionType.income
                ? TransactionType.income
                : TransactionType.expense,
            tags: tags.toList(growable: false),
          );
        }
      }
      if (!transaction.tags.contains(qestoManualCategoryTag)) {
        final resolved = compatible.type == TransactionType.income
            ? const ResolvedTransactionCategory(
                categoryId: 'business',
                confidence: 0.95,
              )
            : _transactionCategoryResolver.resolve(
                '${transaction.merchant ?? ''} ${transaction.title ?? ''} '
                '${transaction.description ?? ''} '
                '${transaction.originalCategoryId ?? ''}',
              );
        compatible = compatible.copyWith(
          categoryId: resolved.categoryId,
          subcategoryId: resolved.subcategoryId,
          classificationConfidence: resolved.confidence,
        );
      }
      if (compatible.tags.contains('sber-status-refund') &&
          compatible.type != TransactionType.refund) {
        yield compatible.copyWith(type: TransactionType.refund);
        continue;
      }
      yield compatible;
    }
  }

  final DateTime referenceDate;
  final String _userId;
  final String _ledgerCurrency;
  QestoUser user;
  final List<BudgetPeriod> periods;
  final List<BudgetCategory> categories;
  final List<BudgetCategory> _baseCategories;
  final List<BudgetCategoryCustomization> _categoryCustomizations;
  final List<CategoryBudget> categoryBudgets;
  final List<QestoAccountPreferences> accountPreferences;
  final List<BudgetPlanPoint> plannedCumulativePoints;
  final List<SavingsGoal> savingsGoals;
  late final List<QestoAccount> accounts;
  final BudgetCalculationService calculationService;
  final BudgetForecastService forecastService;
  final CategoryBudgetCalculationService categoryCalculationService;
  final CashFlowCalculationService cashFlowCalculationService;
  final Future<void> Function()? onChanged;

  late final List<BudgetTransaction> _transactions;
  late final Map<String, BudgetTransaction> _legacyTransactionIdentities;
  final List<UpcomingExpense> _upcomingExpenses;
  final List<FinancialAction> _actions;
  late SynoballCore _synoball;
  var _clearExternalData = false;
  final QestoLegacyBridge _legacyBridge = const QestoLegacyBridge();
  final QestoReadModelService _readModels = const QestoReadModelService();
  final FinancialStateService _financialStateService =
      const FinancialStateService();
  final AiContextService _aiContextService = const AiContextService();

  List<BudgetTransaction> get transactions => List.unmodifiable(_transactions);
  List<UpcomingExpense> get upcomingExpenses =>
      List.unmodifiable(_upcomingExpenses);
  List<FinancialAction> get actions => List.unmodifiable(_actions);
  SynoballState get synoballState => _synoball.state;
  List<TransactionCandidate> get pendingCandidates =>
      _synoball.pendingCandidates;

  QestoCashFlowSummary cashFlowForRange({
    required DateTime from,
    required DateTime toExclusive,
    String? currency,
  }) => cashFlowCalculationService.calculate(
    transactions: _transactions,
    from: from,
    toExclusive: toExclusive,
    currency: currency,
  );

  QestoCashFlowSummary cashFlowFor(BudgetPeriod period) => cashFlowForRange(
    from: period.startDate,
    toExclusive: period.endDate.add(const Duration(days: 1)),
    currency: period.currency,
  );

  CashFlowTreatment cashFlowTreatment(BudgetTransaction transaction) =>
      cashFlowCalculationService.treatment(transaction);

  FinancialState get financialState => _financialStateService.calculate(
    state: _synoball.state,
    entityId: _legacyBridge.entityIdFor(_userId),
    asOf: referenceDate,
    currency: _ledgerCurrency,
    plannedExpensesMinor: _upcomingExpenses
        .where((item) => !item.isCancelled)
        .fold(0, (total, item) => total + item.amount * 100),
  );

  AiFinancialContext aiContext(
    AiContextPurpose purpose, {
    int? proposedPurchaseMinor,
  }) => _aiContextService.build(
    purpose: purpose,
    state: financialState,
    proposedPurchaseMinor: proposedPurchaseMinor,
  );

  UserFinancialData mergeInto(UserFinancialData source) => source.copyWith(
    user: user,
    referenceDate: referenceDate,
    accounts: List.of(accounts),
    accountPreferences: List.of(accountPreferences),
    budgetPeriods: List.of(periods),
    categoryBudgets: List.of(categoryBudgets),
    categoryCustomizations: List.of(_categoryCustomizations),
    transactions: List.of(_transactions),
    upcomingExpenses: List.of(_upcomingExpenses),
    plannedCumulativePoints: List.of(plannedCumulativePoints),
    actions: List.of(_actions),
    savingsGoals: List.of(savingsGoals),
    trackedProducts: _clearExternalData ? const [] : source.trackedProducts,
    synoballState: _synoball.state,
  );

  void _syncFromSynoball() {
    final readModel = _readModels.build(_synoball.state);
    accounts
      ..clear()
      ..addAll(readModel.accounts);
    _transactions
      ..clear()
      ..addAll(_applySberAdapterCompatibility(readModel.transactions));
  }

  void _addAction(FinancialAction action) {
    _actions.insert(0, action);
    if (_actions.length > 50) _actions.removeRange(50, _actions.length);
  }

  Future<void> _changed() async {
    notifyListeners();
    await onChanged?.call();
  }

  BudgetSummary summaryFor(BudgetPeriod period) =>
      calculationService.summary(period, _transactions, categories);

  DateTime activeDateFor(BudgetPeriod period) {
    if (referenceDate.isAfter(period.endDate)) return period.endDate;
    if (!referenceDate.isBefore(period.startDate)) return referenceDate;
    final periodTransactions = transactionsFor(period);
    return periodTransactions.isEmpty
        ? period.startDate
        : periodTransactions.last.date;
  }

  List<BudgetTransaction> transactionsFor(BudgetPeriod period) =>
      calculationService.transactionsForPeriod(period, _transactions);

  List<BudgetTransaction> transactionsForCategory(
    BudgetPeriod period,
    String categoryId,
  ) {
    final result =
        transactionsFor(period)
            .where(
              (transaction) =>
                  transaction.categoryId == categoryId &&
                  calculationService.isConsumerTransaction(transaction),
            )
            .toList()
          ..sort((a, b) => b.date.compareTo(a.date));
    return result;
  }

  List<CategoryPlanStatus> categoryPlansFor(BudgetPeriod period) {
    return categoryCalculationService.calculate(
      period: period,
      categories: categories,
      budgets: categoryBudgets,
      transactions: _transactions,
    );
  }

  List<UpcomingExpense> upcomingFor(BudgetPeriod period) {
    final result =
        _upcomingExpenses
            .where(
              (expense) =>
                  expense.budgetPeriodId == period.id && !expense.isCancelled,
            )
            .toList()
          ..sort((a, b) => a.plannedDate.compareTo(b.plannedDate));
    return result;
  }

  BudgetForecast forecastFor(BudgetPeriod period) {
    return forecastService.buildForecast(
      period: period,
      transactions: _transactions,
      asOfDate: activeDateFor(period),
    );
  }

  int plannedAtActiveDate(BudgetPeriod period) {
    return calculationService.plannedAmountAtDate(
      period,
      activeDateFor(period),
      plannedCumulativePoints,
    );
  }

  int allowedDailyExpense(BudgetPeriod period) {
    final summary = summaryFor(period);
    return calculationService.allowedDailyExpense(
      period,
      summary.currentExpense,
      activeDateFor(period),
    );
  }

  BudgetCategory categoryById(String id) =>
      categories.firstWhere((category) => category.id == id);

  QestoAccount accountById(String id) => accounts.firstWhere(
    (account) => account.id == id,
    orElse: () => accounts.first,
  );

  QestoAccountPreferences accountPreferencesFor(String accountId) {
    for (final value in accountPreferences) {
      if (value.accountId == accountId) return value;
    }
    final account = accounts.where((item) => item.id == accountId).firstOrNull;
    final type = account?.type ?? AccountType.other;
    final isLiquid = {
      AccountType.bankCard,
      AccountType.cash,
      AccountType.savings,
      AccountType.deposit,
    }.contains(type);
    final isReserve = {AccountType.savings, AccountType.deposit}.contains(type);
    return QestoAccountPreferences(
      accountId: accountId,
      role: isReserve ? QestoAccountRole.savings : QestoAccountRole.everyday,
      includeInTotal: isLiquid,
      includeInNetWorth: type != AccountType.liability,
      includeInEmergencyFund: isReserve,
    );
  }

  Future<void> updateAccountPreferences(
    QestoAccountPreferences preferences,
  ) async {
    if (!accounts.any((item) => item.id == preferences.accountId)) return;
    final index = accountPreferences.indexWhere(
      (item) => item.accountId == preferences.accountId,
    );
    if (index < 0) {
      accountPreferences.add(preferences);
    } else {
      accountPreferences[index] = preferences;
    }
    await _changed();
  }

  BudgetPeriod periodForOrCreate(DateTime date) {
    for (final period in periods) {
      if (period.contains(date)) return period;
    }

    final period = BudgetPeriod(
      id: 'imported-${date.year}-${date.month.toString().padLeft(2, '0')}',
      userId: _userId,
      startDate: DateTime(date.year, date.month),
      endDate: DateTime(date.year, date.month + 1, 0),
      type: BudgetPeriodType.calendarMonth,
      totalPlan: 0,
      currency: _ledgerCurrency,
    );
    periods.add(period);
    periods.sort((a, b) => a.startDate.compareTo(b.startDate));
    return period;
  }

  bool hasTransaction(String id) => _synoball.hasTransactionOrProviderId(id);

  Future<void> addImportedTransactions(
    Iterable<BudgetTransaction> transactions, {
    String actionTitle = 'Добавление операции',
    bool confirmedVoiceInput = false,
  }) async {
    final createdIds = <String>[];
    for (final transaction in transactions) {
      if (hasTransaction(transaction.id)) continue;
      final receipt = transaction.receipt;
      final outcome = receipt != null
          ? _ingestReceipt(
              transaction,
              rawPayload: jsonEncode({
                'fiscalDriveNumber': receipt.fiscalDriveNumber,
                'fiscalDocumentNumber': receipt.fiscalDocumentNumber,
                'fiscalSign': receipt.fiscalSign,
              }),
              rawText: transaction.description ?? transaction.comment ?? '',
            )
          : confirmedVoiceInput
          ? _synoball.ingest(
              VoiceInputAdapter(),
              VoiceInput(
                entityId: _legacyBridge.entityIdFor(_userId),
                receivedAt: DateTime.now(),
                rawPayload:
                    transaction.comment ?? transaction.description ?? '',
                transcript:
                    transaction.comment ?? transaction.description ?? '',
                transaction: _seedFromQesto(transaction),
                userCorrections: const {'confirmedInPreview': 'true'},
              ),
            )
          : _synoball.ingest(
              ManualInputAdapter(),
              ManualInput(
                entityId: _legacyBridge.entityIdFor(_userId),
                receivedAt: DateTime.now(),
                rawPayload: jsonEncode({
                  'source': 'qesto-import',
                  'id': transaction.id,
                  'description': transaction.description,
                }),
                transaction: _seedFromQesto(transaction),
              ),
            );
      createdIds.addAll(outcome.createdTransactionIds);
    }
    if (createdIds.isEmpty) {
      _syncFromSynoball();
      await _changed();
      return;
    }
    _syncFromSynoball();
    _addAction(
      FinancialAction(
        id: 'action-${DateTime.now().microsecondsSinceEpoch}',
        occurredAt: DateTime.now(),
        title: actionTitle,
        type: FinancialActionType.transactionAdded,
        createdTransactionIds: createdIds,
      ),
    );
    await _changed();
  }

  Future<int> importStatement({
    required QestoAccount account,
    required Iterable<BudgetTransaction> transactions,
    required Set<String> createdPeriodIds,
    required String actionTitle,
    String? rawPayload,
    Map<String, int> exactMinorById = const {},
    Map<String, String> providerTransactionIdsByTransactionId = const {},
    List<QestoAccount> additionalAccounts = const [],
    bool bankWebSource = false,
  }) async {
    final incoming = transactions.toList(growable: false);
    final previousTransactions = <BudgetTransaction>[];
    for (final transaction in incoming) {
      final index = _transactions.indexWhere(
        (item) => item.id == transaction.id,
      );
      if (index < 0) continue;
      final existing = _transactions[index];
      previousTransactions.add(
        _legacyTransactionIdentities[existing.id] ?? existing,
      );
    }

    final previousAccounts = <QestoAccount>[];
    final createdAccountIds = <String>[];
    var accountChanged = false;
    final importedAccounts = <String, QestoAccount>{
      account.id: account,
      for (final item in additionalAccounts) item.id: item,
    };
    for (final importedAccount in importedAccounts.values) {
      final accountIndex = accounts.indexWhere(
        (item) => item.id == importedAccount.id,
      );
      if (accountIndex < 0) {
        createdAccountIds.add(importedAccount.id);
        accountChanged = true;
      } else if (!_sameAccount(accounts[accountIndex], importedAccount)) {
        previousAccounts.add(accounts[accountIndex]);
        accountChanged = true;
      }
    }
    final entityId = _legacyBridge.entityIdFor(_userId);
    final synoballAccount = _legacyBridge.accountFromQesto(account);
    for (final additional in importedAccounts.values.where(
      (item) => item.id != account.id,
    )) {
      _synoball.upsertAccount(_legacyBridge.accountFromQesto(additional));
    }
    final SynoballAdapter<StatementInput> adapter = bankWebSource
        ? BankWebAdapter()
        : StatementAdapter();
    final outcome = _synoball.ingest(
      adapter,
      StatementInput(
        entityId: entityId,
        receivedAt: DateTime.now(),
        rawPayload:
            rawPayload ??
            jsonEncode({
              'source': 'qesto-statement',
              'transactions': incoming.map((item) => item.id).toList(),
            }),
        batchName: actionTitle,
        transactions: incoming
            .map(
              (item) => _seedFromQesto(
                item,
                exactMinor: exactMinorById[item.id],
                providerTransactionId:
                    providerTransactionIdsByTransactionId[item.id] ?? item.id,
              ),
            )
            .toList(growable: false),
        account: synoballAccount,
      ),
    );
    final incomingById = {for (final item in incoming) item.id: item};
    for (final matchedId in outcome.matchedTransactionIds) {
      final updated = incomingById[matchedId];
      final canonical = _synoball.transactionById(matchedId);
      if (updated == null || canonical == null) continue;
      // A re-import is an explicit adapter refresh. Replace the old legacy
      // type tag instead of leaving both `expense` and `investment` on the
      // same canonical operation after Synoball merges its evidence.
      _synoball.updateTransaction(
        _legacyBridge.canonicalFromQesto(updated, previous: canonical),
        actorId: _userId,
        purpose: 'Refresh a statement operation through its source adapter',
      );
    }
    if (accounts.any((item) => item.id == 'local-default-account') &&
        account.id != 'local-default-account') {
      final placeholder = accounts.firstWhere(
        (item) => item.id == 'local-default-account',
      );
      _synoball.removeAccountIfUnused(placeholder.id);
      if (!_synoball.state.accounts.any((item) => item.id == placeholder.id)) {
        previousAccounts.add(placeholder);
        accountChanged = true;
      }
    }
    _syncFromSynoball();
    if (outcome.createdTransactionIds.isEmpty &&
        outcome.matchedTransactionIds.isEmpty &&
        previousTransactions.isEmpty &&
        !accountChanged) {
      return 0;
    }
    _addAction(
      FinancialAction(
        id: 'action-${DateTime.now().microsecondsSinceEpoch}',
        occurredAt: DateTime.now(),
        title: actionTitle,
        type: FinancialActionType.statementImport,
        createdTransactionIds: outcome.createdTransactionIds,
        createdAccountIds: createdAccountIds,
        createdPeriodIds: createdPeriodIds.toList(),
        previousTransactions: previousTransactions,
        previousAccounts: previousAccounts,
      ),
    );
    await _changed();
    return outcome.createdTransactionIds.length;
  }

  /// Imports facts produced by the local read-only Sber connector through the
  /// Synoball bank-web adapter. The connector never writes raw HTML or banking
  /// credentials into this payload.
  Future<SberImportSummary> importSberSnapshot(
    SberSyncSnapshot snapshot,
  ) async {
    final accountsBeforeImport = List<QestoAccount>.of(accounts);
    final accountReconciliation = _reconcileSberAccounts(snapshot.accounts);
    final importedAccountsById = <String, QestoAccount>{};
    for (final value in snapshot.accounts) {
      final canonicalId = accountReconciliation.sourceToCanonical[value.id]!;
      final linkedCards = value.linkedCardLastFours
          .map((suffix) => '•• $suffix')
          .join(', ');
      importedAccountsById[canonicalId] = QestoAccount(
        id: canonicalId,
        userId: _userId,
        title: linkedCards.isEmpty
            ? value.name
            : '${value.name} · карта $linkedCards',
        balance: value.balance,
        currency: value.currency,
        type: value.type,
      );
    }
    final importedAccounts = importedAccountsById.values.toList(
      growable: false,
    );
    final accountIds = importedAccounts.map((item) => item.id).toSet();
    // A parser mismatch in the products screen must not discard operations
    // that were successfully read from the history screen. Keep the existing
    // account as a safe target until the next complete product refresh.
    final fallbackAccountId = importedAccounts.isNotEmpty
        ? importedAccounts.first.id
        : (accounts.isNotEmpty ? accounts.first.id : 'local-default-account');
    final existingById = {for (final item in _transactions) item.id: item};
    final proposedIds = {
      for (final value in snapshot.transactions)
        value.fingerprint: 'sber-${value.fingerprint}',
    };
    final exactMatchedIds = proposedIds.values
        .where(existingById.containsKey)
        .toSet();
    final unmatchedIncomingBySignature = <String, List<SberTransactionFact>>{};
    for (final value in snapshot.transactions) {
      final proposedId = proposedIds[value.fingerprint]!;
      if (existingById.containsKey(proposedId)) continue;
      unmatchedIncomingBySignature
          .putIfAbsent(_sberFactIdentity(value), () => <SberTransactionFact>[])
          .add(value);
    }
    final unmatchedExistingBySignature = <String, List<BudgetTransaction>>{};
    for (final value in existingById.values.where(
      (item) =>
          item.tags.contains('sber-live') && !exactMatchedIds.contains(item.id),
    )) {
      unmatchedExistingBySignature
          .putIfAbsent(_storedSberIdentity(value), () => <BudgetTransaction>[])
          .add(value);
    }
    final compatibleExistingIdByProposedId = <String, String>{};
    for (final entry in unmatchedIncomingBySignature.entries) {
      final oldMatches = unmatchedExistingBySignature[entry.key];
      // Provider IDs introduced by a connector upgrade can replace an old
      // ordinal-based ID only for an unambiguous one-to-one economic fact.
      // Repeated equal payments must remain separate.
      if (entry.value.length != 1 || oldMatches?.length != 1) continue;
      final incoming = entry.value.single;
      compatibleExistingIdByProposedId[proposedIds[incoming.fingerprint]!] =
          oldMatches!.single.id;
    }
    final providerTransactionIdsByTransactionId = <String, String>{};
    final importedTransactions = snapshot.transactions
        .map((value) {
          final providerId = proposedIds[value.fingerprint]!;
          final id = compatibleExistingIdByProposedId[providerId] ?? providerId;
          providerTransactionIdsByTransactionId[id] = providerId;
          final existing = existingById[id];
          final manualCategory =
              existing?.tags.contains(qestoManualCategoryTag) == true;
          final automaticCategory = value.isIncome
              ? const ResolvedTransactionCategory(
                  categoryId: 'business',
                  confidence: 0.95,
                )
              : _sberCategory(value);
          final type = value.status == 'REFUND'
              ? TransactionType.refund
              : value.isIncome
              ? TransactionType.income
              : value.isInternalTransfer
              ? TransactionType.transfer
              : TransactionType.expense;
          final tags = <String>{
            'sberbank',
            'sber-live',
            'sber-status-${value.status.toLowerCase()}',
            if (value.isTransfer && value.isInternalTransfer)
              qestoInternalTransferTag,
            if (value.isTransfer && !value.isInternalTransfer)
              qestoExternalTransferTag,
            if (value.loyaltyReward != null) qestoLoyaltyMetadataTag,
            if (manualCategory)
              qestoManualCategoryTag
            else
              qestoAutoCategoryTag,
          };
          return BudgetTransaction(
            id: id,
            userId: _userId,
            accountId:
                accountIds.contains(
                  accountReconciliation.sourceToCanonical[value.accountId] ??
                      value.accountId,
                )
                ? accountReconciliation.sourceToCanonical[value.accountId] ??
                      value.accountId
                : fallbackAccountId,
            date: value.date,
            amount: value.amount,
            currency: value.currency,
            type: type,
            categoryId: manualCategory
                ? existing!.categoryId
                : automaticCategory.categoryId,
            subcategoryId: manualCategory
                ? existing!.subcategoryId
                : automaticCategory.subcategoryId,
            merchant: value.merchant,
            title: value.merchant ?? value.description,
            description: value.description,
            comment: 'СберБанк Онлайн · ${value.status}',
            normalizedMerchant: value.merchant?.toLowerCase(),
            isConfirmed: value.status == 'POSTED' || value.status == 'REFUND',
            isPotentialDuplicate: false,
            classificationConfidence: manualCategory
                ? existing!.classificationConfidence
                : automaticCategory.confidence,
            originalCategoryId: value.category,
            transferDirection: value.isTransfer
                ? value.isIncome
                      ? TransferDirection.incoming
                      : TransferDirection.outgoing
                : null,
            tags: tags.toList(growable: false),
          );
        })
        .toList(growable: false);
    final accountsUpdated = importedAccounts.where((incoming) {
      final index = accountsBeforeImport.indexWhere(
        (item) => item.id == incoming.id,
      );
      // A first observation is also a balance update from the user's point
      // of view: the account did not exist in Qesto before this sync.
      return index < 0 || !_sameAccount(accountsBeforeImport[index], incoming);
    }).length;
    final accountItems = importedAccounts
        .map((incoming) {
          final index = accountsBeforeImport.indexWhere(
            (item) => item.id == incoming.id,
          );
          final change = index < 0
              ? SberImportChange.created
              : !_sameAccount(accountsBeforeImport[index], incoming)
              ? SberImportChange.updated
              : SberImportChange.unchanged;
          return SberAccountImportItem(
            title: incoming.title,
            balance: incoming.balance,
            currency: incoming.currency,
            change: change,
          );
        })
        .toList(growable: false);
    if (importedTransactions.isEmpty && importedAccounts.isEmpty) {
      return const SberImportSummary(
        found: 0,
        newCount: 0,
        updatedCount: 0,
        unchangedCount: 0,
        accountsFound: 0,
        accountsUpdated: 0,
      );
    }
    bool transactionChanged(
      BudgetTransaction existing,
      BudgetTransaction incoming,
    ) {
      return existing.amount != incoming.amount ||
          existing.currency != incoming.currency ||
          existing.date != incoming.date ||
          existing.type != incoming.type ||
          existing.categoryId != incoming.categoryId ||
          existing.title != incoming.title ||
          existing.merchant != incoming.merchant ||
          existing.description != incoming.description ||
          existing.transferDirection != incoming.transferDirection ||
          !_sameStringSet(existing.tags, incoming.tags) ||
          existing.isConfirmed != incoming.isConfirmed;
    }

    final recategorizedCount = importedTransactions.where((incoming) {
      final existing = existingById[incoming.id];
      return existing != null &&
          !existing.tags.contains(qestoManualCategoryTag) &&
          existing.categoryId != incoming.categoryId;
    }).length;

    final updatedBeforeImport = importedTransactions.where((incoming) {
      final existing = existingById[incoming.id];
      if (existing == null) return false;
      return transactionChanged(existing, incoming);
    }).length;
    final transactionItems = importedTransactions
        .map((incoming) {
          final existing = existingById[incoming.id];
          final change = existing == null
              ? SberImportChange.created
              : transactionChanged(existing, incoming)
              ? SberImportChange.updated
              : SberImportChange.unchanged;
          return SberTransactionImportItem(
            title: incoming.title ?? incoming.description ?? 'Операция Сбера',
            date: incoming.date,
            amount: incoming.amount,
            currency: incoming.currency,
            isIncome:
                incoming.type == TransactionType.income ||
                incoming.type == TransactionType.refund,
            isTransfer: incoming.type == TransactionType.transfer,
            change: change,
          );
        })
        .toList(growable: false);
    final periods = <String>{};
    for (final transaction in importedTransactions) {
      periods.add(periodForOrCreate(transaction.date).id);
    }
    final primaryAccount = importedAccounts.isNotEmpty
        ? importedAccounts.first
        : accounts.first;
    final created = await importStatement(
      account: primaryAccount,
      additionalAccounts: importedAccounts.skip(1).toList(growable: false),
      transactions: importedTransactions,
      createdPeriodIds: periods,
      actionTitle: 'Синхронизация Сбера',
      rawPayload: jsonEncode({
        'source': 'sber-cef-read-only',
        'observedAt': snapshot.observedAt.toIso8601String(),
        'transactionIds': importedTransactions.map((item) => item.id).toList(),
      }),
      providerTransactionIdsByTransactionId:
          providerTransactionIdsByTransactionId,
      bankWebSource: true,
    );
    var accountsMerged = 0;
    for (final entry in accountReconciliation.duplicateToPrimary.entries) {
      if (entry.key == entry.value) continue;
      final duplicateExists = _synoball.state.accounts.any(
        (item) => item.id == entry.key,
      );
      final primaryExists = _synoball.state.accounts.any(
        (item) => item.id == entry.value,
      );
      if (!duplicateExists || !primaryExists) continue;
      _synoball.mergeAccountInto(
        duplicateAccountId: entry.key,
        primaryAccountId: entry.value,
        actorId: _userId,
        purpose:
            'Reconcile duplicate Sber account/card observations after sync',
      );
      accountsMerged += 1;
    }
    if (accountsMerged > 0) {
      _syncFromSynoball();
      await _changed();
    }
    final updated = updatedBeforeImport.clamp(0, importedTransactions.length);
    return SberImportSummary(
      found: importedTransactions.length,
      newCount: created,
      updatedCount: updated,
      unchangedCount: (importedTransactions.length - created - updated).clamp(
        0,
        importedTransactions.length,
      ),
      accountsFound: importedAccounts.length,
      accountsUpdated: accountsUpdated,
      accountsMerged: accountsMerged,
      accounts: accountItems,
      transactions: transactionItems,
      recategorizedCount: recategorizedCount,
    );
  }

  _SberAccountReconciliation _reconcileSberAccounts(
    List<SberAccountFact> facts,
  ) {
    final sourceToCanonical = <String, String>{};
    final duplicateToPrimary = <String, String>{};
    final alreadyAssigned = <String>{};
    for (final fact in facts) {
      final eligible = accounts
          .where(
            (account) =>
                account.id.startsWith('sber-account-') &&
                account.currency == fact.currency &&
                _sberAccountTypesCompatible(account.type, fact.type),
          )
          .toList(growable: false);
      final exact = eligible.where((account) => account.id == fact.id).toList();
      final suffixes = <String>{
        if (fact.lastFour != null) fact.lastFour!,
        ...fact.linkedCardLastFours,
      };
      final suffixMatches = suffixes.isEmpty
          ? const <QestoAccount>[]
          : eligible
                .where(
                  (account) => _sberAccountSuffixes(
                    account.title,
                  ).intersection(suffixes).isNotEmpty,
                )
                .toList(growable: false);
      final normalizedName = _normalizedSberAccountName(fact.name);
      final nameMatches = eligible
          .where(
            (account) =>
                normalizedName.isNotEmpty &&
                _normalizedSberAccountName(account.title) == normalizedName,
          )
          .toList(growable: false);
      final candidates = exact.isNotEmpty
          ? exact
          : suffixMatches.isNotEmpty
          ? suffixMatches
          : nameMatches.length == 1
          ? nameMatches
          : const <QestoAccount>[];
      final unassigned = candidates
          .where((account) => !alreadyAssigned.contains(account.id))
          .toList(growable: false);
      final primary = _mostUsedSberAccount(
        unassigned.isNotEmpty ? unassigned : candidates,
      );
      final canonicalId = primary?.id ?? fact.id;
      sourceToCanonical[fact.id] = canonicalId;
      alreadyAssigned.add(canonicalId);

      // Only suffix-linked accounts are safe to merge automatically. Equal
      // display names alone are insufficient because a user may own several
      // savings accounts with the same provider label.
      for (final duplicate in suffixMatches) {
        if (duplicate.id != canonicalId) {
          duplicateToPrimary[duplicate.id] = canonicalId;
        }
      }
    }
    return _SberAccountReconciliation(
      sourceToCanonical: sourceToCanonical,
      duplicateToPrimary: duplicateToPrimary,
    );
  }

  QestoAccount? _mostUsedSberAccount(List<QestoAccount> candidates) {
    if (candidates.isEmpty) return null;
    final sorted = List<QestoAccount>.of(candidates)
      ..sort((left, right) {
        final leftUses = _transactions
            .where((item) => item.accountId == left.id)
            .length;
        final rightUses = _transactions
            .where((item) => item.accountId == right.id)
            .length;
        final byUses = rightUses.compareTo(leftUses);
        return byUses != 0 ? byUses : left.id.compareTo(right.id);
      });
    return sorted.first;
  }

  static Set<String> _sberAccountSuffixes(String value) => RegExp(
    r'(?:\*{2,}|x{2,}|•{2,})\s*(\d{4})',
    caseSensitive: false,
  ).allMatches(value).map((match) => match.group(1)!).toSet();

  static String _normalizedSberAccountName(String value) => value
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'(?:\*{2,}|x{2,}|•{2,})\s*\d{4}'), ' ')
      .replaceAll(RegExp(r'\bкарта\b'), ' ')
      .replaceAll(RegExp(r'\bсбер(?:банк)?\b'), ' ')
      .replaceAll(RegExp(r'[^a-zа-я0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _sberAccountTypesCompatible(
    AccountType existing,
    AccountType incoming,
  ) {
    if (existing == incoming) return true;
    const paymentTypes = {
      AccountType.bankCard,
      AccountType.cash,
      AccountType.other,
    };
    return paymentTypes.contains(existing) && paymentTypes.contains(incoming);
  }

  Future<void> addExpense({
    required BudgetPeriod period,
    required int amount,
    required DateTime date,
    required String categoryId,
    required String accountId,
    required String title,
    String? subcategoryId,
    String? comment,
  }) async {
    final transaction = BudgetTransaction(
      id: 'manual-${DateTime.now().microsecondsSinceEpoch}',
      userId: period.userId,
      accountId: accountId,
      date: date,
      amount: amount,
      currency: period.currency,
      type: TransactionType.expense,
      categoryId: categoryId,
      subcategoryId: subcategoryId,
      merchant: title,
      title: title,
      comment: comment,
      tags: const ['legacy-type-expense'],
    );
    final outcome = _synoball.ingest(
      ManualInputAdapter(),
      ManualInput(
        entityId: _legacyBridge.entityIdFor(_userId),
        receivedAt: DateTime.now(),
        rawPayload: jsonEncode({
          'amountMinor': amount * 100,
          'currency': period.currency,
          'date': date.toIso8601String(),
          'categoryId': categoryId,
          'accountId': accountId,
          'title': title,
          'subcategoryId': subcategoryId,
          'comment': comment,
        }),
        transaction: _seedFromQesto(transaction),
      ),
    );
    _syncFromSynoball();
    _addAction(
      FinancialAction(
        id: 'action-${DateTime.now().microsecondsSinceEpoch}',
        occurredAt: DateTime.now(),
        title: 'Добавлен расход «$title»',
        type: FinancialActionType.transactionAdded,
        createdTransactionIds: outcome.createdTransactionIds,
      ),
    );
    await _changed();
  }

  Future<IngestionOutcome> addAndroidNotificationExpense({
    required BudgetPeriod period,
    required int amountMinor,
    required DateTime date,
    required String categoryId,
    required String accountId,
    required String title,
    required String notificationKey,
    required String packageName,
    required String rawNotification,
    String? subcategoryId,
    double confidence = 0.8,
  }) async {
    return addNotificationTransaction(
      period: period,
      amountMinor: amountMinor,
      currency: period.currency,
      date: date,
      type: TransactionType.expense,
      categoryId: categoryId,
      accountId: accountId,
      title: title,
      notificationKey: notificationKey,
      packageName: packageName,
      rawNotification: rawNotification,
      subcategoryId: subcategoryId,
      confidence: confidence,
    );
  }

  Future<IngestionOutcome> addNotificationTransaction({
    required BudgetPeriod period,
    required int amountMinor,
    required String currency,
    required DateTime date,
    required TransactionType type,
    required String categoryId,
    required String accountId,
    required String title,
    required String notificationKey,
    required String packageName,
    required String rawNotification,
    String? sender,
    String? subcategoryId,
    bool isSmsNotification = false,
    double confidence = 0.8,
  }) async {
    final direction = switch (type) {
      TransactionType.income ||
      TransactionType.refund => FinancialDirection.inflow,
      TransactionType.transfer => FinancialDirection.outflow,
      _ => FinancialDirection.outflow,
    };
    final transferDirection = type == TransactionType.transfer
        ? TransferDirection.outgoing.name
        : null;
    final seed = TransactionSeed(
      accountId: accountId,
      amount: Money(minorUnits: amountMinor.abs(), currency: currency),
      direction: direction,
      occurredAt: date,
      description: rawNotification,
      merchant: title,
      category: categoryId,
      subcategoryId: subcategoryId,
      providerTransactionId: notificationKey,
      transferDirection: transferDirection,
      tags: [
        'legacy-type-${type.name}',
        if (type == TransactionType.refund) 'refund',
        if (type == TransactionType.transfer) qestoExternalTransferTag,
        if (isSmsNotification) 'sms-notification' else 'android-notification',
      ],
      confidence: confidence,
    );
    final outcome = isSmsNotification
        ? _synoball.ingest(
            SmsNotificationAdapter(),
            SmsNotificationInput(
              entityId: _legacyBridge.entityIdFor(_userId),
              receivedAt: DateTime.now(),
              rawPayload: rawNotification,
              notificationKey: notificationKey,
              packageName: packageName,
              sender: sender ?? '',
              transaction: seed,
            ),
          )
        : _synoball.ingest(
            AndroidNotificationAdapter(),
            AndroidNotificationInput(
              entityId: _legacyBridge.entityIdFor(_userId),
              receivedAt: DateTime.now(),
              rawPayload: rawNotification,
              notificationKey: notificationKey,
              packageName: packageName,
              transaction: seed,
            ),
          );
    _syncFromSynoball();
    if (outcome.createdTransactionIds.isNotEmpty) {
      _addAction(
        FinancialAction(
          id: 'action-${DateTime.now().microsecondsSinceEpoch}',
          occurredAt: DateTime.now(),
          title: 'Добавлена операция «$title»',
          type: FinancialActionType.transactionAdded,
          createdTransactionIds: outcome.createdTransactionIds,
        ),
      );
    }
    await _changed();
    return outcome;
  }

  Future<IngestionOutcome> importBankScreenshotCandidates(
    Iterable<BankScreenshotCandidate> values,
  ) async {
    final candidates = values
        .where((candidate) => candidate.selected && candidate.accountId != null)
        .toList(growable: false);
    if (candidates.isEmpty) {
      return const IngestionOutcome(
        ingestionRecordId: '',
        createdTransactionIds: [],
        matchedTransactionIds: [],
        pendingCandidateIds: [],
      );
    }
    for (final candidate in candidates) {
      periodForOrCreate(candidate.date);
    }
    final seeds = candidates
        .map((candidate) {
          final type = candidate.transactionType;
          final direction =
              type == TransactionType.income || type == TransactionType.refund
              ? FinancialDirection.inflow
              : FinancialDirection.outflow;
          return TransactionSeed(
            accountId: candidate.accountId!,
            amount: Money(
              minorUnits: candidate.amountMinor.abs(),
              currency: candidate.currency,
            ),
            direction: direction,
            occurredAt: candidate.date,
            description: candidate.merchant,
            merchant: candidate.merchant,
            category: candidate.categoryId,
            providerTransactionId: candidate.id,
            transferDirection: type == TransactionType.transfer
                ? TransferDirection.outgoing.name
                : null,
            tags: [
              'legacy-type-${type.name}',
              'bank-screenshot',
              'bank-screenshot-parser:${candidate.parserId}',
              if (candidate.dateOnly) 'date-precision:day',
              if (type == TransactionType.transfer) qestoExternalTransferTag,
              if (type == TransactionType.refund) 'refund',
            ],
            confidence: candidate.confidence,
          );
        })
        .toList(growable: false);
    final outcome = _synoball.ingest(
      BankScreenshotAdapter(),
      BankScreenshotInput(
        entityId: _legacyBridge.entityIdFor(_userId),
        receivedAt: DateTime.now(),
        rawPayload: '{"redacted":true}',
        batchName: 'Импорт скриншотов банка',
        transactions: seeds,
        imageHashes: candidates
            .map((candidate) => candidate.imageHash)
            .toSet()
            .toList(growable: false),
        parserIds: candidates
            .map((candidate) => candidate.parserId)
            .toSet()
            .toList(growable: false),
        institutionId:
            candidates.every(
              (candidate) => candidate.parserId.startsWith('sber'),
            )
            ? 'sberbank'
            : null,
      ),
    );
    _syncFromSynoball();
    if (outcome.createdTransactionIds.isNotEmpty) {
      _addAction(
        FinancialAction(
          id: 'action-${DateTime.now().microsecondsSinceEpoch}',
          occurredAt: DateTime.now(),
          title: 'Импорт скриншотов банка',
          type: FinancialActionType.statementImport,
          createdTransactionIds: outcome.createdTransactionIds,
        ),
      );
    }
    await _changed();
    return outcome;
  }

  Future<IngestionOutcome> ingestReceiptTransaction(
    BudgetTransaction transaction, {
    required String rawPayload,
    required String rawText,
  }) async {
    final outcome = _ingestReceipt(
      transaction,
      rawPayload: rawPayload,
      rawText: rawText,
    );
    _syncFromSynoball();
    if (outcome.createdTransactionIds.isNotEmpty) {
      _addAction(
        FinancialAction(
          id: 'action-${DateTime.now().microsecondsSinceEpoch}',
          occurredAt: DateTime.now(),
          title: 'Добавлен кассовый чек',
          type: FinancialActionType.transactionAdded,
          createdTransactionIds: outcome.createdTransactionIds,
        ),
      );
    }
    await _changed();
    return outcome;
  }

  Future<String> addVoiceCandidate({
    required String transcript,
    required int amountMinor,
    required String currency,
    required String accountId,
    required DateTime occurredAt,
    required String merchant,
    String? categoryId,
    double confidence = 0.7,
  }) async {
    final outcome = _synoball.ingest(
      VoiceInputAdapter(),
      VoiceInput(
        entityId: _legacyBridge.entityIdFor(_userId),
        receivedAt: DateTime.now(),
        rawPayload: transcript,
        transcript: transcript,
        transaction: TransactionSeed(
          accountId: accountId,
          amount: Money(minorUnits: amountMinor.abs(), currency: currency),
          direction: FinancialDirection.outflow,
          occurredAt: occurredAt,
          description: transcript,
          merchant: merchant,
          category: categoryId,
          confidence: confidence,
          requiresConfirmation: true,
          tags: const ['legacy-type-expense', 'voice-input'],
        ),
      ),
    );
    await _changed();
    return outcome.pendingCandidateIds.single;
  }

  Future<String> confirmVoiceCandidate(String candidateId) async {
    final id = _synoball.confirmCandidate(candidateId, actorId: _userId);
    _syncFromSynoball();
    await _changed();
    return id;
  }

  Future<bool> undoAction(String id) async {
    final actionIndex = _actions.indexWhere((item) => item.id == id);
    if (actionIndex < 0 || _actions[actionIndex].isUndone) return false;
    final action = _actions[actionIndex];

    for (final transactionId in action.createdTransactionIds) {
      _synoball.deleteTransaction(transactionId, actorId: _userId);
    }
    for (final previous in action.previousTransactions) {
      final canonical = _synoball.transactionById(previous.id);
      if (canonical != null) {
        _synoball.restoreTransaction(
          _legacyBridge.canonicalFromQesto(previous, previous: canonical),
        );
      }
    }
    for (final accountId in action.createdAccountIds) {
      _synoball.removeAccountIfUnused(accountId);
    }
    for (final previous in action.previousAccounts) {
      _synoball.upsertAccount(_legacyBridge.accountFromQesto(previous));
    }
    _syncFromSynoball();
    for (final periodId in action.createdPeriodIds) {
      final hasTransactions = _transactions.any(
        (transaction) => periods
            .where((period) => period.id == periodId)
            .any((period) => period.contains(transaction.date)),
      );
      if (!hasTransactions && periods.length > 1) {
        periods.removeWhere((period) => period.id == periodId);
      }
    }
    _actions[actionIndex] = action.copyWith(isUndone: true);
    await _changed();
    return true;
  }

  bool _sameAccount(QestoAccount left, QestoAccount right) =>
      left.id == right.id &&
      left.userId == right.userId &&
      left.title == right.title &&
      left.balance == right.balance &&
      left.currency == right.currency &&
      left.type == right.type;

  Future<void> updateTransaction(BudgetTransaction transaction) async {
    final canonical = _synoball.transactionById(transaction.id);
    if (canonical == null) return;
    final categoryChanged =
        transaction.categoryId != canonical.effectiveCategory;
    final updated = categoryChanged
        ? transaction.copyWith(
            tags: {
              ...transaction.tags.where((tag) => tag != qestoAutoCategoryTag),
              qestoManualCategoryTag,
            }.toList(),
          )
        : transaction;
    _synoball.updateTransaction(
      _legacyBridge.canonicalFromQesto(updated, previous: canonical),
      actorId: _userId,
    );
    _syncFromSynoball();
    await _changed();
  }

  Future<void> updateTransactions(
    Iterable<BudgetTransaction> transactions,
  ) async {
    var changed = false;
    for (final transaction in transactions) {
      final canonical = _synoball.transactionById(transaction.id);
      if (canonical == null) continue;
      final categoryChanged =
          transaction.categoryId != canonical.effectiveCategory;
      final updated = categoryChanged
          ? transaction.copyWith(
              tags: {
                ...transaction.tags.where((tag) => tag != qestoAutoCategoryTag),
                qestoManualCategoryTag,
              }.toList(),
            )
          : transaction;
      _synoball.updateTransaction(
        _legacyBridge.canonicalFromQesto(updated, previous: canonical),
        actorId: _userId,
      );
      changed = true;
    }
    if (!changed) return;
    _syncFromSynoball();
    await _changed();
  }

  Future<void> setCategoryBudget({
    required BudgetPeriod period,
    required String categoryId,
    required int plannedAmount,
  }) async {
    final index = categoryBudgets.indexWhere(
      (item) =>
          item.budgetPeriodId == period.id && item.categoryId == categoryId,
    );
    final value = CategoryBudget(
      id: index < 0
          ? 'category-budget-${period.id}-$categoryId'
          : categoryBudgets[index].id,
      budgetPeriodId: period.id,
      categoryId: categoryId,
      plannedAmount: plannedAmount.clamp(0, 1000000000),
    );
    if (index < 0) {
      categoryBudgets.add(value);
    } else {
      categoryBudgets[index] = value;
    }
    await _changed();
  }

  Future<void> setTotalBudget({
    required BudgetPeriod period,
    required int totalPlan,
  }) async {
    final index = periods.indexWhere((item) => item.id == period.id);
    if (index < 0) return;
    periods[index] = periods[index].copyWith(
      totalPlan: totalPlan.clamp(0, 1000000000),
    );
    plannedCumulativePoints.removeWhere(
      (point) => point.budgetPeriodId == period.id,
    );
    await _changed();
  }

  Future<void> updateCategoryAppearance({
    required String categoryId,
    required String name,
    required String iconKey,
    required int colorValue,
  }) async {
    final index = categories.indexWhere((item) => item.id == categoryId);
    if (index < 0) return;
    final cleanedName = name.trim();
    final current = categories[index];
    final updated = current.copyWith(
      name: cleanedName.isEmpty ? current.name : cleanedName,
      iconKey: iconKey,
      colorValue: colorValue,
    );
    categories[index] = updated;
    final customization = BudgetCategoryCustomization(
      categoryId: categoryId,
      name: updated.name,
      iconKey: updated.iconKey,
      colorValue: updated.colorValue,
    );
    final customizationIndex = _categoryCustomizations.indexWhere(
      (item) => item.categoryId == categoryId,
    );
    if (customizationIndex < 0) {
      _categoryCustomizations.add(customization);
    } else {
      _categoryCustomizations[customizationIndex] = customization;
    }
    await _changed();
  }

  Future<QestoAccount> addAccount({
    required String title,
    required int balance,
    required AccountType type,
    String? currency,
  }) async {
    final id = 'account-${DateTime.now().microsecondsSinceEpoch}';
    final resolvedCurrency = currency ?? user.defaultCurrency;
    final account = QestoAccount(
      id: id,
      userId: _userId,
      title: title,
      balance: balance,
      currency: resolvedCurrency,
      type: type,
    );
    _synoball.upsertAccount(
      SynoballAccount(
        id: id,
        entityId: _legacyBridge.entityIdFor(_userId),
        name: title,
        type: switch (type) {
          AccountType.cash => SynoballAccountType.cash,
          AccountType.bankCard => SynoballAccountType.card,
          AccountType.savings => SynoballAccountType.savings,
          AccountType.deposit => SynoballAccountType.deposit,
          AccountType.investment => SynoballAccountType.investment,
          AccountType.liability => SynoballAccountType.loan,
          _ => SynoballAccountType.other,
        },
        currency: resolvedCurrency,
        balance: Money(minorUnits: balance * 100, currency: resolvedCurrency),
      ),
    );
    _syncFromSynoball();
    await _changed();
    return account;
  }

  Future<void> deleteTransaction(String id) async {
    if (!hasTransaction(id)) return;
    _synoball.deleteTransaction(id, actorId: _userId);
    _syncFromSynoball();
    await _changed();
  }

  /// Clears user financial content while retaining only the minimum local
  /// profile/account scaffold required for the UI to remain operational.
  Future<void> clearAllFinancialData() async {
    _synoball = SynoballCore();
    final entityId = _legacyBridge.entityIdFor(_userId);
    _synoball.upsertEntity(
      SynoballEntity(
        id: entityId,
        type: SynoballEntityType.person,
        displayName: user.name,
      ),
    );
    _synoball.upsertAccount(
      SynoballAccount(
        id: 'local-default-account',
        entityId: entityId,
        name: 'Основной счёт',
        type: SynoballAccountType.other,
        currency: _ledgerCurrency,
        balance: Money(minorUnits: 0, currency: _ledgerCurrency),
        isVirtual: true,
      ),
    );
    _syncFromSynoball();
    periods
      ..clear()
      ..add(
        BudgetPeriod(
          id: 'local-${referenceDate.year}-${referenceDate.month.toString().padLeft(2, '0')}',
          userId: _userId,
          startDate: DateTime(referenceDate.year, referenceDate.month),
          endDate: DateTime(referenceDate.year, referenceDate.month + 1, 0),
          type: BudgetPeriodType.calendarMonth,
          totalPlan: 0,
          currency: _ledgerCurrency,
        ),
      );
    categoryBudgets.clear();
    accountPreferences.clear();
    _categoryCustomizations.clear();
    categories
      ..clear()
      ..addAll(_baseCategories);
    plannedCumulativePoints.clear();
    savingsGoals.clear();
    _upcomingExpenses.clear();
    _actions.clear();
    _legacyTransactionIdentities.clear();
    _clearExternalData = true;
    await _changed();
  }

  Future<void> updateUserProfile({
    required String name,
    required String defaultCurrency,
    String? avatarUrl,
  }) async {
    final cleanedName = name.trim();
    final cleanedCurrency = defaultCurrency.trim().toUpperCase();
    if (cleanedName.isEmpty || cleanedCurrency.length != 3) return;
    user = user.copyWith(
      name: cleanedName,
      defaultCurrency: cleanedCurrency,
      avatarUrl: avatarUrl,
      clearAvatar: avatarUrl == null,
    );
    _synoball.upsertEntity(
      SynoballEntity(
        id: _legacyBridge.entityIdFor(_userId),
        type: SynoballEntityType.person,
        displayName: cleanedName,
      ),
    );
    await _changed();
  }

  Future<void> updateExpenseDisplayCurrency(String currency) async {
    final cleaned = currency.trim().toUpperCase();
    if (!const {'RUB', 'USD', 'EUR', 'CNY'}.contains(cleaned)) return;
    if (user.expenseDisplayCurrency == cleaned) return;
    user = user.copyWith(expenseDisplayCurrency: cleaned);
    await _changed();
  }

  Future<SavingsGoal?> addSavingsGoal({
    required String title,
    required String category,
    required int targetAmount,
    required DateTime targetDate,
    int savedAmount = 0,
    String? currency,
  }) async {
    final cleanedTitle = title.trim();
    if (cleanedTitle.isEmpty || targetAmount <= 0) return null;
    final goal = SavingsGoal(
      id: 'goal-${DateTime.now().microsecondsSinceEpoch}',
      userId: _userId,
      title: cleanedTitle,
      targetAmount: targetAmount,
      savedAmount: savedAmount.clamp(0, targetAmount).toInt(),
      currency: currency ?? user.defaultCurrency,
      streakWeeks: 0,
      isActive: savingsGoals.every((item) => !item.isActive),
      history: savedAmount <= 0
          ? const []
          : [SavingsHistoryPoint(date: referenceDate, amount: savedAmount)],
      category: category.trim().isEmpty ? 'Другое' : category.trim(),
      targetDate: targetDate,
    );
    savingsGoals.add(goal);
    _clearExternalData = false;
    await _changed();
    return goal;
  }

  Future<void> updateSavingsGoal(SavingsGoal goal) async {
    final index = savingsGoals.indexWhere((item) => item.id == goal.id);
    if (index < 0 || goal.title.trim().isEmpty || goal.targetAmount <= 0) {
      return;
    }
    savingsGoals[index] = goal.copyWith(
      title: goal.title.trim(),
      savedAmount: goal.savedAmount.clamp(0, goal.targetAmount).toInt(),
    );
    await _changed();
  }

  Future<void> deleteSavingsGoal(String id) async {
    final before = savingsGoals.length;
    savingsGoals.removeWhere((item) => item.id == id);
    if (savingsGoals.length != before) await _changed();
  }

  Future<void> addUpcoming(UpcomingExpense expense) async {
    _upcomingExpenses.add(expense);
    await _changed();
  }

  Future<void> updateUpcoming(UpcomingExpense expense) async {
    final index = _upcomingExpenses.indexWhere((item) => item.id == expense.id);
    if (index < 0) return;
    _upcomingExpenses[index] = expense;
    await _changed();
  }

  Future<void> deleteUpcoming(String id) async {
    final before = _upcomingExpenses.length;
    _upcomingExpenses.removeWhere((expense) => expense.id == id);
    if (_upcomingExpenses.length != before) await _changed();
  }

  TransactionSeed _seedFromQesto(
    BudgetTransaction transaction, {
    int? exactMinor,
    String? providerTransactionId,
  }) {
    final direction = switch (transaction.type) {
      TransactionType.income ||
      TransactionType.refund => FinancialDirection.inflow,
      TransactionType.transfer =>
        transaction.transferDirection == null
            ? FinancialDirection.neutral
            : transaction.transferDirection == TransferDirection.incoming
            ? FinancialDirection.inflow
            : FinancialDirection.outflow,
      _ => FinancialDirection.outflow,
    };
    return TransactionSeed(
      canonicalId: transaction.id,
      accountId: transaction.accountId,
      amount: Money(
        minorUnits: exactMinor?.abs() ?? transaction.amount.abs() * 100,
        currency: transaction.currency,
      ),
      direction: direction,
      occurredAt: transaction.date,
      description:
          transaction.description ??
          transaction.comment ??
          transaction.title ??
          transaction.merchant ??
          '',
      merchant:
          transaction.merchant ??
          transaction.normalizedMerchant ??
          transaction.title,
      providerCategory: transaction.originalCategoryId,
      category: transaction.categoryId,
      subcategoryId: transaction.subcategoryId,
      providerTransactionId: providerTransactionId ?? transaction.id,
      receiptId: transaction.receipt?.id,
      transferDirection: transaction.transferDirection?.name,
      tags: {
        ...transaction.tags,
        'legacy-type-${transaction.type.name}',
        if (transaction.type == TransactionType.refund) 'refund',
        if (transaction.isPotentialDuplicate) 'qesto-potential-duplicate',
        if (transaction.isLargePurchase) 'qesto-large-purchase',
        if (!transaction.isConfirmed) 'qesto-unconfirmed',
        if (transaction.isRecurring) 'qesto-recurring',
      }.toList(),
      confidence: transaction.classificationConfidence,
    );
  }

  IngestionOutcome _ingestReceipt(
    BudgetTransaction transaction, {
    required String rawPayload,
    required String rawText,
  }) {
    final receipt = transaction.receipt;
    if (receipt == null) {
      throw ArgumentError.value(transaction, 'transaction', 'Receipt required');
    }
    final fingerprint =
        '${receipt.fiscalDriveNumber}:'
        '${receipt.fiscalDocumentNumber}:${receipt.fiscalSign}';
    return _synoball.ingest(
      ReceiptAdapter(),
      ReceiptInput(
        entityId: _legacyBridge.entityIdFor(_userId),
        receivedAt: DateTime.now(),
        rawPayload: rawPayload,
        transaction: _seedFromQesto(
          transaction,
          exactMinor: receipt.totalMinor,
          providerTransactionId: fingerprint,
        ),
        fiscalFingerprint: fingerprint,
        rawText: rawText,
        merchant: receipt.merchant ?? transaction.merchant,
        items: receipt.items
            .map(
              (item) => ReceiptItem(
                name: item.name,
                quantity: item.quantity,
                unitPrice: item.unitPriceMinor == null
                    ? null
                    : Money(
                        minorUnits: item.unitPriceMinor!,
                        currency: transaction.currency,
                      ),
                total: Money(
                  minorUnits: item.totalMinor,
                  currency: transaction.currency,
                ),
              ),
            )
            .toList(growable: false),
        confidence: transaction.classificationConfidence,
      ),
    );
  }
}

class _SberAccountReconciliation {
  const _SberAccountReconciliation({
    required this.sourceToCanonical,
    required this.duplicateToPrimary,
  });

  final Map<String, String> sourceToCanonical;
  final Map<String, String> duplicateToPrimary;
}
