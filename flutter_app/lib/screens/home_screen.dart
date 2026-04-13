import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import 'dart:math' as math;
import '../theme/app_theme.dart';
import '../services/auth_provider.dart';
import 'calculator_screen.dart';
import 'ai_chat_screen.dart';
import 'settings_screen.dart';

// Main post-login shell:
// hosts calculator + AI chat and central settings access.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  int _currentIndex = 0;
  int _previousIndex = 0;

  void _toggleScreen() {
    HapticFeedback.mediumImpact();
    setState(() {
      _previousIndex = _currentIndex;
      _currentIndex = _currentIndex == 0 ? 1 : 0;
    });
  }

  Future<void> _openSettings() async {
    HapticFeedback.selectionClick();
    await Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => const SettingsScreen(),
        transitionsBuilder: (_, animation, __, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: Tween<double>(begin: 0.0, end: 1.0).animate(curved),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.03),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // Background
          Positioned.fill(child: _Background(isDark: isDark)),

          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                children: [
                  ...previousChildren,
                  if (currentChild != null) currentChild,
                ],
              );
            },
            transitionBuilder: (child, animation) {
              final enteringFromRight = _currentIndex > _previousIndex;
              final begin = enteringFromRight
                  ? const Offset(0.05, 0)
                  : const Offset(-0.05, 0);
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(begin: begin, end: Offset.zero)
                      .animate(animation),
                  child: child,
                ),
              );
            },
            child: KeyedSubtree(
              key: ValueKey(_currentIndex),
              child: _currentIndex == 0
                  ? CalculatorScreen(onSwitch: _toggleScreen)
                  : AiChatScreen(onSwitch: _toggleScreen),
            ),
          ),

          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 16,
            child: _SettingsOrb(
              isDark: isDark,
              label: auth.user?.initials ?? 'S',
              onTap: _openSettings,
            ),
          ),
        ],
      ),
      // NO bottomNavigationBar – removed intentionally
    );
  }
}

// ─────────────────────────────────────────────
//  App Bar with animated toggle pill
// ─────────────────────────────────────────────
// ignore: unused_element
class _AppBar extends StatelessWidget {
  final String currentLabel;
  final String nextLabel;
  final bool isDark;
  final dynamic user;
  final VoidCallback onToggle;
  final VoidCallback onSettings;
  final AnimationController pillController;

  const _AppBar({
    required this.currentLabel,
    required this.nextLabel,
    required this.isDark,
    required this.user,
    required this.onToggle,
    required this.onSettings,
    required this.pillController,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(
          children: [
            const SizedBox(width: 50),
            Expanded(
              child: Center(
                child: _TogglePill(
                  currentLabel: currentLabel,
                  nextLabel: nextLabel,
                  isDark: isDark,
                  onToggle: onToggle,
                  controller: pillController,
                ),
              ),
            ),
            _SettingsOrb(
              isDark: isDark,
              label: user?.initials ?? 'S',
              onTap: onSettings,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  The clickable animated pill in the center
// ─────────────────────────────────────────────
class _TogglePill extends StatefulWidget {
  final String currentLabel;
  final String nextLabel;
  final bool isDark;
  final VoidCallback onToggle;
  final AnimationController controller;

  const _TogglePill({
    required this.currentLabel,
    required this.nextLabel,
    required this.isDark,
    required this.onToggle,
    required this.controller,
  });

  @override
  State<_TogglePill> createState() => _TogglePillState();
}

class _TogglePillState extends State<_TogglePill>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2400))
      ..repeat();
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Scale bounce: 1 → 0.93 → 1
    final scaleAnim = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.93)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 35),
      TweenSequenceItem(
          tween: Tween(begin: 0.93, end: 1.04)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 35),
      TweenSequenceItem(
          tween: Tween(begin: 1.04, end: 1.0)
              .chain(CurveTween(curve: Curves.elasticOut)),
          weight: 30),
    ]).animate(widget.controller);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onToggle();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, child) => Transform.scale(
          scale: scaleAnim.value,
          child: child,
        ),
        child: AnimatedOpacity(
          duration: 160.ms,
          opacity: _pressed ? 0.78 : 1,
          child: AnimatedBuilder(
            animation: _glowController,
            builder: (context, _) {
              return CustomPaint(
                painter: _OrbitGlowPainter(
                  progress: _glowController.value,
                  isDark: widget.isDark,
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 26, vertical: 10),
                  child: AnimatedSwitcher(
                    duration: 260.ms,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.3),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(
                            parent: anim, curve: Curves.easeOutCubic)),
                        child: child,
                      ),
                    ),
                    child: _GlowingFlowText(
                      text: widget.currentLabel,
                      key: ValueKey(widget.currentLabel),
                      progress: _glowController.value,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _OrbitGlowPainter extends CustomPainter {
  final double progress;
  final bool isDark;

  _OrbitGlowPainter({required this.progress, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final rx = (size.width / 2) - 8;
    final ry = (size.height / 2) - 5;

    final theta = progress * math.pi * 2;
    final px = cx + rx * math.cos(theta);
    final py = cy + ry * math.sin(theta);
    const lineLen = 22.0;
    final p1 = Offset(px - (lineLen / 2), py);
    final p2 = Offset(px + (lineLen / 2), py);

    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.2
      ..color = AuricTheme.brandBlueLight.withOpacity(isDark ? 0.95 : 0.9)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.5);

    final corePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.2
      ..color = Colors.white.withOpacity(0.95);

    canvas.drawLine(p1, p2, glowPaint);
    canvas.drawLine(p1, p2, corePaint);
  }

  @override
  bool shouldRepaint(covariant _OrbitGlowPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.isDark != isDark;
  }
}

class _GlowingFlowText extends StatelessWidget {
  final String text;
  final double progress;

  const _GlowingFlowText(
      {required this.text, required this.progress, super.key});

  @override
  Widget build(BuildContext context) {
    final baseStyle = TextStyle(
      color: Colors.white.withOpacity(0.88),
      fontSize: 34,
      fontWeight: FontWeight.w700,
      fontStyle: FontStyle.italic,
      fontFamily: 'serif',
      letterSpacing: -0.8,
      shadows: [
        Shadow(
          color: Colors.white.withOpacity(0.18),
          blurRadius: 8,
        ),
      ],
    );

    return Stack(
      alignment: Alignment.center,
      children: [
        Text(text, style: baseStyle),
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            final p = progress;
            final s1 = (p - 0.20).clamp(0.0, 1.0);
            final s2 = (p - 0.06).clamp(0.0, 1.0);
            final s3 = (p + 0.06).clamp(0.0, 1.0);
            final s4 = (p + 0.20).clamp(0.0, 1.0);

            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Colors.white.withOpacity(0.15),
                Colors.white.withOpacity(0.55),
                AuricTheme.brandBlueLight.withOpacity(0.98),
                Colors.white.withOpacity(0.55),
                Colors.white.withOpacity(0.15),
              ],
              stops: [s1, s2, p, s3, s4],
            ).createShader(bounds);
          },
          child: Text(
            text,
            style: baseStyle.copyWith(
              color: Colors.white,
              shadows: [
                Shadow(
                  color: AuricTheme.brandBlue.withOpacity(0.55),
                  blurRadius: 16,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingsOrb extends StatefulWidget {
  final bool isDark;
  final String label;
  final VoidCallback onTap;

  const _SettingsOrb({
    required this.isDark,
    required this.label,
    required this.onTap,
  });

  @override
  State<_SettingsOrb> createState() => _SettingsOrbState();
}

class _SettingsOrbState extends State<_SettingsOrb> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      child: AnimatedContainer(
        duration: 180.ms,
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: _pressed
              ? AuricTheme.brandBlue.withOpacity(0.92)
              : (widget.isDark ? Colors.white : Colors.white).withOpacity(0.1),
          shape: BoxShape.circle,
          border: Border.all(
            color: _pressed
                ? AuricTheme.brandBlueLight.withOpacity(0.95)
                : (widget.isDark ? Colors.white : Colors.white)
                    .withOpacity(0.26),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: AuricTheme.brandBlue.withOpacity(_pressed ? 0.4 : 0.12),
              blurRadius: _pressed ? 16 : 8,
            ),
          ],
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 17,
            ),
          ),
        ),
      ),
    );
  }
}

class _Background extends StatelessWidget {
  final bool isDark;
  const _Background({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: isDark
                ? AuricTheme.darkBgGradient
                : const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF99CCFF), Color(0xFFCCE5FF)],
                  ),
          ),
        ),
        Positioned(
          top: -100,
          left: -50,
          child: Container(
            width: MediaQuery.of(context).size.width * 0.7,
            height: MediaQuery.of(context).size.width * 0.7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AuricTheme.brandBlue.withOpacity(isDark ? 0.15 : 0.25),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: -100,
          right: -50,
          child: Container(
            width: MediaQuery.of(context).size.width * 0.7,
            height: MediaQuery.of(context).size.width * 0.7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AuricTheme.brandBlueDark.withOpacity(isDark ? 0.2 : 0.15),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
