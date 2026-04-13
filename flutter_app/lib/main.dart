import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'services/auth_provider.dart';
import 'services/settings_provider.dart';
import 'services/api_service.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';

// App bootstrap:
// - load runtime environment
// - configure API base URL
// - register global providers
// - route to login/home based on auth state
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables from .env
  await dotenv.load(fileName: ".env");

  // Configure API base URL from .env (fallback to emulator localhost)
  final baseUrl = dotenv.env['API_BASE_URL'];
  final normalizedBaseUrl = baseUrl?.trim();
  if (normalizedBaseUrl != null && normalizedBaseUrl.isNotEmpty) {
    ApiService.baseUrl = normalizedBaseUrl.replaceAll(RegExp(r'/+$'), '');
  }

  // Full-screen immersive experience
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const AuricApp());
}

class AuricApp extends StatelessWidget {
  const AuricApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()..tryAutoLogin()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
      ],
      child: Consumer2<SettingsProvider, AuthProvider>(
        builder: (context, settings, auth, _) {
          return MaterialApp(
            title: 'Auric',
            debugShowCheckedModeBanner: false,
            themeMode: settings.themeMode,
            theme: AuricTheme.light(),
            darkTheme: AuricTheme.dark(),
            home: auth.isLoading
                ? const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  )
                : (auth.isLoggedIn ? const HomeScreen() : const LoginScreen()),
          );
        },
      ),
    );
  }
}
