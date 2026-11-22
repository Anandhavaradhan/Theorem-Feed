import 'package:material_ui/material_ui.dart';

import 'core/i18n.dart';
import 'core/theme.dart';
import 'screens/app_shell.dart';

class TheoremFeedApp extends StatelessWidget {
  const TheoremFeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: t('app.title'),
      debugShowCheckedModeBanner: false,
      locale: const Locale('en', 'US'),
      supportedLocales: const [Locale('en', 'US')],
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const AppShell(),
    );
  }
}
