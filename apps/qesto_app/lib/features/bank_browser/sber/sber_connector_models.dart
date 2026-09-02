import '../../../data/models/qesto_models.dart';

enum SberConnectorState {
  closed,
  checkingAuth,
  authenticated,
  pinRequired,
  fullLoginRequired,
  syncingProducts,
  syncingTransactions,
  syncComplete,
  syncPartial,
  error,
}

enum SberPageType {
  login,
  pinLogin,
  dashboard,
  accounts,
  accountDetails,
  transactions,
  savings,
  deposit,
  investments,
  unknown,
}

enum SberTransactionDirection { inflow, outflow }

class SberSyncRange {
  const SberSyncRange({
    required this.from,
    required this.toExclusive,
    required this.label,
  });

  factory SberSyncRange.currentMonth([DateTime? clock]) {
    final now = clock ?? DateTime.now();
    return SberSyncRange(
      from: DateTime(now.year, now.month),
      toExclusive: DateTime(now.year, now.month, now.day + 1),
      label: 'Текущий месяц',
    );
  }

  final DateTime from;
  final DateTime toExclusive;
  final String label;

  bool contains(DateTime value) =>
      !value.isBefore(from) && value.isBefore(toExclusive);
}

class SberLoyaltyReward {
  const SberLoyaltyReward({
    required this.amount,
    this.program = 'SBER_SPASIBO',
  });

  final double amount;
  final String program;
}

class SberAccountFact {
  const SberAccountFact({
    required this.id,
    required this.name,
    required this.type,
    required this.currency,
    required this.balance,
    this.availableBalance,
    this.lastFour,
    this.linkedCardLastFours = const [],
    this.isLiability = false,
  });

  final String id;
  final String name;
  final AccountType type;
  final String currency;
  final int balance;
  final int? availableBalance;
  final String? lastFour;
  final List<String> linkedCardLastFours;
  final bool isLiability;
}

class SberTransactionFact {
  const SberTransactionFact({
    required this.sourceId,
    required this.accountId,
    required this.date,
    required this.amount,
    required this.currency,
    required this.description,
    required this.status,
    required this.fingerprint,
    this.merchant,
    this.category,
    this.isTransfer = false,
    this.isIncome = false,
    this.isInternalTransfer = false,
    this.operationType,
    this.loyaltyReward,
  });

  final String sourceId;
  final String accountId;
  final DateTime date;
  final int amount;
  final String currency;
  final String description;
  final String status;
  final String fingerprint;
  final String? merchant;
  final String? category;
  final bool isTransfer;
  final bool isIncome;
  final bool isInternalTransfer;
  final String? operationType;
  final SberLoyaltyReward? loyaltyReward;

  SberTransactionDirection get direction => isIncome
      ? SberTransactionDirection.inflow
      : SberTransactionDirection.outflow;
}

class SberTransactionExtraction {
  const SberTransactionExtraction({
    this.transactions = const [],
    this.rawRowsSeen = 0,
    this.rejectedRows = 0,
    this.scrollSteps = 0,
    this.loadMoreClicks = 0,
    this.rewardRows = 0,
    this.serviceRows = 0,
    this.loyaltyRewards = 0,
    this.rangeBoundaryReached = false,
    this.hasMoreRows = false,
  });

  final List<SberTransactionFact> transactions;
  final int rawRowsSeen;
  final int rejectedRows;
  final int scrollSteps;
  final int loadMoreClicks;
  final int rewardRows;
  final int serviceRows;
  final int loyaltyRewards;
  final bool rangeBoundaryReached;
  final bool hasMoreRows;
}

class SberSyncSnapshot {
  const SberSyncSnapshot({
    required this.observedAt,
    required this.accounts,
    required this.transactions,
    required this.oldestTransaction,
    required this.newestTransaction,
    required this.pendingCount,
    required this.pageType,
    this.historyRowsSeen = 0,
    this.historyRowsAccepted = 0,
    this.historyRowsRejected = 0,
    this.historyScrollSteps = 0,
    this.historyLoadMoreClicks = 0,
    this.historyRewardRows = 0,
    this.historyServiceRows = 0,
    this.historyLoyaltyRewards = 0,
    this.historyRangeBoundaryReached = false,
    this.historyHasMoreRows = false,
  });

  final DateTime observedAt;
  final List<SberAccountFact> accounts;
  final List<SberTransactionFact> transactions;
  final DateTime? oldestTransaction;
  final DateTime? newestTransaction;
  final int pendingCount;
  final SberPageType pageType;
  final int historyRowsSeen;
  final int historyRowsAccepted;
  final int historyRowsRejected;
  final int historyScrollSteps;
  final int historyLoadMoreClicks;
  final int historyRewardRows;
  final int historyServiceRows;
  final int historyLoyaltyRewards;
  final bool historyRangeBoundaryReached;
  final bool historyHasMoreRows;
}

class SberSyncReport {
  const SberSyncReport({
    required this.state,
    this.snapshot,
    this.message,
    this.pinAttempted = false,
  });

  final SberConnectorState state;
  final SberSyncSnapshot? snapshot;
  final String? message;
  final bool pinAttempted;
}

/// Local reconciliation counters shown after a manual sync.  It contains
/// counts only; no balances, merchants, or other bank payload is persisted in
/// the diagnostic result.
class SberImportSummary {
  const SberImportSummary({
    required this.found,
    required this.newCount,
    required this.updatedCount,
    required this.unchangedCount,
    required this.accountsFound,
    required this.accountsUpdated,
    this.accountsMerged = 0,
    this.accounts = const [],
    this.transactions = const [],
    this.recategorizedCount = 0,
  });

  final int found;
  final int newCount;
  final int updatedCount;
  final int unchangedCount;
  final int accountsFound;
  final int accountsUpdated;
  final int accountsMerged;
  final List<SberAccountImportItem> accounts;
  final List<SberTransactionImportItem> transactions;
  final int recategorizedCount;
}

enum SberImportChange { created, updated, unchanged }

class SberAccountImportItem {
  const SberAccountImportItem({
    required this.title,
    required this.balance,
    required this.currency,
    required this.change,
  });

  final String title;
  final int balance;
  final String currency;
  final SberImportChange change;
}

class SberTransactionImportItem {
  const SberTransactionImportItem({
    required this.title,
    required this.date,
    required this.amount,
    required this.currency,
    required this.isIncome,
    required this.isTransfer,
    required this.change,
  });

  final String title;
  final DateTime date;
  final int amount;
  final String currency;
  final bool isIncome;
  final bool isTransfer;
  final SberImportChange change;
}
