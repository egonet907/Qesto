import 'package:flutter_test/flutter_test.dart';
import 'package:qesto/data/models/qesto_models.dart';
import 'package:qesto/features/budget/services/cash_flow_calculation_service.dart';
import 'package:qesto/features/capital/domain/account_capital_service.dart';
import 'package:qesto/synoball/core/models.dart';

void main() {
  const service = AccountCapitalService();
  final asOf = DateTime(2026, 9, 2);

  QestoAccount account(
    String id,
    int balance, {
    AccountType type = AccountType.bankCard,
    String currency = 'RUB',
  }) => QestoAccount(
    id: id,
    userId: 'user-1',
    title: id,
    balance: balance,
    currency: currency,
    type: type,
  );

  BudgetTransaction transaction({
    required String id,
    required String accountId,
    required DateTime date,
    required int amount,
    required TransactionType type,
    TransferDirection? transferDirection,
    String? categoryId,
    String currency = 'RUB',
    List<String> tags = const [],
  }) => BudgetTransaction(
    id: id,
    userId: 'user-1',
    accountId: accountId,
    date: date,
    amount: amount,
    currency: currency,
    type: type,
    transferDirection: transferDirection,
    categoryId: categoryId,
    tags: tags,
  );

  AccountCapitalSnapshot calculate({
    required List<QestoAccount> accounts,
    List<QestoAccountPreferences> preferences = const [],
    List<BudgetTransaction> transactions = const [],
    List<SavingsGoal> goals = const [],
  }) => service.calculate(
    accounts: accounts,
    accountPreferences: preferences,
    transactions: transactions,
    upcomingExpenses: const [],
    savingsGoals: goals,
    synoballState: const SynoballState(),
    asOf: asOf,
    period: CapitalPeriod.oneMonth,
    baseCurrency: 'RUB',
  );

  test('internal transfer does not change aggregate liquid balance trend', () {
    final result = calculate(
      accounts: [account('sber', 40000), account('tbank', 50000)],
      transactions: [
        transaction(
          id: 'transfer-out',
          accountId: 'sber',
          date: DateTime(2026, 8, 20),
          amount: 50000,
          type: TransactionType.transfer,
          transferDirection: TransferDirection.outgoing,
        ),
        transaction(
          id: 'transfer-in',
          accountId: 'tbank',
          date: DateTime(2026, 8, 20),
          amount: 50000,
          type: TransactionType.transfer,
          transferDirection: TransferDirection.incoming,
        ),
        transaction(
          id: 'shop',
          accountId: 'sber',
          date: DateTime(2026, 8, 25),
          amount: 10000,
          type: TransactionType.expense,
          categoryId: 'groceries',
        ),
      ],
    );

    expect(result.totalLiquidAssets, 90000);
    expect(result.change, -10000);
    expect(result.history.first.balance, 100000);
    expect(result.history.last.balance, 90000);
    expect(result.accounts.first.internalTransfers, -50000);
    expect(result.accounts.last.internalTransfers, 50000);
  });

  test('external person transfers change liquid capital and account flow', () {
    final result = calculate(
      accounts: [account('card', 16000)],
      transactions: [
        transaction(
          id: 'person-in',
          accountId: 'card',
          date: DateTime(2026, 8, 20),
          amount: 10000,
          type: TransactionType.transfer,
          transferDirection: TransferDirection.incoming,
          tags: const [qestoExternalTransferTag],
        ),
        transaction(
          id: 'person-out',
          accountId: 'card',
          date: DateTime(2026, 8, 25),
          amount: 4000,
          type: TransactionType.transfer,
          transferDirection: TransferDirection.outgoing,
          tags: const [qestoExternalTransferTag],
        ),
      ],
    );

    expect(result.change, 6000);
    expect(result.history.first.balance, 10000);
    expect(result.accounts.single.inflow, 10000);
    expect(result.accounts.single.outflow, 4000);
    expect(result.accounts.single.internalTransfers, 0);
  });

  test('liquid currencies are converted while investments are excluded', () {
    final result = calculate(
      accounts: [
        account('rub', 1000),
        account('usd', 10, currency: 'USD'),
        account('broker', 500000, type: AccountType.investment),
      ],
    );

    expect(result.totalLiquidAssets, 1829);
    expect(result.excludedNonLiquidAccounts, 1);
    expect(result.hasUnconvertedCurrencies, isFalse);
  });

  test('closed and excluded accounts do not inflate available money', () {
    final result = calculate(
      accounts: [account('active', 10000), account('closed', 20000)],
      preferences: const [
        QestoAccountPreferences(
          accountId: 'closed',
          role: QestoAccountRole.savings,
          isClosed: true,
        ),
      ],
    );

    expect(result.totalLiquidAssets, 10000);
  });

  test('emergency fund remains unconfigured without selected accounts', () {
    final result = calculate(accounts: [account('card', 10000)]);

    expect(result.emergencyAccountCount, 0);
    expect(result.emergencyFundAmount, 0);
    expect(result.emergencyFundMonths, isNull);
  });

  test(
    'emergency fund uses selected accounts and essential spending history',
    () {
      final expenses = <BudgetTransaction>[
        for (var index = 0; index < 6; index++)
          transaction(
            id: 'essential-$index',
            accountId: 'card',
            date: DateTime(2026, 7, 5 + index * 8),
            amount: 5000,
            type: TransactionType.expense,
            categoryId: 'groceries',
          ),
      ];
      final result = calculate(
        accounts: [
          account('card', 10000),
          account('reserve', 60000, type: AccountType.savings),
        ],
        transactions: expenses,
        goals: [
          SavingsGoal(
            id: 'goal',
            userId: 'user-1',
            title: 'Подушка безопасности',
            targetAmount: 120000,
            savedAmount: 0,
            currency: 'RUB',
            streakWeeks: 0,
            isActive: true,
            history: const [],
            category: 'Финансовая подушка',
          ),
        ],
      );

      expect(result.emergencyFundAmount, 60000);
      expect(result.averageEssentialMonthlyExpenses, isNotNull);
      expect(result.emergencyFundMonths, isNotNull);
      expect(result.emergencyGoal?.targetAmount, 120000);
    },
  );
}
