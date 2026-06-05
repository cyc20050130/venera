import 'package:flutter/material.dart';

TabController replaceOwnedTabController({
  required TabController previous,
  required int length,
  required TickerProvider vsync,
}) {
  final next = TabController(length: length, vsync: vsync);
  previous.dispose();
  return next;
}
