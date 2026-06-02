import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bootstrap.dart';
import 'package:venera/pages/main_page.dart';

void main() {
  test('main page first frame marks the app interactive', () async {
    final controller = BootstrapController(
      startupInteractionProtectionWindow: Duration.zero,
    );
    final events = <String>[];

    markMainPageFirstFrameInteractive(controller, logEvent: events.add);

    expect(events, ['main page visible']);
    expect(controller.homeInteractive, isTrue);
    await expectLater(controller.waitForHomeInteractive(), completes);
  });
}
