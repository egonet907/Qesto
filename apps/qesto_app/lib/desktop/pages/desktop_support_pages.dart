import 'package:flutter/material.dart';

import '../../core/formatters/qesto_formatters.dart';
import '../../core/theme/app_appearance_controller.dart';
import '../../core/theme/qesto_theme.dart';
import '../../data/models/qesto_models.dart';
import '../../features/budget/state/budget_controller.dart';
import '../../features/profile/services/cbr_currency_service.dart';
import '../../synoball/ai/context.dart';
import '../widgets/desktop_chrome.dart';
import '../widgets/desktop_components.dart';

class DesktopGoalsPage extends StatelessWidget {
  const DesktopGoalsPage({required this.controller, super.key});
  final BudgetController controller;

  static const categories = <String>[
    'Финансовая подушка',
    'Путешествие',
    'Крупная покупка',
    'Жильё',
    'Образование',
    'Другое',
  ];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final goals = controller.savingsGoals;
    if (goals.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(26, 20, 26, 30),
        children: [
          _GoalsHeader(onAdd: () => _openEditor(context)),
          const SizedBox(height: 16),
          DesktopEmptyState(
            title: 'Целей пока нет',
            message: 'Создайте цель, укажите сумму и дату завершения.',
            icon: Icons.flag_outlined,
            action: FilledButton.icon(
              onPressed: () => _openEditor(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Создать цель'),
            ),
          ),
        ],
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(26, 20, 26, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GoalsHeader(onAdd: () => _openEditor(context)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final goal in goals)
                SizedBox(
                  width: 350,
                  height: 252,
                  child: _GoalCard(
                    goal: goal,
                    onEdit: () => _openEditor(context, goal: goal),
                    onDelete: () => _delete(context, goal),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, {SavingsGoal? goal}) async {
    final title = TextEditingController(text: goal?.title ?? '');
    final target = TextEditingController(
      text: goal == null ? '' : goal.targetAmount.toString(),
    );
    final saved = TextEditingController(
      text: goal == null ? '0' : goal.savedAmount.toString(),
    );
    var category = goal?.category ?? categories.first;
    var targetDate =
        goal?.targetDate ?? DateTime.now().add(const Duration(days: 180));
    var currency = goal?.currency ?? controller.user.defaultCurrency;
    if (!const {'RUB', 'USD', 'EUR', 'CNY'}.contains(currency)) {
      currency = 'RUB';
    }
    String? error;
    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          key: const Key('goal-editor-dialog'),
          title: Text(goal == null ? 'Новая цель' : 'Редактировать цель'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('goal-title-field'),
                    controller: title,
                    decoration: const InputDecoration(
                      labelText: 'Название цели',
                      prefixIcon: Icon(Icons.flag_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('goal-category-field'),
                    initialValue: category,
                    decoration: const InputDecoration(
                      labelText: 'Категория',
                      prefixIcon: Icon(Icons.category_outlined),
                    ),
                    items: [
                      for (final item in categories)
                        DropdownMenuItem(value: item, child: Text(item)),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => category = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('goal-target-field'),
                          controller: target,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Цель'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          key: const Key('goal-saved-field'),
                          controller: saved,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Накоплено',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 110,
                        child: DropdownButtonFormField<String>(
                          key: const Key('goal-currency-field'),
                          initialValue: currency,
                          decoration: const InputDecoration(
                            labelText: 'Валюта',
                          ),
                          items: const [
                            DropdownMenuItem(value: 'RUB', child: Text('RUB')),
                            DropdownMenuItem(value: 'USD', child: Text('USD')),
                            DropdownMenuItem(value: 'EUR', child: Text('EUR')),
                            DropdownMenuItem(value: 'CNY', child: Text('CNY')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => currency = value);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    key: const Key('goal-date-field'),
                    onTap: () async {
                      final value = await showDatePicker(
                        context: context,
                        initialDate: targetDate,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(
                          const Duration(days: 3650),
                        ),
                      );
                      if (value != null) {
                        setDialogState(() => targetDate = value);
                      }
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Срок цели',
                        prefixIcon: Icon(Icons.event_outlined),
                      ),
                      child: Text(formatDate(targetDate, includeYear: true)),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      style: const TextStyle(color: QestoColors.danger),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const Key('goal-save-button'),
              onPressed: () {
                final targetAmount = _amount(target.text);
                final savedAmount = _amount(saved.text);
                if (title.text.trim().isEmpty || targetAmount <= 0) {
                  setDialogState(
                    () => error = 'Укажите название и сумму больше нуля',
                  );
                } else if (savedAmount > targetAmount) {
                  setDialogState(
                    () => error = 'Накоплено не может быть больше цели',
                  );
                } else {
                  Navigator.pop(dialogContext, true);
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (shouldSave == true) {
      if (goal == null) {
        await controller.addSavingsGoal(
          title: title.text,
          category: category,
          targetAmount: _amount(target.text),
          savedAmount: _amount(saved.text),
          targetDate: targetDate,
          currency: currency,
        );
      } else {
        await controller.updateSavingsGoal(
          goal.copyWith(
            title: title.text,
            category: category,
            targetAmount: _amount(target.text),
            savedAmount: _amount(saved.text),
            targetDate: targetDate,
            currency: currency,
          ),
        );
      }
    }
    // The dialog route may still be animating after its Future completes.
    // Keep field controllers alive until its widgets have left the tree.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    title.dispose();
    target.dispose();
    saved.dispose();
  }

  Future<void> _delete(BuildContext context, SavingsGoal goal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить цель?'),
        content: Text('«${goal.title}» будет удалена.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('goal-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.deleteSavingsGoal(goal.id);
  }

  int _amount(String value) =>
      int.tryParse(value.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
}

class _GoalsHeader extends StatelessWidget {
  const _GoalsHeader({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Финансовые цели',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            SizedBox(height: 4),
            Text(
              'Планируйте сумму и срок накопления',
              style: TextStyle(color: QestoColors.secondaryText),
            ),
          ],
        ),
      ),
      FilledButton.icon(
        key: const Key('goal-add-button'),
        onPressed: onAdd,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Новая цель'),
      ),
    ],
  );
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.goal,
    required this.onEdit,
    required this.onDelete,
  });
  final SavingsGoal goal;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => DesktopCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.flag_outlined, color: QestoColors.primary),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                goal.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            IconButton(
              key: Key('goal-edit-${goal.id}'),
              tooltip: 'Редактировать',
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, size: 18),
            ),
            IconButton(
              key: Key('goal-delete-${goal.id}'),
              tooltip: 'Удалить',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
            ),
          ],
        ),
        Text(
          goal.category,
          style: const TextStyle(
            color: QestoColors.primary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '${formatMoney(goal.savedAmount, goal.currency)} из ${formatMoney(goal.targetAmount, goal.currency)}',
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 12),
        DesktopProgressBar(
          value: goal.progress.clamp(0, 1).toDouble(),
          height: 8,
        ),
        const SizedBox(height: 8),
        Text(
          '${(goal.progress * 100).clamp(0, 100).round()}% накоплено',
          style: const TextStyle(
            color: QestoColors.secondaryText,
            fontSize: 11,
          ),
        ),
        const Spacer(),
        Row(
          children: [
            const Icon(
              Icons.event_outlined,
              size: 15,
              color: QestoColors.secondaryText,
            ),
            const SizedBox(width: 6),
            Text(
              goal.targetDate == null
                  ? 'Срок не задан'
                  : 'До ${formatDate(goal.targetDate!, includeYear: true)}',
              style: const TextStyle(
                color: QestoColors.secondaryText,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class DesktopInsightsPage extends StatelessWidget {
  const DesktopInsightsPage({required this.controller, super.key});
  final BudgetController controller;
  @override
  Widget build(BuildContext context) {
    final quality = controller.financialState.dataQuality;
    return ListView(
      padding: const EdgeInsets.fromLTRB(26, 20, 26, 30),
      children: [
        DesktopCard(
          color: const Color(0xFFF1F5FF),
          borderColor: const Color(0xFFDCE7FF),
          child: Row(
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                color: QestoColors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Финансовая картина',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      quality.overall >= 0.75
                          ? 'Хорошая'
                          : quality.overall >= 0.5
                          ? 'Частичная'
                          : 'Ограниченная',
                      style: const TextStyle(
                        color: QestoColors.primary,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${(quality.overall * 100).round()}% · ${quality.warnings.isEmpty ? 'критичных предупреждений нет' : quality.warnings.join(' · ')}',
                      style: const TextStyle(
                        color: QestoColors.secondaryText,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _InsightFeedCard(
          icon: Icons.trending_up_rounded,
          color: QestoColors.warning,
          title: 'Изменение расходов',
          message:
              'Qesto сравнивает категории и магазины только по каноническим операциям, исключая неподтверждённые дубли.',
        ),
        const SizedBox(height: 12),
        _InsightFeedCard(
          icon: Icons.event_repeat_outlined,
          color: QestoColors.purple,
          title: 'Новые регулярные операции',
          message:
              'Найдено ${controller.synoballState.recurringStreams.length} повторяющихся потоков. Прогнозы помечены как expected/inferred.',
        ),
        const SizedBox(height: 12),
        _InsightFeedCard(
          icon: Icons.shield_outlined,
          color: QestoColors.positive,
          title: 'Источники и provenance',
          message:
              '${controller.synoballState.evidence.length} evidence-записей поддерживают ${controller.synoballState.transactions.length} канонических транзакций.',
        ),
      ],
    );
  }
}

class _InsightFeedCard extends StatelessWidget {
  const _InsightFeedCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => DesktopCard(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 21),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                message,
                style: const TextStyle(
                  color: QestoColors.secondaryText,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const Icon(
          Icons.chevron_right_rounded,
          color: QestoColors.secondaryText,
        ),
      ],
    ),
  );
}

class DesktopAssistantPage extends StatefulWidget {
  const DesktopAssistantPage({required this.controller, super.key});
  final BudgetController controller;
  @override
  State<DesktopAssistantPage> createState() => _DesktopAssistantPageState();
}

class _DesktopAssistantPageState extends State<DesktopAssistantPage> {
  final _messages = <String>[];
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.financialState;
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 20, 26, 28),
      child: Row(
        children: [
          SizedBox(
            width: 285,
            child: DesktopCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const DesktopSectionHeader(
                    title: 'Финансовый контекст',
                    subtitle: 'Передаётся AI по задаче',
                  ),
                  const SizedBox(height: 18),
                  _ContextLine(
                    'Ликвидные средства',
                    state.liquidMoney.minorUnits ~/ 100,
                    state.liquidMoney.currency,
                  ),
                  _ContextLine(
                    'Доход месяца',
                    state.monthlyIncome.minorUnits ~/ 100,
                    state.monthlyIncome.currency,
                  ),
                  _ContextLine(
                    'Расходы месяца',
                    state.monthlyExpenses.minorUnits ~/ 100,
                    state.monthlyExpenses.currency,
                  ),
                  _ContextLine(
                    'Свободный cash-flow',
                    state.freeCashflow.minorUnits ~/ 100,
                    state.freeCashflow.currency,
                  ),
                  const Divider(height: 28),
                  Text(
                    'Качество: ${(state.dataQuality.overall * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DesktopProgressBar(
                    value: state.dataQuality.overall,
                    color: state.dataQuality.overall >= 0.7
                        ? QestoColors.positive
                        : QestoColors.warning,
                  ),
                  const Spacer(),
                  const Text(
                    'Сырая полная история в LLM не отправляется.',
                    style: TextStyle(
                      color: QestoColors.secondaryText,
                      fontSize: 10,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: DesktopCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: DesktopSectionHeader(
                      title: 'Qesto Assistant',
                      subtitle: 'Объяснения поверх deterministic analytics',
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _messages.isEmpty
                        ? Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 590),
                              child: Wrap(
                                spacing: 9,
                                runSpacing: 9,
                                alignment: WrapAlignment.center,
                                children: [
                                  for (final prompt in _prompts)
                                    ActionChip(
                                      label: Text(prompt),
                                      avatar: const Icon(
                                        Icons.auto_awesome_outlined,
                                        size: 16,
                                      ),
                                      onPressed: () => _ask(prompt),
                                    ),
                                ],
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(18),
                            itemCount: _messages.length,
                            itemBuilder: (context, index) => Align(
                              alignment: index.isEven
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(12),
                                constraints: const BoxConstraints(
                                  maxWidth: 590,
                                ),
                                decoration: BoxDecoration(
                                  color: index.isEven
                                      ? QestoColors.primary
                                      : QestoColors.surfaceSecondary,
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Text(
                                  _messages[index],
                                  style: TextStyle(
                                    color: index.isEven
                                        ? Colors.white
                                        : QestoColors.text,
                                    fontSize: 12,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(13),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _input,
                            onSubmitted: _ask,
                            decoration: const InputDecoration(
                              hintText: 'Спросите о своих финансах…',
                            ),
                          ),
                        ),
                        const SizedBox(width: 9),
                        IconButton.filled(
                          onPressed: () => _ask(_input.text),
                          icon: const Icon(Icons.arrow_upward_rounded),
                          style: IconButton.styleFrom(
                            backgroundColor: QestoColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const _prompts = [
    'Что изменилось в расходах?',
    'Где я трачу больше обычного?',
    'Что ждёт до конца месяца?',
    'Могу ли я позволить себе покупку?',
  ];

  void _ask(String value) {
    final question = value.trim();
    if (question.isEmpty) return;
    final context = widget.controller.aiContext(
      question.contains('покуп')
          ? AiContextPurpose.purchaseDecision
          : AiContextPurpose.financialSummary,
    );
    setState(() {
      _messages.add(question);
      _messages.add(
        'Факты Synoball: свободный cash-flow ${context.facts['freeCashflow'] ?? 'не рассчитан'}, качество данных ${(context.dataQuality * 100).round()}%. Это локальный deterministic preview; подключение LLM используется только для объяснения этих фактов.',
      );
      _input.clear();
    });
  }
}

class _ContextLine extends StatelessWidget {
  const _ContextLine(this.label, this.amount, this.currency);
  final String label;
  final int amount;
  final String currency;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: QestoColors.secondaryText,
              fontSize: 11,
            ),
          ),
        ),
        Text(
          formatMoney(amount, currency),
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}

class DesktopBenefitsPage extends StatelessWidget {
  const DesktopBenefitsPage({
    required this.coupons,
    required this.promotions,
    required this.trackedProducts,
    super.key,
  });
  final List<Deal> coupons;
  final List<Deal> promotions;
  final List<TrackedProduct> trackedProducts;
  @override
  Widget build(BuildContext context) {
    final deals = [...coupons, ...promotions];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(26, 20, 26, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DesktopCard(
            color: Color(0xFFF1F5FF),
            borderColor: Color(0xFFDCE7FF),
            child: Row(
              children: [
                Icon(Icons.savings_outlined, color: QestoColors.primary),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Выгода — это действия в контексте ваших расходов. Купоны остаются дополнительным источником, а не основой раздела.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Найденная выгода',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final deal in deals.take(6))
                SizedBox(
                  width: 350,
                  height: 150,
                  child: DesktopCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DesktopPill(
                          label: deal.category,
                          color: QestoColors.purple,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          deal.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          deal.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: QestoColors.secondaryText,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              for (final item in trackedProducts)
                SizedBox(
                  width: 350,
                  height: 150,
                  child: DesktopCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const DesktopPill(
                          label: 'Отслеживается',
                          color: QestoColors.positive,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          item.title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${formatMoney(item.currentPrice, item.currency)} · ${item.changePercent}% · ${item.bestMarketplace}',
                          style: const TextStyle(
                            color: QestoColors.secondaryText,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class DesktopSettingsPage extends StatefulWidget {
  const DesktopSettingsPage({required this.controller, super.key});
  final BudgetController controller;

  @override
  State<DesktopSettingsPage> createState() => _DesktopSettingsPageState();
}

class _DesktopSettingsPageState extends State<DesktopSettingsPage> {
  static const _avatars = <String?>[
    null,
    'emoji:🙂',
    'emoji:😎',
    'emoji:🧑‍💻',
    'emoji:🦊',
    'emoji:🐼',
    'emoji:🚀',
    'emoji:🌿',
  ];

  late final TextEditingController _nameController;
  late String _currency;
  String? _avatarUrl;
  late Future<CbrRateSnapshot> _ratesFuture;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    final user = widget.controller.user;
    _nameController = TextEditingController(text: user.name);
    _currency =
        CbrCurrencyService.supportedCurrencies.contains(user.defaultCurrency)
        ? user.defaultCurrency
        : 'RUB';
    _avatarUrl = user.avatarUrl;
    _ratesFuture = CbrCurrencyService().loadLatest();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty || _saving) return;
    setState(() => _saving = true);
    await widget.controller.updateUserProfile(
      name: _nameController.text,
      defaultCurrency: _currency,
      avatarUrl: _avatarUrl,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Профиль сохранён')));
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(26, 20, 26, 30),
    children: [
      Text(
        'Профиль',
        style: context.qestoTypography.display(
          const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: QestoColors.text,
          ),
        ),
      ),
      const SizedBox(height: 5),
      const Text(
        'Личные настройки Qesto. Они не изменяют структуру или историю Synoball.',
        style: TextStyle(color: QestoColors.secondaryText, fontSize: 12),
      ),
      const SizedBox(height: 16),
      DesktopCard(
        padding: const EdgeInsets.all(20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 720;
            final profile = _profileEditor(context);
            final appearance = _appearanceEditor(context);
            return compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [profile, const SizedBox(height: 22), appearance],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 6, child: profile),
                      const SizedBox(width: 28),
                      Expanded(flex: 5, child: appearance),
                    ],
                  );
          },
        ),
      ),
      const SizedBox(height: 14),
      _currencyRatesCard(),
      const SizedBox(height: 24),
      Text(
        'Система',
        style: context.qestoTypography.display(
          const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
      ),
      const SizedBox(height: 10),
      _SettingsSection(
        title: 'Счета и источники',
        icon: Icons.account_balance_outlined,
        description:
            '${widget.controller.accounts.length} счетов · ${widget.controller.synoballState.connections.length} подключений',
      ),
      _SettingsSection(
        title: 'Категории',
        icon: Icons.category_outlined,
        description: '${widget.controller.categories.length} категорий Qesto',
      ),
      _SettingsSection(
        title: 'Данные',
        icon: Icons.storage_outlined,
        description:
            '${widget.controller.synoballState.ingestionRecords.length} ingestion records · schema v2',
      ),
      if (const bool.fromEnvironment('DEV_MODE'))
        _SettingsSection(
          title: 'Developer mode',
          icon: Icons.developer_mode_rounded,
          description:
              '${widget.controller.synoballState.rawPayloads.length} raw payloads · ${widget.controller.synoballState.auditEntries.length} audit entries',
        ),
    ],
  );

  Widget _profileEditor(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          DesktopUserAvatar(
            user: widget.controller.user.copyWith(
              name: _nameController.text,
              avatarUrl: _avatarUrl,
              clearAvatar: _avatarUrl == null,
            ),
            radius: 29,
          ),
          const SizedBox(width: 13),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ваш профиль',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 3),
                Text(
                  'Имя, аватар и основная валюта',
                  style: TextStyle(
                    color: QestoColors.secondaryText,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      TextField(
        key: const Key('profile-name-field'),
        controller: _nameController,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Имя',
          prefixIcon: Icon(Icons.person_outline_rounded),
        ),
      ),
      const SizedBox(height: 14),
      const Text(
        'Аватар',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final avatar in _avatars)
            ChoiceChip(
              label: Text(
                avatar == null ? 'А' : avatar.substring('emoji:'.length),
              ),
              selected: _avatarUrl == avatar,
              onSelected: (_) => setState(() => _avatarUrl = avatar),
            ),
        ],
      ),
      const SizedBox(height: 14),
      DropdownButtonFormField<String>(
        key: const Key('profile-currency-field'),
        initialValue: _currency,
        decoration: const InputDecoration(
          labelText: 'Основная валюта',
          prefixIcon: Icon(Icons.currency_exchange_rounded),
        ),
        items: [
          for (final code in CbrCurrencyService.supportedCurrencies)
            DropdownMenuItem(
              value: code,
              child: Text('$code · ${CbrCurrencyService.currencyNames[code]}'),
            ),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _currency = value);
        },
      ),
      const SizedBox(height: 7),
      const Text(
        'Существующие операции сохраняют исходную валюту. Выбор применяется к интерфейсу и новым данным.',
        style: TextStyle(color: QestoColors.secondaryText, fontSize: 10),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        key: const Key('profile-save-button'),
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.check_rounded, size: 18),
        label: const Text('Сохранить профиль'),
      ),
    ],
  );

  Widget _appearanceEditor(BuildContext context) {
    final appearance = AppAppearanceScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.palette_outlined, color: QestoColors.primary),
            SizedBox(width: 9),
            Text(
              'Оформление',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Тема применяется ко всему приложению и сохраняется на устройстве.',
          style: TextStyle(color: QestoColors.secondaryText, fontSize: 11),
        ),
        const SizedBox(height: 14),
        Wrap(
          key: const Key('profile-theme-selector'),
          spacing: 8,
          runSpacing: 8,
          children: [
            _ThemeChoice(
              label: 'Система',
              icon: Icons.brightness_auto_outlined,
              selected: appearance.preference == QestoThemePreference.system,
              onTap: () => appearance.select(QestoThemePreference.system),
            ),
            _ThemeChoice(
              label: 'Светлая',
              icon: Icons.light_mode_outlined,
              selected: appearance.preference == QestoThemePreference.light,
              onTap: () => appearance.select(QestoThemePreference.light),
            ),
            _ThemeChoice(
              label: 'Тёмная',
              icon: Icons.dark_mode_outlined,
              selected: appearance.preference == QestoThemePreference.dark,
              onTap: () => appearance.select(QestoThemePreference.dark),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: QestoColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.text_fields_rounded, color: QestoColors.primary),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Шрифт B закреплён: IBM Plex Sans для заголовков, Manrope для интерфейса и IBM Plex Mono для чисел.',
                  style: TextStyle(fontSize: 11, height: 1.45),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _currencyRatesCard() => DesktopCard(
    padding: const EdgeInsets.all(18),
    child: FutureBuilder<CbrRateSnapshot>(
      future: _ratesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Row(
            children: [
              SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Получаем официальный курс ЦБ…'),
            ],
          );
        }
        if (!snapshot.hasData) {
          return Row(
            children: [
              const Icon(Icons.cloud_off_outlined, color: QestoColors.warning),
              const SizedBox(width: 11),
              const Expanded(
                child: Text(
                  'Курс ЦБ сейчас недоступен. Валюту можно выбрать без конвертации данных.',
                ),
              ),
              TextButton(
                onPressed: () => setState(
                  () => _ratesFuture = CbrCurrencyService().loadLatest(),
                ),
                child: const Text('Повторить'),
              ),
            ],
          );
        }
        final value = snapshot.requireData;
        final rate = value.rates[_currency];
        return Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: QestoColors.primarySoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.account_balance_rounded,
                color: QestoColors.primary,
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Официальный курс Банка России',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    rate == null
                        ? 'Для $_currency курс не опубликован'
                        : '1 $_currency = ${_rateText(rate.rublesPerUnit)} ₽ · ${_dateText(value.date)}',
                    style: const TextStyle(
                      color: QestoColors.secondaryText,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const DesktopPill(
              label: 'ЦБ РФ',
              color: QestoColors.positive,
              background: Color(0xFFEAF8ED),
            ),
          ],
        );
      },
    ),
  );

  String _dateText(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}';

  String _rateText(double value) {
    final digits = value >= 10 ? 2 : 4;
    return value.toStringAsFixed(digits).replaceFirst('.', ',');
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    avatar: Icon(
      icon,
      size: 17,
      color: selected ? QestoColors.primary : QestoColors.secondaryText,
    ),
    selected: selected,
    showCheckmark: false,
    onSelected: (_) => onTap(),
  );
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.icon,
    required this.description,
  });
  final String title;
  final IconData icon;
  final String description;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: DesktopCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: QestoColors.primarySoft,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 19, color: QestoColors.primary),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: const TextStyle(
                    color: QestoColors.secondaryText,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
