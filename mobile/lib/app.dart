import 'package:material_ui/material_ui.dart';

import 'core/i18n.dart';
import 'screens/home_screen.dart';

class TheoremFeedApp extends StatelessWidget {
  const TheoremFeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: t('app.title'),
      debugShowCheckedModeBanner: false,
      locale: const Locale('en', 'US'),
      supportedLocales: const [Locale('en', 'US')],
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3F4A8A), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF3F4A8A), brightness: Brightness.dark, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}
