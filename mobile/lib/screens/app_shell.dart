import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import 'home_screen.dart';
import 'shorts_screen.dart';

/// Home (long-form) and Shorts. Search and My Material arrive in later phases.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          const HomeScreen(),
          // Shorts only plays while its tab is visible.
          ShortsScreen(active: _index == 1),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home), label: t('nav.home')),
          NavigationDestination(
              icon: const Icon(Icons.slow_motion_video_outlined), selectedIcon: const Icon(Icons.slow_motion_video), label: t('nav.shorts')),
        ],
      ),
    );
  }
}
