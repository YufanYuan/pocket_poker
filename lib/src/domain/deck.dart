import 'dart:math';

import 'card.dart';

class Deck {
  Deck({Random? random}) : _random = random ?? Random() {
    reset();
  }

  final Random _random;
  final List<PlayingCard> _cards = <PlayingCard>[];

  int get remaining => _cards.length;

  void reset() {
    _cards
      ..clear()
      ..addAll(
        Suit.values.expand(
          (Suit suit) =>
              Rank.values.map((Rank rank) => PlayingCard(rank, suit)),
        ),
      )
      ..shuffle(_random);
  }

  PlayingCard draw() {
    if (_cards.isEmpty) {
      throw StateError('Cannot draw from an empty deck.');
    }
    return _cards.removeLast();
  }

  List<PlayingCard> drawMany(int count) {
    return List<PlayingCard>.generate(count, (_) => draw(), growable: false);
  }
}
