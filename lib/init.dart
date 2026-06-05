import 'package:venera/foundation/bootstrap.dart';

Future<void> init() async {
  bootstrapController.start();
  await bootstrapController.waitForReady();
}
