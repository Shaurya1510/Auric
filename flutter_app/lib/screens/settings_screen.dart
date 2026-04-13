import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../services/settings_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static final ApiService _api = ApiService();
  Future<UsageStats>? _usageFuture;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isLoggedIn = context.read<AuthProvider>().isLoggedIn;
    if (isLoggedIn && _usageFuture == null) {
      _usageFuture = _api.getUsageStats();
    }
  }

  void _refreshUsage() {
    if (!context.read<AuthProvider>().isLoggedIn) return;
    setState(() {
      _usageFuture = _api.getUsageStats();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            HapticFeedback.selectionClick();
            Navigator.pop(context);
          },
          color: isDark ? AuricTheme.darkText : AuricTheme.lightText,
        ),
      ),
      body: Stack(
        children: [
          // Background
          Positioned.fill(
            child: Container(
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
          ),

          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                // ─── Account ─────────────────────────────

                _SectionLabel('Account', isDark: isDark),
                const SizedBox(height: 8),

                GlassCard(
                  isDark: isDark,
                  padding: const EdgeInsets.all(16),
                  child: auth.isLoggedIn
                      ? Row(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                gradient: AuricTheme.brandGradient,
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: [
                                  BoxShadow(
                                    color:
                                        AuricTheme.brandBlue.withOpacity(0.3),
                                    blurRadius: 12,
                                  )
                                ],
                              ),
                              child: Center(
                                child: Text(
                                  auth.user?.initials ?? 'U',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 20,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    auth.user?.name ?? '',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontSize: 16),
                                  ),
                                  Text(
                                    auth.user?.email ?? '',
                                    style:
                                        Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.logout_rounded,
                                  color: Colors.redAccent),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                    title: const Text('Sign out'),
                                    content: const Text(
                                        'Are you sure you want to sign out?'),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('Cancel')),
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('Sign out',
                                              style: TextStyle(
                                                  color: Colors.redAccent))),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  if (!context.mounted) return;
                                  await context.read<AuthProvider>().signOut();
                                }
                              },
                            ),
                          ],
                        )
                      : ElevatedButton.icon(
                          onPressed: () =>
                              context.read<AuthProvider>().signInWithGoogle(),
                          icon: const Icon(Icons.login_rounded),
                          label: const Text('Sign in with Google'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AuricTheme.brandBlue,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                ).animate().fadeIn(delay: 100.ms).slideY(begin: 0.05),

                const SizedBox(height: 24),

                // ─── Appearance ───────────────────────────

                _SectionLabel('Appearance', isDark: isDark),
                const SizedBox(height: 8),

                GlassCard(
                  isDark: isDark,
                  padding: const EdgeInsets.all(6),
                  child: Row(
                    children: [
                      _ThemeOption(
                        label: 'Dark',
                        icon: Icons.dark_mode_rounded,
                        isSelected: isDark,
                        isDark: isDark,
                        onTap: () {
                          if (!isDark) settings.toggleTheme();
                        },
                      ),
                      _ThemeOption(
                        label: 'Light',
                        icon: Icons.light_mode_rounded,
                        isSelected: !isDark,
                        isDark: isDark,
                        onTap: () {
                          if (isDark) settings.toggleTheme();
                        },
                      ),
                    ],
                  ),
                ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.05),

                const SizedBox(height: 24),

                // ─── AI Preferences ───────────────────────

                _SectionLabel('AI Preferences', isDark: isDark),
                const SizedBox(height: 8),

                GlassCard(
                  isDark: isDark,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      _SettingsRow(
                        icon: Icons.language_rounded,
                        title: 'Language',
                        trailing: Text('English',
                            style: TextStyle(
                                color: AuricTheme.brandBlue,
                                fontWeight: FontWeight.w600)),
                        isDark: isDark,
                      ),
                    ],
                  ),
                ).animate().fadeIn(delay: 300.ms).slideY(begin: 0.05),

                const SizedBox(height: 24),

                // ─── Usage ────────────────────────────────

                _SectionLabel('Usage', isDark: isDark),
                const SizedBox(height: 8),

                if (!auth.isLoggedIn)
                  GlassCard(
                    isDark: isDark,
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Sign in to view your token usage.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ).animate().fadeIn(delay: 350.ms).slideY(begin: 0.05)
                else
                  FutureBuilder<UsageStats>(
                    future: _usageFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return GlassCard(
                          isDark: isDark,
                          padding: const EdgeInsets.all(16),
                          child: const SizedBox(
                            height: 40,
                            child: Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          ),
                        );
                      }

                      if (snapshot.hasError || !snapshot.hasData) {
                        return GlassCard(
                          isDark: isDark,
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Could not load usage stats.',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                              TextButton(
                                onPressed: _refreshUsage,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        );
                      }

                      return _UsageCard(
                        usage: snapshot.data!,
                        isDark: isDark,
                        onRefresh: _refreshUsage,
                      );
                    },
                  ).animate().fadeIn(delay: 350.ms).slideY(begin: 0.05),

                const SizedBox(height: 24),

                // ─── About ────────────────────────────────

                _SectionLabel('About', isDark: isDark),
                const SizedBox(height: 8),

                GlassCard(
                  isDark: isDark,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      _SettingsRow(
                        icon: Icons.info_outline_rounded,
                        title: 'Version',
                        trailing: Text('1.0.0',
                            style: TextStyle(
                                color: isDark
                                    ? AuricTheme.darkSubtext
                                    : AuricTheme.lightSubtext)),
                        isDark: isDark,
                      ),
                      _Divider(isDark: isDark),
                      _SettingsRow(
                        icon: Icons.policy_outlined,
                        title: 'Privacy Policy',
                        trailing: Icon(Icons.arrow_forward_ios_rounded,
                            size: 14,
                            color: isDark
                                ? AuricTheme.darkMuted
                                : AuricTheme.lightSubtext),
                        isDark: isDark,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const _LegalPage(
                                title: 'Privacy Policy',
                                body: _privacyPolicyText,
                              ),
                            ),
                          );
                        },
                      ),
                      _Divider(isDark: isDark),
                      _SettingsRow(
                        icon: Icons.description_outlined,
                        title: 'Terms of Service',
                        trailing: Icon(Icons.arrow_forward_ios_rounded,
                            size: 14,
                            color: isDark
                                ? AuricTheme.darkMuted
                                : AuricTheme.lightSubtext),
                        isDark: isDark,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const _LegalPage(
                                title: 'Terms of Service',
                                body: _termsOfServiceText,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.05),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final bool isDark;

  const _SectionLabel(this.text, {required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
        color: isDark ? AuricTheme.darkMuted : AuricTheme.lightSubtext,
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;

  const _ThemeOption({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: 200.ms,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? (isDark ? Colors.white.withOpacity(0.1) : Colors.white)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            boxShadow: isSelected && !isDark
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 8,
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 18,
                  color: isSelected
                      ? (isDark ? Colors.white : AuricTheme.lightText)
                      : (isDark
                          ? AuricTheme.darkMuted
                          : AuricTheme.lightSubtext)),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected
                      ? (isDark ? Colors.white : AuricTheme.lightText)
                      : (isDark
                          ? AuricTheme.darkMuted
                          : AuricTheme.lightSubtext),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UsageCard extends StatelessWidget {
  final UsageStats usage;
  final bool isDark;
  final VoidCallback onRefresh;

  const _UsageCard({
    required this.usage,
    required this.isDark,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final pct = usage.unlimited
        ? 0.0
        : (usage.usagePercent / 100).clamp(0.0, 1.0).toDouble();
    final pctLabel = usage.unlimited
        ? 'Unlimited'
        : '${usage.usagePercent.toStringAsFixed(1)}%';
    final used = usage.usedTokens.toString();
    final limit = usage.unlimited ? 'unlimited' : usage.limitTokens.toString();
    final remaining =
        usage.unlimited ? 'unlimited' : usage.remainingTokens.toString();

    return GlassCard(
      isDark: isDark,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Token Usage',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontSize: 16),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                onPressed: onRefresh,
                tooltip: 'Refresh',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$pctLabel used in last ${usage.windowHours}h window',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: usage.unlimited ? null : pct,
              backgroundColor:
                  (isDark ? Colors.white : Colors.black).withOpacity(0.12),
              valueColor: AlwaysStoppedAnimation<Color>(
                pct > 0.85 ? Colors.redAccent : AuricTheme.brandBlue,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Used: $used   •   Remaining: $remaining   •   Limit: $limit',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget trailing;
  final bool isDark;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.trailing,
    required this.isDark,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AuricTheme.brandBlue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: AuricTheme.brandBlue, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontSize: 15)),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  final bool isDark;
  const _Divider({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 64,
      endIndent: 16,
      color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
    );
  }
}

class _LegalPage extends StatelessWidget {
  final String title;
  final String body;

  const _LegalPage({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Text(
          body,
          style: TextStyle(
            fontSize: 14,
            height: 1.6,
            color: isDark ? AuricTheme.darkText : AuricTheme.lightText,
          ),
        ),
      ),
    );
  }
}

const String _privacyPolicyText = 'Privacy Policy\n\n'
    'Last updated: March 2026\n\n'
    'Auric is designed to help with math, science, and AI chat. We collect only what is needed to operate core features.\n\n'
    '1. Data We Process\n'
    '- Account data: name, email, and profile image if you sign in with Google.\n'
    '- App content: chat messages, uploaded images, and calculator history you create in the app.\n'
    '- Technical data: basic logs for reliability, performance, and security.\n\n'
    '2. How We Use Data\n'
    '- To provide chat, image analysis, and history/session features.\n'
    '- To improve response quality, safety, and app stability.\n'
    '- To protect against abuse and unauthorized access.\n\n'
    '3. AI Processing\n'
    '- Your prompts may be sent to third-party AI providers required to generate responses.\n'
    '- Do not upload sensitive personal, financial, or medical information unless necessary.\n\n'
    '4. Storage and Retention\n'
    '- Chat/history data is stored to support session continuity and user features.\n'
    '- You can remove stored sessions/history from inside the app where supported.\n\n'
    '5. Security\n'
    '- We apply reasonable technical safeguards, but no system is 100% secure.\n\n'
    '6. Your Choices\n'
    '- You can sign out at any time.\n'
    '- You can request deletion/export features in future versions.\n\n'
    '7. Contact\n'
    '- For policy questions, contact the Auric support channel used for this project.';

const String _termsOfServiceText = 'Terms of Service\n\n'
    'Last updated: March 2026\n\n'
    'By using Auric, you agree to the following terms.\n\n'
    '1. Use of Service\n'
    '- Auric is an educational and productivity assistant.\n'
    '- You are responsible for how you use generated content.\n\n'
    '2. Accuracy and Verification\n'
    '- AI responses can be incomplete or incorrect.\n'
    '- Always verify important outputs, especially for exams, legal, medical, or financial decisions.\n\n'
    '3. Acceptable Use\n'
    '- Do not use Auric for illegal, abusive, or harmful activities.\n'
    '- Do not attempt to exploit or disrupt the service.\n\n'
    '4. Accounts\n'
    '- If you sign in, you are responsible for your account activity.\n\n'
    '5. Content\n'
    '- You retain ownership of your input content.\n'
    '- You grant the service permission to process your content to provide app functionality.\n\n'
    '6. Availability\n'
    '- Features may change, be updated, or be temporarily unavailable without prior notice.\n\n'
    '7. Limitation of Liability\n'
    '- The service is provided "as is" without warranties.\n'
    '- Auric is not liable for losses resulting from reliance on AI output.\n\n'
    '8. Updates to Terms\n'
    '- These terms may be updated. Continued use means you accept revised terms.';
