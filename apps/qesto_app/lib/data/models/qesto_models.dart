export 'budget_models.dart';

import 'budget_models.dart';
import '../../synoball/core/models.dart';

enum AccountType {
  cash,
  bankCard,
  savings,
  deposit,
  investment,
  receivable,
  liability,
  other,
}

enum QestoAccountRole {
  everyday,
  emergency,
  savings,
  salary,
  mandatoryPayments,
  other,
}

/// User-owned account metadata. It intentionally lives outside Synoball:
/// changing how Qesto presents or analyses an account must not mutate the
/// canonical bank account received from an adapter.
class QestoAccountPreferences {
  const QestoAccountPreferences({
    required this.accountId,
    required this.role,
    this.includeInTotal = true,
    this.includeInNetWorth = true,
    this.includeInEmergencyFund = false,
    this.isVisible = true,
    this.includeTransactionsInAnalytics = true,
    this.isClosed = false,
  });

  final String accountId;
  final QestoAccountRole role;
  final bool includeInTotal;
  final bool includeInNetWorth;
  final bool includeInEmergencyFund;
  final bool isVisible;
  final bool includeTransactionsInAnalytics;
  final bool isClosed;

  QestoAccountPreferences copyWith({
    QestoAccountRole? role,
    bool? includeInTotal,
    bool? includeInNetWorth,
    bool? includeInEmergencyFund,
    bool? isVisible,
    bool? includeTransactionsInAnalytics,
    bool? isClosed,
  }) => QestoAccountPreferences(
    accountId: accountId,
    role: role ?? this.role,
    includeInTotal: includeInTotal ?? this.includeInTotal,
    includeInNetWorth: includeInNetWorth ?? this.includeInNetWorth,
    includeInEmergencyFund:
        includeInEmergencyFund ?? this.includeInEmergencyFund,
    isVisible: isVisible ?? this.isVisible,
    includeTransactionsInAnalytics:
        includeTransactionsInAnalytics ?? this.includeTransactionsInAnalytics,
    isClosed: isClosed ?? this.isClosed,
  );
}

enum DealKind { coupon, promotion }

enum FinancialActionType { statementImport, transactionAdded }

class QestoUser {
  const QestoUser({
    required this.id,
    required this.name,
    required this.defaultCurrency,
    this.avatarUrl,
    this.expenseDisplayCurrency = 'RUB',
  });

  final String id;
  final String name;
  final String defaultCurrency;
  final String? avatarUrl;
  final String expenseDisplayCurrency;

  QestoUser copyWith({
    String? name,
    String? defaultCurrency,
    String? avatarUrl,
    String? expenseDisplayCurrency,
    bool clearAvatar = false,
  }) => QestoUser(
    id: id,
    name: name ?? this.name,
    defaultCurrency: defaultCurrency ?? this.defaultCurrency,
    avatarUrl: clearAvatar ? null : avatarUrl ?? this.avatarUrl,
    expenseDisplayCurrency:
        expenseDisplayCurrency ?? this.expenseDisplayCurrency,
  );
}

class QestoAccount {
  const QestoAccount({
    required this.id,
    required this.userId,
    required this.title,
    required this.balance,
    required this.currency,
    required this.type,
  });

  final String id;
  final String userId;
  final String title;
  final int balance;
  final String currency;
  final AccountType type;
}

class Deal {
  const Deal({
    required this.id,
    required this.userId,
    required this.kind,
    required this.category,
    required this.title,
    required this.description,
    required this.visualKey,
    this.badge,
    this.promoCode,
    this.merchantName,
    this.targetUrl,
    this.sourceUrl,
    this.discountType,
    this.discountValue,
    this.minimumOrder,
    this.maximumDiscount,
    this.customerType,
    this.validUntil,
    this.confidence,
  });

  final String id;
  final String userId;
  final DealKind kind;
  final String category;
  final String title;
  final String description;
  final String visualKey;
  final String? badge;
  final String? promoCode;
  final String? merchantName;
  final String? targetUrl;
  final String? sourceUrl;
  final String? discountType;
  final int? discountValue;
  final int? minimumOrder;
  final int? maximumDiscount;
  final String? customerType;
  final DateTime? validUntil;
  final int? confidence;
}

class TrackedProduct {
  const TrackedProduct({
    required this.id,
    required this.userId,
    required this.title,
    required this.currentPrice,
    required this.currency,
    required this.bestMarketplace,
    required this.changePercent,
    required this.trackedStoresCount,
    required this.visualKey,
  });

  final String id;
  final String userId;
  final String title;
  final int currentPrice;
  final String currency;
  final String bestMarketplace;
  final double changePercent;
  final int trackedStoresCount;
  final String visualKey;
}

class SavingsHistoryPoint {
  const SavingsHistoryPoint({required this.date, required this.amount});

  final DateTime date;
  final int amount;
}

class SavingsGoal {
  const SavingsGoal({
    required this.id,
    required this.userId,
    required this.title,
    required this.targetAmount,
    required this.savedAmount,
    required this.currency,
    required this.streakWeeks,
    required this.isActive,
    required this.history,
    this.category = 'Другое',
    this.targetDate,
  });

  final String id;
  final String userId;
  final String title;
  final int targetAmount;
  final int savedAmount;
  final String currency;
  final int streakWeeks;
  final bool isActive;
  final List<SavingsHistoryPoint> history;
  final String category;
  final DateTime? targetDate;

  double get progress => targetAmount == 0 ? 0 : savedAmount / targetAmount;

  SavingsGoal copyWith({
    String? title,
    int? targetAmount,
    int? savedAmount,
    String? currency,
    int? streakWeeks,
    bool? isActive,
    List<SavingsHistoryPoint>? history,
    String? category,
    DateTime? targetDate,
  }) => SavingsGoal(
    id: id,
    userId: userId,
    title: title ?? this.title,
    targetAmount: targetAmount ?? this.targetAmount,
    savedAmount: savedAmount ?? this.savedAmount,
    currency: currency ?? this.currency,
    streakWeeks: streakWeeks ?? this.streakWeeks,
    isActive: isActive ?? this.isActive,
    history: history ?? this.history,
    category: category ?? this.category,
    targetDate: targetDate ?? this.targetDate,
  );
}

class FinancialAction {
  const FinancialAction({
    required this.id,
    required this.occurredAt,
    required this.title,
    required this.type,
    this.createdTransactionIds = const [],
    this.createdAccountIds = const [],
    this.createdPeriodIds = const [],
    this.previousTransactions = const [],
    this.previousAccounts = const [],
    this.isUndone = false,
  });

  final String id;
  final DateTime occurredAt;
  final String title;
  final FinancialActionType type;
  final List<String> createdTransactionIds;
  final List<String> createdAccountIds;
  final List<String> createdPeriodIds;
  final List<BudgetTransaction> previousTransactions;
  final List<QestoAccount> previousAccounts;
  final bool isUndone;

  FinancialAction copyWith({bool? isUndone}) => FinancialAction(
    id: id,
    occurredAt: occurredAt,
    title: title,
    type: type,
    createdTransactionIds: createdTransactionIds,
    createdAccountIds: createdAccountIds,
    createdPeriodIds: createdPeriodIds,
    previousTransactions: previousTransactions,
    previousAccounts: previousAccounts,
    isUndone: isUndone ?? this.isUndone,
  );
}

class QestoAppData {
  const QestoAppData({
    required this.budgetConfiguration,
    required this.financialData,
    required this.coupons,
    required this.promotions,
  });

  final BudgetConfiguration budgetConfiguration;
  final UserFinancialData financialData;
  final List<Deal> coupons;
  final List<Deal> promotions;
}

class UserFinancialData {
  const UserFinancialData({
    required this.user,
    required this.referenceDate,
    this.accounts = const [],
    this.accountPreferences = const [],
    this.budgetPeriods = const [],
    this.categoryBudgets = const [],
    this.categoryCustomizations = const [],
    this.transactions = const [],
    this.upcomingExpenses = const [],
    this.plannedCumulativePoints = const [],
    this.savingsGoals = const [],
    this.trackedProducts = const [],
    this.actions = const [],
    this.synoballState,
  });

  final QestoUser user;
  final DateTime referenceDate;
  final List<QestoAccount> accounts;
  final List<QestoAccountPreferences> accountPreferences;
  final List<BudgetPeriod> budgetPeriods;
  final List<CategoryBudget> categoryBudgets;
  final List<BudgetCategoryCustomization> categoryCustomizations;
  final List<BudgetTransaction> transactions;
  final List<UpcomingExpense> upcomingExpenses;
  final List<BudgetPlanPoint> plannedCumulativePoints;
  final List<SavingsGoal> savingsGoals;
  final List<TrackedProduct> trackedProducts;
  final List<FinancialAction> actions;
  final SynoballState? synoballState;

  UserFinancialData copyWith({
    QestoUser? user,
    DateTime? referenceDate,
    List<QestoAccount>? accounts,
    List<QestoAccountPreferences>? accountPreferences,
    List<BudgetPeriod>? budgetPeriods,
    List<CategoryBudget>? categoryBudgets,
    List<BudgetCategoryCustomization>? categoryCustomizations,
    List<BudgetTransaction>? transactions,
    List<UpcomingExpense>? upcomingExpenses,
    List<BudgetPlanPoint>? plannedCumulativePoints,
    List<SavingsGoal>? savingsGoals,
    List<TrackedProduct>? trackedProducts,
    List<FinancialAction>? actions,
    SynoballState? synoballState,
  }) {
    return UserFinancialData(
      user: user ?? this.user,
      referenceDate: referenceDate ?? this.referenceDate,
      accounts: accounts ?? this.accounts,
      accountPreferences: accountPreferences ?? this.accountPreferences,
      budgetPeriods: budgetPeriods ?? this.budgetPeriods,
      categoryBudgets: categoryBudgets ?? this.categoryBudgets,
      categoryCustomizations:
          categoryCustomizations ?? this.categoryCustomizations,
      transactions: transactions ?? this.transactions,
      upcomingExpenses: upcomingExpenses ?? this.upcomingExpenses,
      plannedCumulativePoints:
          plannedCumulativePoints ?? this.plannedCumulativePoints,
      savingsGoals: savingsGoals ?? this.savingsGoals,
      trackedProducts: trackedProducts ?? this.trackedProducts,
      actions: actions ?? this.actions,
      synoballState: synoballState ?? this.synoballState,
    );
  }
}
