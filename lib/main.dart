import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ProviderScope(
    child: BranchPilotApp(initialRepoPaths: args),
  ));
}
