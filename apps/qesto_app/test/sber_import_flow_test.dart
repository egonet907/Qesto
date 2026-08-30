import 'package:flutter_test/flutter_test.dart';
import 'package:qesto/data/models/qesto_models.dart';
import 'package:qesto/features/bank_browser/sber/sber_connector_models.dart';
import 'package:qesto/features/budget/services/cash_flow_calculation_service.dart';
import 'package:qesto/features/budget/state/budget_controller.dart';
import 'package:qesto/mocks/fixtures/budget_categories.dart';

void main() {
  BudgetController controllerWith(BudgetTransaction transaction) =>
      BudgetController(
        configuration: budgetConfiguration,
        financialData: UserFinancialData(
          user: const QestoUser(
            id: 'user',
            name: 'Пользователь',
            defaultCurrency: 'RUB',
          ),
          referenceDate: DateTime(2026, 8, 31),
          transactions: [transaction],
        ),
      );

  BudgetTransaction existing({List<String> tags = const ['sberbank']}) =>
      BudgetTransaction(
        id: 'sber-stable-fingerprint',
        userId: 'user',
        accountId: 'local-default-account',
        date: DateTime(2026, 8, 20),
        amount: 83,
        currency: 'RUB',
        type: TransactionType.expense,
        categoryId: 'other',
        merchant: '+6',
        title: '+6',
        description: '+6 83 ₽ Оплата товаров и услуг',
        tags: tags,
      );

  SberSyncSnapshot snapshot({
    String merchant = 'Scooters',
    bool isIncome = false,
    bool isTransfer = false,
    bool isInternalTransfer = false,
    String status = 'POSTED',
  }) => SberSyncSnapshot(
    observedAt: DateTime(2026, 8, 31),
    accounts: const [],
    transactions: [
      SberTransactionFact(
        sourceId: 'source',
        accountId: '',
        date: DateTime(2026, 8, 20),
        amount: 83,
        currency: 'RUB',
        description: '$merchant · Оплата товаров и услуг',
        merchant: merchant,
        operationType: 'Оплата товаров и услуг',
        status: status,
        fingerprint: 'stable-fingerprint',
        isIncome: isIncome,
        isTransfer: isTransfer,
        isInternalTransfer: isInternalTransfer,
      ),
    ],
    oldestTransaction: DateTime(2026, 8, 20),
    newestTransaction: DateTime(2026, 8, 20),
    pendingCount: 0,
    pageType: SberPageType.transactions,
  );

  test(
    'repeat sync repairs merchant and category without a duplicate',
    () async {
      final controller = controllerWith(existing());

      final result = await controller.importSberSnapshot(snapshot());

      expect(controller.transactions, hasLength(1));
      expect(controller.transactions.single.merchant, 'Scooters');
      expect(controller.transactions.single.categoryId, 'transport');
      expect(result.newCount, 0);
      expect(result.updatedCount, 1);
      expect(result.recategorizedCount, 1);
    },
  );

  test('manual category override survives adapter refresh', () async {
    final manual = existing(
      tags: const ['sberbank', qestoManualCategoryTag],
    ).copyWith(categoryId: 'fun');
    final controller = controllerWith(manual);

    await controller.importSberSnapshot(snapshot());

    expect(controller.transactions.single.categoryId, 'fun');
    expect(
      controller.transactions.single.tags,
      contains(qestoManualCategoryTag),
    );
  });

  test(
    'external and internal Sber transfers receive distinct semantics',
    () async {
      final controller = controllerWith(existing());
      final base = snapshot();
      final transferSnapshot = SberSyncSnapshot(
        observedAt: base.observedAt,
        accounts: const [],
        transactions: [
          SberTransactionFact(
            sourceId: 'incoming',
            accountId: '',
            date: DateTime(2026, 8, 21),
            amount: 10000,
            currency: 'RUB',
            description: 'Перевод от другого человека',
            status: 'POSTED',
            fingerprint: 'incoming',
            isIncome: true,
            isTransfer: true,
          ),
          SberTransactionFact(
            sourceId: 'outgoing',
            accountId: '',
            date: DateTime(2026, 8, 22),
            amount: 4000,
            currency: 'RUB',
            description: 'Перевод по СБП',
            status: 'POSTED',
            fingerprint: 'outgoing',
            isTransfer: true,
          ),
          SberTransactionFact(
            sourceId: 'internal',
            accountId: '',
            date: DateTime(2026, 8, 23),
            amount: 20000,
            currency: 'RUB',
            description: 'Перевод между своими счетами',
            status: 'POSTED',
            fingerprint: 'internal',
            isTransfer: true,
            isInternalTransfer: true,
          ),
        ],
        oldestTransaction: DateTime(2026, 8, 21),
        newestTransaction: DateTime(2026, 8, 23),
        pendingCount: 0,
        pageType: SberPageType.transactions,
      );

      await controller.importSberSnapshot(transferSnapshot);

      final incoming = controller.transactions.firstWhere(
        (item) => item.id == 'sber-incoming',
      );
      final outgoing = controller.transactions.firstWhere(
        (item) => item.id == 'sber-outgoing',
      );
      final internal = controller.transactions.firstWhere(
        (item) => item.id == 'sber-internal',
      );
      expect(incoming.type, TransactionType.income);
      expect(incoming.tags, contains(qestoExternalTransferTag));
      expect(outgoing.type, TransactionType.expense);
      expect(outgoing.tags, contains(qestoExternalTransferTag));
      expect(internal.type, TransactionType.transfer);
      expect(internal.tags, contains(qestoInternalTransferTag));
    },
  );
}
