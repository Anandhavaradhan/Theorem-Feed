import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../providers/providers.dart';
import 'home_screen.dart';
import 'my_material_screen.dart';
import 'shorts_screen.dart';
import 'you_screen.dart';

/// Bottom bar laid out like a video app: Home, Shorts, a round "+" (upload a
/// PDF), My Material, You. Search lives in the top bar.
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(materialControllerProvider.notifier).autoArchive();
      // English only: drop videos added before the stricter checks (background, once each).
      unawaited(ref.read(ingestionControllerProvider.notifier).recheckLanguages().catchError((_) {}));
    });
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
    final select = ref.read(tabProvider.notifier).select;
    final shorts = index == shortsTab;
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: [
          const HomeScreen(),
          // Shorts only plays while its tab is visible.
          ShortsScreen(active: shorts),
          const MyMaterialScreen(),
          const YouScreen(),
        ],
      ),
      bottomNavigationBar: _BottomBar(
        index: index,
        dark: shorts, // Shorts uses a black bar, like full-screen video apps
        onSelect: select,
        onCreate: () {
          select(materialTab);
          ref.read(materialControllerProvider.notifier).pickAndUpload();
        },
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.dark, required this.onSelect, required this.onCreate});
  final int index;
  final bool dark;
  final void Function(int) onSelect;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = dark ? Colors.black : theme.scaffoldBackgroundColor;
    final fg = dark ? Colors.white : theme.colorScheme.onSurface;
    Widget item(int tab, IconData icon, IconData selectedIcon, String label) => Expanded(
          child: InkResponse(
            onTap: () => onSelect(tab),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(index == tab ? selectedIcon : icon, color: fg, size: 24),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(color: fg, fontSize: 10)),
            ]),
          ),
        );
    return Material(
      color: bg,
      child: SafeArea(
        top: false,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: dark ? Colors.white12 : theme.colorScheme.outlineVariant, width: 0.5)),
          ),
          child: Row(children: [
            item(homeTab, Icons.home_outlined, Icons.home, t('nav.home')),
            item(shortsTab, Icons.slow_motion_video_outlined, Icons.slow_motion_video, t('nav.shorts')),
            Expanded(
              child: Center(
                child: InkResponse(
                  onTap: onCreate,
                  child: Tooltip(
                    message: t('nav.create'),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: fg, width: 1.2)),
                      child: Icon(Icons.add, color: fg, size: 28),
                    ),
                  ),
                ),
              ),
            ),
            item(materialTab, Icons.menu_book_outlined, Icons.menu_book, t('nav.material')),
            item(youTab, Icons.account_circle_outlined, Icons.account_circle, t('nav.you')),
          ]),
        ),
      ),
    );
  }
}
