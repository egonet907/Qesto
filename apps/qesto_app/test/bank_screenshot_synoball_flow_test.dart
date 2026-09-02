import 'package:flutter_test/flutter_test.dart';
import 'package:qesto/data/models/qesto_models.dart';
import 'package:qesto/features/bank_screenshot_import/domain/bank_screenshot_models.dart';
import 'package:qesto/features/budget/state/budget_controller.dart';
import 'package:qesto/mocks/fixtures/budget_categories.dart';
import 'package:qesto/synoball/synoball.dart';

void main() {
  test(
    'confirmed screenshot candidates enter the canonical Synoball pipeline',
    () async {
      final controller = BudgetController(
        configuration: budgetConfiguration,
        financialData: UserFinancialData(
          user: const QestoUser(
            id: 'screenshot-user',
            name: 'Screenshot test',
            defaultCurrency: 'RUB',
          ),
          referenceDate: DateTime(2026, 8, 31),
          accounts: const [
            QestoAccount(
              id: 'sber-card',
              userId: 'screenshot-user',
              title: 'Сбер •• 1234',
              balance: 2265,
              currency: 'RUB',
              type: AccountType.bankCard,
            ),
          ],
        ),
      );
      final candidate = BankScreenshotCandidate(
        id: 'bank-shot-stable-1',
        imageHash: 'sha256-redacted',
        parserId: 'sber-mobile-history-v1',
        merchant: 'BPA 629 KHIMKI RUS',
        amountMinor: 70000,
        currency: 'RUB',
        date: DateTime(2026, 8, 31),
        kind: BankScreenshotTransactionKind.expense,
        categoryId: 'other',
        confidence: 0.82,
        accountId: 'sber-card',
        balanceAfterMinor: 226530,
      );

      final first = await controller.importBankScreenshotCandidates([
        candidate,
      ]);
      final second = await controller.importBankScreenshotCandidates([
        candidate,
      ]);

      expect(first.createdTransactionIds, hasLength(1));
      expect(second.createdTransactionIds, isEmpty);
      expect(second.matchedTransactionIds, hasLength(1));
      expect(
        controller.synoballState.evidence.last.sourceType,
        SynoballSourceType.bankScreenshot,
      );
      final payload = controller.synoballState.rawPayloads.last;
      expect(payload.redacted, isTrue);
      expect(payload.body, isNot(contains('BPA 629')));
      expect(controller.transactions.single.amount, 700);
    },
  );
}
