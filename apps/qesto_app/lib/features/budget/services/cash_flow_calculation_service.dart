import '../../../data/models/qesto_models.dart';

const qestoInternalTransferTag = 'qesto-internal-transfer';
const qestoExternalTransferTag = 'qesto-external-transfer';
const qestoLoyaltyMetadataTag = 'qesto-loyalty-metadata';
const qestoManualCategoryTag = 'qesto-manual-category';
const qestoAutoCategoryTag = 'qesto-auto-category';

enum CashFlowTreatment {
  externalInflow,
  externalOutflow,
  internalTransfer,
  ignored,
}

class QestoCashFlowSummary {
  const QestoCashFlowSummary({
    required this.periodStart,
    required this.periodEndExclusive,
    required this.externalInflows,
    required this.externalOutflows,
    required this.internalTransferInflows,
    required this.internalTransferOutflows,
    required this.ignoredTransactions,
  });

  final DateTime periodStart;
  final DateTime periodEndExclusive;
  final int externalInflows;
  final int externalOutflows;
  final int internalTransferInflows;
  final int internalTransferOutflows;
  final int ignoredTransactions;

  int get netCashFlow => externalInflows - externalOutflows;
  int get internalTransfersExcluded =>
      internalTransferInflows + internalTransferOutflows;
}

class CashFlowCalculationService {
  const CashFlowCalculationService();

  QestoCashFlowSummary calculate({
    required Iterable<BudgetTransaction> transactions,
    required DateTime from,
    required DateTime toExclusive,
    String? currency,
  }) {
    var inflows = 0;
    var outflows = 0;
    var internalInflows = 0;
    var internalOutflows = 0;
    var ignored = 0;
    for (final transaction in transactions) {
      if (transaction.date.isBefore(from) ||
          !transaction.date.isBefore(toExclusive) ||
          (currency != null && transaction.currency != currency)) {
        continue;
      }
      switch (treatment(transaction)) {
        case CashFlowTreatment.externalInflow:
          inflows += transaction.amount;
        case CashFlowTreatment.externalOutflow:
          outflows += transaction.amount;
        case CashFlowTreatment.internalTransfer:
          if (transaction.transferDirection == TransferDirection.incoming) {
            internalInflows += transaction.amount;
          } else {
            internalOutflows += transaction.amount;
          }
        case CashFlowTreatment.ignored:
          ignored += 1;
      }
    }
    return QestoCashFlowSummary(
      periodStart: from,
      periodEndExclusive: toExclusive,
      externalInflows: inflows,
      externalOutflows: outflows,
      internalTransferInflows: internalInflows,
      internalTransferOutflows: internalOutflows,
      ignoredTransactions: ignored,
    );
  }

  CashFlowTreatment treatment(BudgetTransaction transaction) {
    if ((transaction.isPotentialDuplicate && !transaction.isConfirmed) ||
        transaction.tags.contains('sber-status-pending') ||
        transaction.tags.contains('sber-status-cancelled') ||
        transaction.tags.contains('qesto-non-cash') ||
        transaction.tags.contains('sber-loyalty-only')) {
      return CashFlowTreatment.ignored;
    }
    if (transaction.tags.contains(qestoInternalTransferTag) ||
        transaction.type == TransactionType.savingsTransfer) {
      return CashFlowTreatment.internalTransfer;
    }
    return switch (transaction.type) {
      TransactionType.income ||
      TransactionType.refund => CashFlowTreatment.externalInflow,
      TransactionType.expense ||
      TransactionType.investment => CashFlowTreatment.externalOutflow,
      TransactionType.transfer => switch (transaction.transferDirection) {
        TransferDirection.incoming => CashFlowTreatment.externalInflow,
        TransferDirection.outgoing => CashFlowTreatment.externalOutflow,
        null => CashFlowTreatment.ignored,
      },
      TransactionType.savingsTransfer => CashFlowTreatment.internalTransfer,
    };
  }
}
