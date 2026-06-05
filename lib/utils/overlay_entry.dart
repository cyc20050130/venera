import 'package:flutter/widgets.dart';

void removeAndDisposeOverlayEntry(OverlayEntry entry) {
  entry.remove();
  entry.dispose();
}
