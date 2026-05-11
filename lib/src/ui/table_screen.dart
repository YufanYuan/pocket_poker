import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ai/ai_decision_provider.dart';
import '../domain/card.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/poker_game.dart';

class TableScreen extends StatefulWidget {
  const TableScreen({
    required this.config,
    required this.aiDecisionProvider,
    required this.onLeaveTable,
    super.key,
  });

  final TableConfig config;
  final AiDecisionProvider aiDecisionProvider;
  final VoidCallback onLeaveTable;

  @override
  State<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends State<TableScreen> {
  late final PokerGame _game;
  bool _aiRunning = false;
  bool _nextHandScheduled = false;
  bool _controlsCollapsed = false;

  @override
  void initState() {
    super.initState();
    _game = PokerGame(
      config: widget.config,
      aiDecisionProvider: widget.aiDecisionProvider,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _driveAi());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool wide = constraints.maxWidth > 760;
            final bool showControls = _game.isHumanTurn || _game.isHandComplete;
            final bool collapsedDecisionBar =
                showControls && _game.isHumanTurn && _controlsCollapsed;
            final Widget table = _TableFelt(
              game: _game,
              onLeaveTable: widget.onLeaveTable,
            );
            final Widget controls = _ControlsPanel(
              game: _game,
              aiRunning: _aiRunning,
              onAction: _onHumanAction,
              onNextHand: _startNextHand,
              onCollapse: _game.isHumanTurn ? _collapseControls : null,
              onRebuy: _showRebuySheet,
              onHistory: _showHistorySheet,
              onLog: _showLogSheet,
            );
            return Padding(
              padding: EdgeInsets.fromLTRB(
                wide ? 18 : 10,
                wide ? 14 : 6,
                wide ? 18 : 10,
                wide ? 14 : 8,
              ),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(flex: 3, child: table),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 380,
                          child: collapsedDecisionBar
                              ? _CollapsedDecisionBar(
                                  game: _game,
                                  onExpand: _expandControls,
                                )
                              : showControls
                              ? controls
                              : _TableDock(
                                  game: _game,
                                  aiRunning: _aiRunning,
                                  onRebuy: _showRebuySheet,
                                  onHistory: _showHistorySheet,
                                  onLog: _showLogSheet,
                                ),
                        ),
                      ],
                    )
                  : Stack(
                      children: <Widget>[
                        Positioned.fill(child: table),
                        if (!showControls)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: _TableDock(
                              game: _game,
                              aiRunning: _aiRunning,
                              onRebuy: _showRebuySheet,
                              onHistory: _showHistorySheet,
                              onLog: _showLogSheet,
                            ),
                          ),
                        if (collapsedDecisionBar)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: _CollapsedDecisionBar(
                              game: _game,
                              onExpand: _expandControls,
                            ),
                          ),
                        if (showControls && !collapsedDecisionBar)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: constraints.maxHeight * 0.58,
                              ),
                              child: controls,
                            ),
                          ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _driveAi() async {
    if (_aiRunning || !mounted) {
      return;
    }
    setState(() => _aiRunning = true);
    try {
      int guard = 0;
      while (mounted &&
          !_game.isHandComplete &&
          !_game.isHumanTurn &&
          _game.currentPlayer?.kind == PlayerKind.ai) {
        guard += 1;
        if (guard > 200) {
          throw StateError('AI action loop exceeded the safety limit.');
        }

        final PlayerState actor = _game.currentPlayer!;
        final String style = actor.profile == null
            ? ''
            : ' (${actor.profile!.name})';
        setState(() {
          _game.statusMessage = '${actor.name}$style thinking...';
        });
        final bool applied = await _game.runNextAiAction();
        if (!applied || !mounted) {
          break;
        }
        setState(() {
          if (_game.isHumanTurn) {
            _controlsCollapsed = false;
          }
        });
        if (!_game.isHumanTurn && !_game.isHandComplete) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
        }
      }
    } on Object catch (error) {
      _game.statusMessage = error.toString();
    } finally {
      if (mounted) {
        setState(() {
          _aiRunning = false;
          if (_game.isHumanTurn) {
            _controlsCollapsed = false;
          }
        });
        _scheduleNextHandIfNeeded();
      }
    }
  }

  void _onHumanAction(PokerAction action) {
    setState(() {
      _controlsCollapsed = false;
      _game.applyAction(action);
    });
    _driveAi();
    _scheduleNextHandIfNeeded();
  }

  void _scheduleNextHandIfNeeded() {
    if (!_game.isHandComplete || _nextHandScheduled || !mounted) {
      return;
    }
    _nextHandScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted || !_game.isHandComplete) {
        _nextHandScheduled = false;
        return;
      }
      _startNextHand();
    });
  }

  void _startNextHand() {
    setState(() {
      _controlsCollapsed = false;
      _nextHandScheduled = false;
      _game.startNextHand();
    });
    _driveAi();
  }

  void _collapseControls() {
    if (!_game.isHumanTurn) {
      return;
    }
    setState(() => _controlsCollapsed = true);
  }

  void _expandControls() {
    setState(() => _controlsCollapsed = false);
  }

  Future<void> _showRebuySheet() async {
    final int? amount = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF162423),
      builder: (BuildContext context) => _RebuySheet(game: _game),
    );
    if (amount == null || amount <= 0 || !mounted) {
      return;
    }
    setState(() {
      _game.rebuyHuman(amount);
    });
  }

  Future<void> _showHistorySheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF162423),
      builder: (BuildContext context) => _HistorySheet(game: _game),
    );
  }

  Future<void> _showLogSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF162423),
      builder: (BuildContext context) => _ActionLogSheet(game: _game),
    );
  }
}

class _TableFelt extends StatelessWidget {
  const _TableFelt({required this.game, required this.onLeaveTable});

  final PokerGame game;
  final VoidCallback onLeaveTable;

  @override
  Widget build(BuildContext context) {
    final List<PlayerState> opponents = game.players
        .where((PlayerState player) => player.kind == PlayerKind.ai)
        .toList(growable: false);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double height = constraints.maxHeight;
        final bool compact = width < 390;
        final double seatWidth = compact ? 116 : 126;
        final double seatHeight = compact ? 58 : 62;
        final double tableWidth = math.min(width * 0.72, compact ? 280 : 312);
        final double tableHeight = math.min(
          height * (height < 720 ? 0.60 : 0.66),
          590,
        );
        final double tableTop = math.max(86, height * 0.11);
        final Rect tableRect = Rect.fromCenter(
          center: Offset(width / 2, tableTop + tableHeight / 2),
          width: tableWidth,
          height: tableHeight,
        );

        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.42),
              radius: 1.15,
              colors: <Color>[
                Color(0xFF132321),
                Color(0xFF091311),
                Color(0xFF050A0A),
              ],
            ),
          ),
          child: ClipRRect(
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned.fill(child: CustomPaint(painter: _FeltPainter())),
                Positioned(
                  left: 4,
                  top: 4,
                  right: 4,
                  child: _TableHeader(game: game, onLeaveTable: onLeaveTable),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: tableTop - (game.isHandComplete ? 64 : 42),
                  child: _CenterBoard(
                    game: game,
                    boardGap: tableHeight * 0.24 + 10,
                  ),
                ),
                for (int index = 0; index < opponents.length; index += 1)
                  _positionedOpponent(
                    opponent: opponents[index],
                    index: index,
                    count: opponents.length,
                    width: width,
                    height: height,
                    tableRect: tableRect,
                    seatWidth: seatWidth,
                    seatHeight: seatHeight,
                  ),
                Positioned(
                  left: (width - 128) / 2,
                  top: tableTop + tableHeight * 0.72,
                  width: 128,
                  child: _HeroPanel(
                    player: game.humanPlayer,
                    active: game.currentPlayer == game.humanPlayer,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _positionedOpponent({
    required PlayerState opponent,
    required int index,
    required int count,
    required double width,
    required double height,
    required Rect tableRect,
    required double seatWidth,
    required double seatHeight,
  }) {
    final Offset seatCenter = _seatCenterFor(
      count: count,
      index: index,
      tableRect: tableRect,
      seatWidth: seatWidth,
    );
    return Positioned(
      left: (seatCenter.dx - seatWidth / 2)
          .clamp(6.0, width - seatWidth - 6)
          .toDouble(),
      top: (seatCenter.dy - seatHeight / 2)
          .clamp(64.0, height - seatHeight - 118)
          .toDouble(),
      width: seatWidth,
      height: seatHeight,
      child: _SeatChip(
        game: game,
        player: opponent,
        active: game.currentPlayer == opponent,
        revealCards: game.showdownPlayerIds.contains(opponent.id),
      ),
    );
  }

  Offset _seatCenterFor({
    required int count,
    required int index,
    required Rect tableRect,
    required double seatWidth,
  }) {
    final int sideCount = count ~/ 2;
    final bool hasTopSeat = count.isOdd;
    final List<double> leftFractions = _clockwiseLeftFractions(sideCount);
    final List<double> rightFractions = _clockwiseRightFractions(sideCount);
    final List<Offset> seats = <Offset>[];

    for (final double fraction in leftFractions) {
      seats.add(
        Offset(
          tableRect.left - seatWidth * 0.18,
          tableRect.top + tableRect.height * fraction,
        ),
      );
    }
    if (hasTopSeat) {
      seats.add(
        Offset(tableRect.center.dx, tableRect.top + tableRect.height * 0.18),
      );
    }
    for (final double fraction in rightFractions) {
      seats.add(
        Offset(
          tableRect.right + seatWidth * 0.18,
          tableRect.top + tableRect.height * fraction,
        ),
      );
    }

    return seats[index.clamp(0, seats.length - 1)];
  }

  List<double> _clockwiseLeftFractions(int count) {
    return switch (count) {
      0 => <double>[],
      1 => <double>[0.62],
      2 => <double>[0.68, 0.22],
      3 => <double>[0.76, 0.62, 0.20],
      _ => <double>[0.78, 0.64, 0.24, 0.12],
    };
  }

  List<double> _clockwiseRightFractions(int count) {
    return switch (count) {
      0 => <double>[],
      1 => <double>[0.62],
      2 => <double>[0.22, 0.68],
      3 => <double>[0.20, 0.62, 0.76],
      _ => <double>[0.12, 0.24, 0.64, 0.78],
    };
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.game, required this.onLeaveTable});

  final PokerGame game;
  final VoidCallback onLeaveTable;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        IconButton(
          tooltip: 'Leave table',
          onPressed: onLeaveTable,
          icon: const Icon(Icons.menu),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xAA0B1211),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFF334742)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Hand #${game.handNumber}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.copy, size: 13, color: Color(0xFF8FA69C)),
            ],
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Stats',
          onPressed: () {},
          icon: const Icon(Icons.bar_chart),
        ),
      ],
    );
  }
}

class _CenterBoard extends StatelessWidget {
  const _CenterBoard({required this.game, required this.boardGap});

  final PokerGame game;
  final double boardGap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (game.isHandComplete) ...<Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: _ResultBanner(message: game.statusMessage),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 64),
          _PhasePill(label: _phaseLabel(game.phase).toUpperCase()),
          SizedBox(height: boardGap),
          _BoardCards(cards: game.board),
          const SizedBox(height: 8),
          _PotStrip(pot: game.potTotal),
        ],
      ),
    );
  }
}

class _PotStrip extends StatelessWidget {
  const _PotStrip({required this.pot});

  final int pot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xDD0D1615),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF7B6330)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.blur_on, size: 14, color: Color(0xFFE0B85C)),
          const SizedBox(width: 6),
          Text(
            'Pot ${Chips.format(pot)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFF8F1D8),
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _PhasePill extends StatelessWidget {
  const _PhasePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xDD2B7D46),
        borderRadius: BorderRadius.circular(999),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x33000000), blurRadius: 10),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFD8F5D6),
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _ResultBanner extends StatelessWidget {
  const _ResultBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xEE111817),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE0B85C)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.emoji_events, color: Color(0xFFE0B85C), size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({required this.player, required this.active});

  final PlayerState player;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final String? streetInvestment = _streetInvestmentLabel(player);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF142A23) : const Color(0xEE111C1A),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: active ? const Color(0xFFE0B85C) : const Color(0xFF7B6330),
          width: active ? 1.8 : 1.1,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _CardFace(
                card: player.holeCards.isNotEmpty ? player.holeCards[0] : null,
                compact: true,
              ),
              const SizedBox(width: 7),
              _CardFace(
                card: player.holeCards.length > 1 ? player.holeCards[1] : null,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            player.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 2,
            children: <Widget>[
              Text(
                Chips.format(player.stack),
                style: const TextStyle(
                  color: Color(0xFF6BE083),
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (streetInvestment != null)
                Text(
                  streetInvestment,
                  style: const TextStyle(
                    color: Color(0xFFE0B85C),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            children: <Widget>[
              if (player.isSmallBlind) const _SeatBadge(label: 'SB'),
              if (player.isBigBlind) const _SeatBadge(label: 'BB'),
              if (player.isDealer) const _SeatBadge(label: 'D'),
            ],
          ),
        ],
      ),
    );
  }
}

class _RebuySheet extends StatefulWidget {
  const _RebuySheet({required this.game});

  final PokerGame game;

  @override
  State<_RebuySheet> createState() => _RebuySheetState();
}

class _RebuySheetState extends State<_RebuySheet> {
  late final TextEditingController _controller;
  late int _amount;

  @override
  void initState() {
    super.initState();
    _amount = _defaultAmount();
    _controller = TextEditingController(text: Chips.format(_amount));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PokerGame game = widget.game;
    final PlayerState hero = game.humanPlayer;
    final int room = game.humanRebuyRoom;
    final bool canRebuy = game.canRebuyHuman && room > 0;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          0,
          18,
          18 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _SheetTitle(
              icon: Icons.monetization_on_outlined,
              title: 'Rebuy',
            ),
            const SizedBox(height: 12),
            _InfoRow(label: 'Hero stack', value: Chips.format(hero.stack)),
            _InfoRow(
              label: 'Table max',
              value: Chips.format(game.config.maxBuyIn),
            ),
            _InfoRow(label: 'Room', value: Chips.format(room)),
            const SizedBox(height: 14),
            if (!canRebuy)
              Text(
                room <= 0
                    ? 'Hero is already at the table max.'
                    : 'Rebuy is available after Hero folds or the hand ends.',
                style: const TextStyle(
                  color: Color(0xFFB7C8C0),
                  fontWeight: FontWeight.w700,
                ),
              )
            else ...<Widget>[
              TextField(
                controller: _controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: const TextStyle(
                  color: Color(0xFFF8F1D8),
                  fontWeight: FontWeight.w900,
                ),
                decoration: const InputDecoration(
                  labelText: 'Add chips',
                  prefixIcon: Icon(Icons.add_circle_outline),
                ),
                onChanged: _setFromText,
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          _setAmount(math.min(game.config.minBuyIn, room)),
                      child: const Text('Min'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _setAmount(room),
                      child: const Text('Max'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _amount <= 0
                    ? null
                    : () => Navigator.of(context).pop(_amount),
                icon: const Icon(Icons.monetization_on_outlined),
                label: Text('Add ${Chips.format(_amount)}'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  int _defaultAmount() {
    final int room = widget.game.humanRebuyRoom;
    if (room <= 0) {
      return 0;
    }
    return math.min(
      widget.game.config.maxBuyIn - widget.game.humanPlayer.stack,
      room,
    );
  }

  void _setFromText(String value) {
    final int? parsed = _parseChips(value);
    if (parsed == null) {
      return;
    }
    setState(
      () => _amount = parsed.clamp(0, widget.game.humanRebuyRoom).toInt(),
    );
  }

  void _setAmount(int amount) {
    final int next = amount.clamp(0, widget.game.humanRebuyRoom).toInt();
    setState(() {
      _amount = next;
      _controller.text = Chips.format(next);
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
  }
}

class _HistorySheet extends StatelessWidget {
  const _HistorySheet({required this.game});

  final PokerGame game;

  @override
  Widget build(BuildContext context) {
    final List<int> handNumbers =
        game.actionLog
            .map((ActionHistoryEntry entry) => entry.handNumber)
            .toSet()
            .toList()
          ..sort((int a, int b) => b.compareTo(a));
    return _ScrollableSheet(
      title: 'History',
      icon: Icons.schedule,
      child: handNumbers.isEmpty
          ? const _EmptySheetMessage(message: 'No completed actions yet.')
          : Column(
              children: handNumbers.map((int handNumber) {
                final List<ActionHistoryEntry> entries = game.actionLog
                    .where(
                      (ActionHistoryEntry entry) =>
                          entry.handNumber == handNumber,
                    )
                    .toList(growable: false);
                return _HandHistoryCard(
                  handNumber: handNumber,
                  entries: entries,
                  isCurrentHand: handNumber == game.handNumber,
                );
              }).toList(),
            ),
    );
  }
}

class _ActionLogSheet extends StatelessWidget {
  const _ActionLogSheet({required this.game});

  final PokerGame game;

  @override
  Widget build(BuildContext context) {
    return _ScrollableSheet(
      title: 'Log',
      icon: Icons.receipt_long_outlined,
      child: game.actionLog.isEmpty
          ? const _EmptySheetMessage(message: 'No table actions yet.')
          : Column(
              children: game.actionLog.reversed
                  .map(
                    (ActionHistoryEntry entry) => _ActionLogRow(entry: entry),
                  )
                  .toList(),
            ),
    );
  }
}

class _ScrollableSheet extends StatelessWidget {
  const _ScrollableSheet({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.32,
        maxChildSize: 0.92,
        builder: (BuildContext context, ScrollController scrollController) {
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            children: <Widget>[
              _SheetTitle(icon: icon, title: title),
              const SizedBox(height: 12),
              child,
            ],
          );
        },
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, color: const Color(0xFFE0B85C)),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFFF4F0DE),
            fontSize: 18,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF9BAEA6),
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFFF4F0DE),
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _HandHistoryCard extends StatelessWidget {
  const _HandHistoryCard({
    required this.handNumber,
    required this.entries,
    required this.isCurrentHand,
  });

  final int handNumber;
  final List<ActionHistoryEntry> entries;
  final bool isCurrentHand;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF101918),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF314842)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                'Hand $handNumber',
                style: const TextStyle(
                  color: Color(0xFFF4F0DE),
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                isCurrentHand ? 'Current' : '${entries.length} actions',
                style: const TextStyle(
                  color: Color(0xFFE0B85C),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...entries.map((ActionHistoryEntry entry) {
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _compactActionLabel(entry),
                style: const TextStyle(
                  color: Color(0xFFB7C8C0),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _ActionLogRow extends StatelessWidget {
  const _ActionLogRow({required this.entry});

  final ActionHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 58,
            child: Text(
              'H${entry.handNumber} ${entry.phase.name}',
              style: const TextStyle(
                color: Color(0xFFE0B85C),
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${entry.playerName} ${_actionText(entry)}',
              style: const TextStyle(
                color: Color(0xFFB7C8C0),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            Chips.format(entry.stackAfter),
            style: const TextStyle(
              color: Color(0xFF8FA69C),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptySheetMessage extends StatelessWidget {
  const _EmptySheetMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFFB7C8C0),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TableDock extends StatelessWidget {
  const _TableDock({
    required this.game,
    required this.aiRunning,
    required this.onRebuy,
    required this.onHistory,
    required this.onLog,
  });

  final PokerGame game;
  final bool aiRunning;
  final VoidCallback onRebuy;
  final VoidCallback onHistory;
  final VoidCallback onLog;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xDD0D1615),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFF293B36)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  aiRunning ? Icons.auto_awesome : Icons.circle,
                  size: 14,
                  color: const Color(0xFFE0B85C),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    aiRunning
                        ? 'AI thinking'
                        : 'Blinds 0.5 / 1   |   Hand ${game.handNumber}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFB7C8C0),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            constraints: const BoxConstraints(maxWidth: 344),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xDD0D1615),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF243632)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                _DockAction(
                  icon: Icons.monetization_on_outlined,
                  label: 'Rebuy',
                  onPressed: onRebuy,
                ),
                _DockAction(
                  icon: Icons.schedule,
                  label: 'History',
                  onPressed: onHistory,
                ),
                _DockAction(
                  icon: Icons.receipt_long_outlined,
                  label: 'Log',
                  onPressed: onLog,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsedDecisionBar extends StatelessWidget {
  const _CollapsedDecisionBar({required this.game, required this.onExpand});

  final PokerGame game;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final PlayerState hero = game.humanPlayer;
    final int toCall = math.max(0, game.currentBet - hero.currentBet);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onExpand,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 370),
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            color: const Color(0xF2162423),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFF314842)),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 18,
                offset: Offset(0, -6),
              ),
            ],
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.keyboard_arrow_up, color: Color(0xFFE0B85C)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Hero to act',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Color(0xFFF4F0DE),
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'To call ${Chips.format(toCall)}  ·  Pot ${Chips.format(game.potTotal)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFB7C8C0),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _CardFace(
                card: hero.holeCards.isNotEmpty ? hero.holeCards[0] : null,
                tiny: true,
              ),
              const SizedBox(width: 5),
              _CardFace(
                card: hero.holeCards.length > 1 ? hero.holeCards[1] : null,
                tiny: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockAction extends StatelessWidget {
  const _DockAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: const Color(0xFFE0B85C), size: 24),
              const SizedBox(height: 5),
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: Color(0xFFB7C8C0),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolStrip extends StatelessWidget {
  const _ToolStrip({
    required this.onRebuy,
    required this.onHistory,
    required this.onLog,
  });

  final VoidCallback onRebuy;
  final VoidCallback onHistory;
  final VoidCallback onLog;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: _ToolStripButton(
            icon: Icons.monetization_on_outlined,
            label: 'Rebuy',
            onPressed: onRebuy,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ToolStripButton(
            icon: Icons.schedule,
            label: 'History',
            onPressed: onHistory,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ToolStripButton(
            icon: Icons.receipt_long_outlined,
            label: 'Log',
            onPressed: onLog,
          ),
        ),
      ],
    );
  }
}

class _ToolStripButton extends StatelessWidget {
  const _ToolStripButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label.toUpperCase(),
          maxLines: 1,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
        ),
      ),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        foregroundColor: const Color(0xFFE0B85C),
        side: const BorderSide(color: Color(0xFF314842)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

class _ControlsPanel extends StatefulWidget {
  const _ControlsPanel({
    required this.game,
    required this.aiRunning,
    required this.onAction,
    required this.onNextHand,
    required this.onCollapse,
    required this.onRebuy,
    required this.onHistory,
    required this.onLog,
  });

  final PokerGame game;
  final bool aiRunning;
  final ValueChanged<PokerAction> onAction;
  final VoidCallback onNextHand;
  final VoidCallback? onCollapse;
  final VoidCallback onRebuy;
  final VoidCallback onHistory;
  final VoidCallback onLog;

  @override
  State<_ControlsPanel> createState() => _ControlsPanelState();
}

class _ControlsPanelState extends State<_ControlsPanel> {
  final TextEditingController _amountController = TextEditingController();
  PokerActionType? _activeWagerType;
  int? _selectedAmount;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PokerGame game = widget.game;
    final List<LegalAction> legal = game.legalActionsForCurrentPlayer();
    final LegalAction? fold = _findLegal(legal, PokerActionType.fold);
    final LegalAction? check = _findLegal(legal, PokerActionType.check);
    final LegalAction? call = _findLegal(legal, PokerActionType.call);
    final LegalAction? wager =
        _findLegal(legal, PokerActionType.raise) ??
        _findLegal(legal, PokerActionType.bet);
    final LegalAction? allIn = _findLegal(legal, PokerActionType.allIn);
    _syncSelectedAmount(wager);

    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: const Color(0xF2162423),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: const Color(0xFF253C38)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0xAA000000),
            blurRadius: 26,
            offset: Offset(0, -10),
          ),
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: 28,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onCollapse,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 36,
                        vertical: 10,
                      ),
                      child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFF6C7D78),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
                  if (widget.onCollapse != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: 'Hide decision panel',
                        onPressed: widget.onCollapse,
                        icon: const Icon(Icons.keyboard_arrow_down),
                        color: const Color(0xFFB7C8C0),
                        style: IconButton.styleFrom(
                          fixedSize: const Size(32, 32),
                          minimumSize: const Size(32, 32),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            _ToolStrip(
              onRebuy: widget.onRebuy,
              onHistory: widget.onHistory,
              onLog: widget.onLog,
            ),
            const SizedBox(height: 10),
            if (game.isHandComplete)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _ResultBanner(message: game.statusMessage),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: widget.onNextHand,
                    icon: const Icon(Icons.skip_next),
                    label: const Text('Next hand'),
                  ),
                ],
              )
            else ...<Widget>[
              _DecisionStats(game: game),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  if (fold != null)
                    Expanded(
                      child: _ActionButton(
                        label: 'Fold',
                        icon: Icons.close,
                        enabled: game.isHumanTurn,
                        muted: true,
                        onPressed: () => _submit(PokerActionType.fold),
                      ),
                    ),
                  if (check != null) ...<Widget>[
                    if (fold != null) const SizedBox(width: 8),
                    Expanded(
                      child: _ActionButton(
                        label: 'Check',
                        icon: Icons.check,
                        enabled: game.isHumanTurn,
                        onPressed: () => _submit(PokerActionType.check),
                      ),
                    ),
                  ],
                  if (call != null) ...<Widget>[
                    if (fold != null || check != null) const SizedBox(width: 8),
                    Expanded(
                      child: _ActionButton(
                        label: 'Call ${Chips.format(_toCall(game))}',
                        icon: Icons.call_made,
                        enabled: game.isHumanTurn,
                        emphasized: true,
                        onPressed: () => _submit(PokerActionType.call),
                      ),
                    ),
                  ],
                ],
              ),
              if (wager != null) ...<Widget>[
                const SizedBox(height: 14),
                _WagerControls(
                  action: wager,
                  allIn: allIn,
                  amount: _selectedAmount ?? wager.minAmount ?? 0,
                  amountController: _amountController,
                  enabled: game.isHumanTurn,
                  game: game,
                  onAmountChanged: _setAmount,
                  onSubmitted: () =>
                      _submit(wager.type, amount: _selectedAmount),
                ),
              ] else if (allIn != null) ...<Widget>[
                const SizedBox(height: 10),
                _ActionButton(
                  label:
                      'All-in ${Chips.format(game.currentPlayer?.stack ?? 0)}',
                  icon: Icons.local_fire_department,
                  enabled: game.isHumanTurn,
                  emphasized: true,
                  onPressed: () =>
                      _submit(PokerActionType.allIn, amount: allIn.maxAmount),
                ),
              ],
            ],
            if (game.isHandComplete) ...<Widget>[
              const SizedBox(height: 10),
              Theme(
                data: Theme.of(context).copyWith(
                  dividerColor: Colors.transparent,
                  listTileTheme: const ListTileThemeData(
                    dense: true,
                    minVerticalPadding: 0,
                  ),
                ),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text('Action log'),
                  children: <Widget>[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 130),
                      child: ListView(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: game.actionLog.reversed.take(10).map((
                          ActionHistoryEntry entry,
                        ) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              entry.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: const Color(0xFFB7C8C0)),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _syncSelectedAmount(LegalAction? wager) {
    if (wager == null) {
      _activeWagerType = null;
      _selectedAmount = null;
      if (_amountController.text.isNotEmpty) {
        _amountController.text = '';
      }
      return;
    }
    final int min = wager.minAmount ?? 0;
    final int max = wager.maxAmount ?? min;
    final bool reset =
        _activeWagerType != wager.type ||
        _selectedAmount == null ||
        _selectedAmount! < min ||
        _selectedAmount! > max;
    if (!reset) {
      return;
    }
    _activeWagerType = wager.type;
    _selectedAmount = _defaultWagerAmount(wager);
    _amountController.text = Chips.format(_selectedAmount!);
  }

  int _defaultWagerAmount(LegalAction wager) {
    final PokerGame game = widget.game;
    final int min = wager.minAmount ?? 0;
    final int max = wager.maxAmount ?? min;
    final int currentBet = game.currentBet;
    final int target = currentBet > 0
        ? currentBet * 3
        : math.max(game.config.bigBlind * 3, game.potTotal);
    return target.clamp(min, max).toInt();
  }

  void _setAmount(int amount) {
    final List<LegalAction> legal = widget.game.legalActionsForCurrentPlayer();
    final LegalAction? wager =
        _findLegal(legal, PokerActionType.raise) ??
        _findLegal(legal, PokerActionType.bet);
    if (wager == null) {
      return;
    }
    final int min = wager.minAmount ?? 0;
    final int max = wager.maxAmount ?? min;
    final int next = amount.clamp(min, max).toInt();
    setState(() {
      _selectedAmount = next;
      _amountController.text = Chips.format(next);
      _amountController.selection = TextSelection.collapsed(
        offset: _amountController.text.length,
      );
    });
  }

  void _submit(PokerActionType type, {int? amount}) {
    widget.onAction(PokerAction(type, amount: amount));
  }

  LegalAction? _findLegal(List<LegalAction> legal, PokerActionType type) {
    for (final LegalAction action in legal) {
      if (action.type == type) {
        return action;
      }
    }
    return null;
  }

  int _toCall(PokerGame game) {
    final PlayerState? player = game.currentPlayer;
    if (player == null) {
      return 0;
    }
    return math.max(0, game.currentBet - player.currentBet);
  }
}

class _DecisionStats extends StatelessWidget {
  const _DecisionStats({required this.game});

  final PokerGame game;

  @override
  Widget build(BuildContext context) {
    final PlayerState? current = game.currentPlayer;
    final int toCall = current == null
        ? 0
        : math.max(0, game.currentBet - current.currentBet);
    final String potOdds = toCall <= 0
        ? '--'
        : '${(game.potTotal / toCall).toStringAsFixed(1)} : 1';
    return Row(
      children: <Widget>[
        Expanded(
          child: _MiniStat(label: 'To Call', value: Chips.format(toCall)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MiniStat(label: 'Pot Odds', value: potOdds),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MiniStat(
            label: 'Stack',
            value: Chips.format(game.humanPlayer.stack),
          ),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF9BAEA6),
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFF4F0DE),
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _WagerControls extends StatelessWidget {
  const _WagerControls({
    required this.action,
    required this.allIn,
    required this.amount,
    required this.amountController,
    required this.enabled,
    required this.game,
    required this.onAmountChanged,
    required this.onSubmitted,
  });

  final LegalAction action;
  final LegalAction? allIn;
  final int amount;
  final TextEditingController amountController;
  final bool enabled;
  final PokerGame game;
  final ValueChanged<int> onAmountChanged;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final int min = action.minAmount ?? 0;
    final int max = action.maxAmount ?? min;
    final int safeAmount = amount.clamp(min, max).toInt();
    final int step = Chips.bigBlind;
    final int divisions = max <= min
        ? 1
        : ((max - min) ~/ Chips.smallBlind).clamp(1, 120).toInt();
    final String verb = action.type == PokerActionType.raise
        ? 'Raise to'
        : 'Bet';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          verb.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFFB7C8C0),
            fontSize: 11,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFF101918),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF314842)),
          ),
          child: Row(
            children: <Widget>[
              _AmountIconButton(
                icon: Icons.remove,
                enabled: enabled && safeAmount > min,
                onPressed: () => onAmountChanged(safeAmount - step),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: amountController,
                  enabled: enabled,
                  textAlign: TextAlign.center,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(
                    color: Color(0xFFF8F1D8),
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onSubmitted: (String value) {
                    final int? parsed = _parseChips(value);
                    if (parsed != null) {
                      onAmountChanged(parsed);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              _AmountIconButton(
                icon: Icons.add,
                enabled: enabled && safeAmount < max,
                onPressed: () => onAmountChanged(safeAmount + step),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: _QuickAmountButton(
                label: '2x',
                enabled: enabled,
                onPressed: () => onAmountChanged(_quickTarget(2)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _QuickAmountButton(
                label: '3x',
                enabled: enabled,
                onPressed: () => onAmountChanged(_quickTarget(3)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _QuickAmountButton(
                label: 'Pot',
                enabled: enabled,
                onPressed: () => onAmountChanged(_potTarget()),
              ),
            ),
            if (allIn != null) ...<Widget>[
              const SizedBox(width: 8),
              Expanded(
                child: _QuickAmountButton(
                  label: 'All-in',
                  enabled: enabled,
                  onPressed: () => onAmountChanged(allIn!.maxAmount ?? max),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFF4ED06C),
            inactiveTrackColor: const Color(0xFF3D4947),
            thumbColor: const Color(0xFFE0B85C),
            overlayColor: const Color(0x33E0B85C),
            trackHeight: 4,
          ),
          child: SizedBox(
            height: 34,
            child: Slider(
              value: safeAmount.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: divisions,
              label: Chips.format(safeAmount),
              onChanged: !enabled || max <= min
                  ? null
                  : (double next) => onAmountChanged(
                      (next / Chips.smallBlind).round() * Chips.smallBlind,
                    ),
            ),
          ),
        ),
        Row(
          children: <Widget>[
            Text(
              '${Chips.format(min)} (Min)',
              style: const TextStyle(color: Color(0xFF9BAEA6), fontSize: 11),
            ),
            const Spacer(),
            Text(
              '${Chips.format(max)} (All-in)',
              style: const TextStyle(color: Color(0xFF9BAEA6), fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: enabled ? onSubmitted : null,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: const Color(0xFFE0B85C),
            foregroundColor: const Color(0xFF171006),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Text(
            '$verb ${Chips.format(safeAmount)}'.toUpperCase(),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
        ),
      ],
    );
  }

  int _quickTarget(int multiplier) {
    final int raw = game.currentBet > 0
        ? game.currentBet * multiplier
        : game.config.bigBlind * multiplier;
    return _clampToAction(raw);
  }

  int _potTarget() {
    final PlayerState? player = game.currentPlayer;
    if (player == null) {
      return _clampToAction(game.potTotal);
    }
    final int toCall = math.max(0, game.currentBet - player.currentBet);
    final int raw = game.currentBet > 0
        ? game.currentBet + game.potTotal + toCall
        : player.currentBet + game.potTotal;
    return _clampToAction(raw);
  }

  int _clampToAction(int raw) {
    final int min = action.minAmount ?? 0;
    final int max = action.maxAmount ?? min;
    return raw.clamp(min, max).toInt();
  }

  int? _parseChips(String value) {
    final String normalized = value.trim().replaceAll(',', '');
    if (normalized.isEmpty) {
      return null;
    }
    final double? parsed = double.tryParse(normalized);
    if (parsed == null) {
      return null;
    }
    return Chips.fromWhole(parsed);
  }
}

class _AmountIconButton extends StatelessWidget {
  const _AmountIconButton({
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: enabled ? onPressed : null,
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        minimumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        backgroundColor: const Color(0xFF202C2A),
        disabledBackgroundColor: const Color(0xFF18211F),
        foregroundColor: const Color(0xFFE0B85C),
      ),
      icon: Icon(icon),
      tooltip: icon == Icons.add ? 'Increase' : 'Decrease',
    );
  }
}

class _QuickAmountButton extends StatelessWidget {
  const _QuickAmountButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: enabled ? onPressed : null,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        foregroundColor: const Color(0xFFF1E8CE),
        side: const BorderSide(color: Color(0xFF475F58)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label.toUpperCase(),
          maxLines: 1,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onPressed,
    this.emphasized = false,
    this.muted = false,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;
  final bool emphasized;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final Color background = muted
        ? const Color(0xFFA4493F)
        : emphasized
        ? const Color(0xFF3F9D55)
        : const Color(0xFFE0B85C);
    final Color foreground = muted || emphasized
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF171006);
    final ButtonStyle style = FilledButton.styleFrom(
      minimumSize: const Size(0, 56),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      backgroundColor: background,
      disabledBackgroundColor: const Color(0xFF26312F),
      disabledForegroundColor: const Color(0xFF7D8D87),
      foregroundColor: foreground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
    return FilledButton(
      onPressed: enabled ? onPressed : null,
      style: style,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 20),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeatChip extends StatelessWidget {
  const _SeatChip({
    required this.game,
    required this.player,
    required this.active,
    required this.revealCards,
  });

  final PokerGame game;
  final PlayerState player;
  final bool active;
  final bool revealCards;

  @override
  Widget build(BuildContext context) {
    final ActionHistoryEntry? lastAction = game.lastActionFor(player);
    final String status = _seatStatus(lastAction);
    final List<String> badges = <String>[
      if (player.isDealer) 'D',
      if (player.isSmallBlind) 'SB',
      if (player.isBigBlind) 'BB',
      if (player.hasFolded) 'Fold',
      if (player.isAllIn) 'All-in',
    ];
    final bool showCards = revealCards && player.holeCards.length >= 2;
    final bool faded = player.hasFolded && !showCards;

    return Opacity(
      opacity: faded ? 0.52 : 1,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            left: 18,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: EdgeInsets.fromLTRB(24, 6, showCards ? 47 : 8, 6),
              decoration: BoxDecoration(
                color: active
                    ? const Color(0xF01D473B)
                    : const Color(0xF0101D1A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: active
                      ? const Color(0xFFE0B85C)
                      : const Color(0xFF34584D),
                  width: active ? 1.6 : 1,
                ),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 12,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    player.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Chips.format(player.stack),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFB7C8C0),
                      fontSize: 11,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      status,
                      maxLines: 1,
                      style: TextStyle(
                        color: player.hasFolded
                            ? const Color(0xFFFF7A66)
                            : active
                            ? const Color(0xFF9FE0BF)
                            : const Color(0xFF6BE083),
                        fontSize: 10,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 8,
            child: _PlayerAvatar(
              label: player.name.replaceFirst('AI ', ''),
              active: active,
            ),
          ),
          if (badges.isNotEmpty)
            Positioned(
              left: 1,
              bottom: 2,
              child: _SeatBadge(label: badges.first),
            ),
          if (showCards)
            Positioned(
              right: 2,
              top: 8,
              child: Row(
                children: <Widget>[
                  _CardFace(card: player.holeCards[0], tiny: true),
                  const SizedBox(width: 3),
                  _CardFace(card: player.holeCards[1], tiny: true),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _seatStatus(ActionHistoryEntry? lastAction) {
    if (active) {
      final String bet = player.currentBet > 0
          ? ' ${Chips.format(player.currentBet)} in'
          : '';
      return 'To act$bet';
    }
    if (player.hasFolded) {
      return 'Fold';
    }
    if (lastAction != null) {
      return _seatActionLabel(lastAction);
    }
    if (player.isAllIn) {
      return 'All-in';
    }
    if (player.currentBet > 0) {
      return 'Bet ${Chips.format(player.currentBet)}';
    }
    return 'In hand';
  }
}

class _PlayerAvatar extends StatelessWidget {
  const _PlayerAvatar({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final int value = int.tryParse(label) ?? label.codeUnitAt(0);
    final List<Color> colors = <Color>[
      const Color(0xFF876D3D),
      const Color(0xFF536E7A),
      const Color(0xFF715F91),
      const Color(0xFF7A594B),
      const Color(0xFF486F5E),
      const Color(0xFF74694A),
    ];
    final Color color = colors[value % colors.length];
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[Color.lerp(color, Colors.white, 0.18)!, color],
        ),
        border: Border.all(
          color: active ? const Color(0xFFE0B85C) : const Color(0xFF2B3634),
          width: active ? 2 : 1,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x88000000),
            blurRadius: 10,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 14,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _FeltPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bool compact = size.width < 390;
    final double tableWidth = math.min(size.width * 0.72, compact ? 280 : 312);
    final double tableHeight = math.min(
      size.height * (size.height < 720 ? 0.60 : 0.66),
      590,
    );
    final double tableTop = math.max(86, size.height * 0.11);
    final Rect rail = Rect.fromCenter(
      center: Offset(size.width / 2, tableTop + tableHeight / 2),
      width: tableWidth,
      height: tableHeight,
    );
    final RRect railShape = RRect.fromRectAndRadius(
      rail,
      Radius.circular(rail.width / 2),
    );
    final Path shadowPath = Path()..addRRect(railShape);
    canvas.drawShadow(shadowPath, const Color(0xFF000000), 22, true);

    final Paint railPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0xFF3A3329),
          Color(0xFF171916),
          Color(0xFF47351D),
        ],
      ).createShader(rail);
    canvas.drawRRect(railShape, railPaint);

    final Paint goldStroke = Paint()
      ..color = const Color(0xFFE0B85C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rail.deflate(7),
        Radius.circular((rail.width - 14) / 2),
      ),
      goldStroke,
    );

    final Rect felt = rail.deflate(18);
    final RRect feltShape = RRect.fromRectAndRadius(
      felt,
      Radius.circular(felt.width / 2),
    );
    final Paint feltPaint = Paint()
      ..shader = const RadialGradient(
        center: Alignment(0, -0.38),
        radius: 0.92,
        colors: <Color>[
          Color(0xFF0F6D45),
          Color(0xFF06492F),
          Color(0xFF042B21),
        ],
      ).createShader(felt);
    canvas.drawRRect(feltShape, feltPaint);

    final Paint innerStroke = Paint()
      ..color = const Color(0x5536D79C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        felt.deflate(16),
        Radius.circular((felt.width - 32) / 2),
      ),
      innerStroke,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        felt.deflate(30),
        Radius.circular((felt.width - 60) / 2),
      ),
      innerStroke..color = const Color(0x2236D79C),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SeatBadge extends StatelessWidget {
  const _SeatBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF213C34),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF4C7669)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: const TextStyle(
          color: Color(0xFFE0B85C),
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _BoardCards extends StatelessWidget {
  const _BoardCards({required this.cards});

  final List<PlayingCard> cards;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List<Widget>.generate(5, (int index) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: _CardFace(card: index < cards.length ? cards[index] : null),
          );
        }),
      ),
    );
  }
}

class _CardFace extends StatelessWidget {
  const _CardFace({
    required this.card,
    this.compact = false,
    this.tiny = false,
  });

  final PlayingCard? card;
  final bool compact;
  final bool tiny;

  @override
  Widget build(BuildContext context) {
    final double width = tiny
        ? 22
        : compact
        ? 40
        : 44;
    final double height = tiny
        ? 32
        : compact
        ? 54
        : 58;
    final PlayingCard? value = card;
    final bool red = value?.suit == Suit.hearts || value?.suit == Suit.diamonds;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: value == null
            ? const Color(0xFF10382F)
            : const Color(0xFFF8F4E9),
        borderRadius: BorderRadius.circular(tiny ? 5 : 8),
        border: Border.all(
          color: value == null
              ? const Color(0xFF315348)
              : const Color(0xFFE6DDC8),
        ),
        boxShadow: value == null
            ? null
            : const <BoxShadow>[
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
      ),
      child: value == null
          ? Container(
              width: width * 0.42,
              height: 2,
              decoration: BoxDecoration(
                color: const Color(0xFF7AA092),
                borderRadius: BorderRadius.circular(999),
              ),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  value.rank.label,
                  style: TextStyle(
                    color: red
                        ? const Color(0xFFC92535)
                        : const Color(0xFF101416),
                    fontWeight: FontWeight.w900,
                    fontSize: tiny ? 10 : 15,
                    height: 0.95,
                  ),
                ),
                Text(
                  value.suit.symbol,
                  style: TextStyle(
                    color: red
                        ? const Color(0xFFC92535)
                        : const Color(0xFF101416),
                    fontSize: tiny ? 11 : 17,
                    height: 0.95,
                  ),
                ),
              ],
            ),
    );
  }
}

String? _streetInvestmentLabel(PlayerState player) {
  if (player.currentBet <= 0) {
    return null;
  }
  final String verb = player.isAllIn ? 'All-in' : 'Bet';
  return '$verb ${Chips.format(player.currentBet)}';
}

String _seatActionLabel(ActionHistoryEntry entry) {
  final String amount = entry.amount > 0
      ? ' ${Chips.format(entry.amount)}'
      : '';
  return switch (entry.action) {
    PokerActionType.fold => 'Fold',
    PokerActionType.check => 'Check',
    PokerActionType.call => 'Call$amount',
    PokerActionType.bet => 'Bet$amount',
    PokerActionType.raise => 'Raise$amount',
    PokerActionType.allIn => 'All-in$amount',
  };
}

String _compactActionLabel(ActionHistoryEntry entry) {
  return '${entry.phase.name}: ${entry.playerName} ${_actionText(entry)}';
}

String _actionText(ActionHistoryEntry entry) {
  final String amount = entry.amount > 0
      ? ' ${Chips.format(entry.amount)}'
      : '';
  return switch (entry.action) {
    PokerActionType.fold => 'folds',
    PokerActionType.check => 'checks',
    PokerActionType.call => 'calls$amount',
    PokerActionType.bet => 'bets$amount',
    PokerActionType.raise => 'raises to$amount',
    PokerActionType.allIn => 'is all-in$amount',
  };
}

int? _parseChips(String value) {
  final String normalized = value.trim().replaceAll(',', '');
  if (normalized.isEmpty) {
    return null;
  }
  final double? parsed = double.tryParse(normalized);
  if (parsed == null || parsed < 0) {
    return null;
  }
  return Chips.fromWhole(parsed);
}

String _phaseLabel(BettingPhase phase) {
  return switch (phase) {
    BettingPhase.waiting => 'waiting',
    BettingPhase.preflop => 'preflop',
    BettingPhase.flop => 'flop',
    BettingPhase.turn => 'turn',
    BettingPhase.river => 'river',
    BettingPhase.showdown => 'showdown',
    BettingPhase.handComplete => 'complete',
  };
}

extension _SuitSymbol on Suit {
  String get symbol {
    return switch (this) {
      Suit.clubs => '♣',
      Suit.diamonds => '♦',
      Suit.hearts => '♥',
      Suit.spades => '♠',
    };
  }
}
