import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../providers/providers.dart';
import 'home_screen.dart';
import 'my_material_screen.dart';
import 'shorts_screen.dart';

/// Home (long-form), Shorts, and My Material. Search arrives in Phase E.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  Timer? _daily;

  @override
  void initState() {
    super.initState();
    // §6.5 daily job: archive materials whose exam date has passed (at start, then daily).
    WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(materialControllerProvider.notifier).autoArchive());
    _daily = Timer.periodic(
        const Duration(hours: 24), (_) => ref.read(materialControllerProvider.notifier).autoArchive());
  }

  @override
  void dispose() {
    _daily?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(tabProvider);
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: [
          const HomeScreen(),
          // Shorts only plays while its tab is visible.
          ShortsScreen(active: index == 1),
          const MyMaterialScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: ref.read(tabProvider.notifier).select,
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home), label: t('nav.home')),
          NavigationDestination(
              icon: const Icon(Icons.slow_motion_video_outlined),
              selectedIcon: const Icon(Icons.slow_motion_video),
              label: t('nav.shorts')),
          NavigationDestination(
              icon: const Icon(Icons.menu_book_outlined), selectedIcon: const Icon(Icons.menu_book), label: t('nav.material')),
        ],
      ),
    );
  }
}
