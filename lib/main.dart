import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'services/cpap_repository.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ko');
  final repo = await CpapRepository.create();
  runApp(CpapApp(repo: repo));
}

class CpapApp extends StatelessWidget {
  const CpapApp({super.key, required this.repo});
  final CpapRepository repo;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2B6CB0);
    return MaterialApp(
      title: 'CPAP EzShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: HomeScreen(repo: repo),
    );
  }
}
