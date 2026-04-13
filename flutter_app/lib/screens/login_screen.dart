import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import '../services/auth_provider.dart';
import '../theme/app_theme.dart';

// Landing/login screen with product branding and Google sign-in action.
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      body: Stack(
        children: [
          // Background gradient orbs
          Positioned(
            top: -100,
            left: -80,
            child: _GlowOrb(
                color: AuricTheme.brandBlue.withOpacity(0.25), size: 350),
          ),
          Positioned(
            bottom: -120,
            right: -80,
            child: _GlowOrb(
                color: AuricTheme.brandBlueDark.withOpacity(0.3), size: 300),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  const Spacer(flex: 2),

                  // Logo + Brand
                  Column(
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          gradient: AuricTheme.brandGradient,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: AuricTheme.brandBlue.withOpacity(0.4),
                              blurRadius: 30,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.calculate_rounded,
                            color: Colors.white, size: 40),
                      )
                          .animate()
                          .fadeIn(duration: 600.ms)
                          .scale(begin: const Offset(0.8, 0.8)),
                      const SizedBox(height: 20),
                      Text(
                        'Auric',
                        style:
                            Theme.of(context).textTheme.displayMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1.5,
                                ),
                      )
                          .animate()
                          .fadeIn(delay: 200.ms, duration: 500.ms)
                          .slideY(begin: 0.2),
                      const SizedBox(height: 8),
                      Text(
                        'AI-Powered Calculator',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: isDark
                                  ? AuricTheme.darkSubtext
                                  : AuricTheme.lightSubtext,
                            ),
                      ).animate().fadeIn(delay: 350.ms, duration: 500.ms),
                    ],
                  ),

                  const Spacer(flex: 2),

                  // Feature Highlights
                  Column(
                    children: [
                      _FeatureRow(
                        icon: Icons.calculate_outlined,
                        title: 'Scientific Calculator',
                        subtitle: 'With full history & scientific modes',
                        isDark: isDark,
                      ).animate().fadeIn(delay: 450.ms).slideX(begin: -0.1),
                      const SizedBox(height: 12),
                      _FeatureRow(
                        icon: Icons.auto_awesome_rounded,
                        title: 'AI Chat Assistant',
                        subtitle: 'Powered by OpenAI GPT-5.4 mini',
                        isDark: isDark,
                      ).animate().fadeIn(delay: 550.ms).slideX(begin: -0.1),
                      const SizedBox(height: 12),
                      _FeatureRow(
                        icon: Icons.image_outlined,
                        title: 'Vision Support',
                        subtitle: 'Send images to the AI',
                        isDark: isDark,
                      ).animate().fadeIn(delay: 650.ms).slideX(begin: -0.1),
                    ],
                  ),

                  const Spacer(flex: 1),

                  // Sign In Button
                  if (auth.error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        auth.error!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ),

                  _GoogleSignInButton(
                    isLoading: auth.isLoading,
                    onPressed: () =>
                        context.read<AuthProvider>().signInWithGoogle(),
                  ).animate().fadeIn(delay: 700.ms).slideY(begin: 0.3),

                  const SizedBox(height: 16),

                  Text(
                    'By signing in, you agree to our Terms of Service\nand Privacy Policy',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? AuricTheme.darkMuted
                              : AuricTheme.lightSubtext,
                        ),
                  ).animate().fadeIn(delay: 800.ms),

                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  final Color color;
  final double size;
  const _GlowOrb({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, color.withOpacity(0)],
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isDark;

  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AuricTheme.glassCard(isDark: isDark),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: AuricTheme.brandGradient,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontSize: 15)),
                Text(subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GoogleSignInButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onPressed;

  const _GoogleSignInButton({required this.isLoading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AuricTheme.brandBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.white),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: Text(
                        'G',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF4285F4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Continue with Google',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white),
                  ),
                ],
              ),
      ),
    );
  }
}
