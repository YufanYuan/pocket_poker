import 'card.dart';

enum HandCategory {
  highCard('High card'),
  onePair('One pair'),
  twoPair('Two pair'),
  threeOfAKind('Three of a kind'),
  straight('Straight'),
  flush('Flush'),
  fullHouse('Full house'),
  fourOfAKind('Four of a kind'),
  straightFlush('Straight flush');

  const HandCategory(this.label);

  final String label;
}

class HandValue implements Comparable<HandValue> {
  const HandValue(this.category, this.kickers);

  final HandCategory category;
  final List<int> kickers;

  @override
  int compareTo(HandValue other) {
    final int categoryCompare = category.index.compareTo(other.category.index);
    if (categoryCompare != 0) {
      return categoryCompare;
    }
    for (int i = 0; i < kickers.length && i < other.kickers.length; i += 1) {
      final int kickerCompare = kickers[i].compareTo(other.kickers[i]);
      if (kickerCompare != 0) {
        return kickerCompare;
      }
    }
    return kickers.length.compareTo(other.kickers.length);
  }

  @override
  String toString() => '${category.label} ${kickers.join('-')}';
}

class HandEvaluator {
  const HandEvaluator._();

  static HandValue bestOf(List<PlayingCard> cards) {
    if (cards.length < 5) {
      throw ArgumentError.value(
        cards.length,
        'cards.length',
        'Need at least 5 cards.',
      );
    }

    HandValue? best;
    for (final List<PlayingCard> combo in _fiveCardCombinations(cards)) {
      final HandValue value = _evaluateFive(combo);
      if (best == null || value.compareTo(best) > 0) {
        best = value;
      }
    }
    return best!;
  }

  static HandValue _evaluateFive(List<PlayingCard> cards) {
    final List<int> ranks =
        cards.map((PlayingCard card) => card.rank.value).toList()
          ..sort((int a, int b) => b.compareTo(a));
    final Map<int, int> counts = <int, int>{};
    for (final int rank in ranks) {
      counts[rank] = (counts[rank] ?? 0) + 1;
    }

    final bool flush = cards.every(
      (PlayingCard card) => card.suit == cards.first.suit,
    );
    final int? straightHigh = _straightHigh(ranks);
    if (flush && straightHigh != null) {
      return HandValue(HandCategory.straightFlush, <int>[straightHigh]);
    }

    final List<int> quads = _ranksWithCount(counts, 4);
    if (quads.isNotEmpty) {
      final int kicker = ranks.firstWhere((int rank) => rank != quads.first);
      return HandValue(HandCategory.fourOfAKind, <int>[quads.first, kicker]);
    }

    final List<int> trips = _ranksWithCount(counts, 3);
    final List<int> pairs = _ranksWithCount(counts, 2);
    if (trips.isNotEmpty && (pairs.isNotEmpty || trips.length > 1)) {
      final int pairRank = pairs.isNotEmpty ? pairs.first : trips[1];
      return HandValue(HandCategory.fullHouse, <int>[trips.first, pairRank]);
    }

    if (flush) {
      return HandValue(HandCategory.flush, ranks);
    }

    if (straightHigh != null) {
      return HandValue(HandCategory.straight, <int>[straightHigh]);
    }

    if (trips.isNotEmpty) {
      final List<int> kickers = ranks
          .where((int rank) => rank != trips.first)
          .toList();
      return HandValue(HandCategory.threeOfAKind, <int>[
        trips.first,
        ...kickers,
      ]);
    }

    if (pairs.length >= 2) {
      final List<int> topPairs = pairs.take(2).toList();
      final int kicker = ranks.firstWhere(
        (int rank) => !topPairs.contains(rank),
      );
      return HandValue(HandCategory.twoPair, <int>[...topPairs, kicker]);
    }

    if (pairs.length == 1) {
      final int pair = pairs.first;
      final List<int> kickers = ranks
          .where((int rank) => rank != pair)
          .toList();
      return HandValue(HandCategory.onePair, <int>[pair, ...kickers]);
    }

    return HandValue(HandCategory.highCard, ranks);
  }

  static List<int> _ranksWithCount(Map<int, int> counts, int count) {
    return counts.entries
        .where((MapEntry<int, int> entry) => entry.value == count)
        .map((MapEntry<int, int> entry) => entry.key)
        .toList()
      ..sort((int a, int b) => b.compareTo(a));
  }

  static int? _straightHigh(List<int> ranks) {
    final Set<int> rankSet = ranks.toSet();
    final List<int> unique = rankSet.toList()
      ..sort((int a, int b) => b.compareTo(a));
    if (rankSet.contains(14)) {
      unique.add(1);
    }

    int runLength = 1;
    for (int i = 1; i < unique.length; i += 1) {
      if (unique[i - 1] - 1 == unique[i]) {
        runLength += 1;
        if (runLength >= 5) {
          return unique[i - 4];
        }
      } else {
        runLength = 1;
      }
    }
    return null;
  }

  static Iterable<List<PlayingCard>> _fiveCardCombinations(
    List<PlayingCard> cards,
  ) sync* {
    for (int a = 0; a < cards.length - 4; a += 1) {
      for (int b = a + 1; b < cards.length - 3; b += 1) {
        for (int c = b + 1; c < cards.length - 2; c += 1) {
          for (int d = c + 1; d < cards.length - 1; d += 1) {
            for (int e = d + 1; e < cards.length; e += 1) {
              yield <PlayingCard>[
                cards[a],
                cards[b],
                cards[c],
                cards[d],
                cards[e],
              ];
            }
          }
        }
      }
    }
  }
}
