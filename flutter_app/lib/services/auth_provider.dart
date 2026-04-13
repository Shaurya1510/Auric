import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/models.dart';
import 'api_service.dart';

// Auth state holder:
// - Google sign-in orchestration
// - secure token/profile persistence
// - auto-login restoration on app start
class AuthProvider extends ChangeNotifier {
  UserProfile? _user;
  bool _isLoading = false;
  String? _error;

  String? get _webClientId {
    final explicitWebId = dotenv.env['GOOGLE_WEB_CLIENT_ID']?.trim();
    if (explicitWebId != null && explicitWebId.isNotEmpty) return explicitWebId;

    final legacyId = dotenv.env['GOOGLE_CLIENT_ID']?.trim();
    if (legacyId != null && legacyId.isNotEmpty) return legacyId;
    return null;
  }

  String? get _serverClientId {
    final explicitServerId = dotenv.env['GOOGLE_SERVER_CLIENT_ID']?.trim();
    if (explicitServerId != null && explicitServerId.isNotEmpty) {
      return explicitServerId;
    }
    return _webClientId;
  }

  // Pass serverClientId so GoogleSignIn returns an idToken
  late final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
    clientId: kIsWeb ? _webClientId : null,
    serverClientId: _serverClientId,
  );
  final _storage = const FlutterSecureStorage();
  final _api = ApiService();

  UserProfile? get user => _user;
  bool get isLoading => _isLoading;
  bool get isLoggedIn => _user != null;
  String? get error => _error;

  Future<void> tryAutoLogin() async {
    if (_isLoading) return;
    _isLoading = true;
    notifyListeners();

    try {
      final token = await _storage
          .read(key: 'access_token')
          .timeout(const Duration(seconds: 5));
      final userId = await _storage
          .read(key: 'user_id')
          .timeout(const Duration(seconds: 5));
      final email =
          await _storage.read(key: 'email').timeout(const Duration(seconds: 5));
      final name =
          await _storage.read(key: 'name').timeout(const Duration(seconds: 5));
      final picture = await _storage
          .read(key: 'picture')
          .timeout(const Duration(seconds: 5));

      if (token != null && userId != null) {
        _api.setToken(token);

        bool isValid;
        try {
          isValid =
              await _api.validateToken().timeout(const Duration(seconds: 8));
        } catch (_) {
          isValid = false;
        }

        if (isValid) {
          _user = UserProfile(
            userId: userId,
            email: email ?? '',
            name: name ?? '',
            picture: picture,
            accessToken: token,
          );
        } else {
          await _storage.deleteAll();
          _api.clearToken();
        }
      } else {
        _api.clearToken();
      }
    } catch (_) {
      _user = null;
      _api.clearToken();
      await _storage.deleteAll();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> signInWithGoogle() async {
    if (_isLoading) return false;
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final account =
          await _googleSignIn.signIn().timeout(const Duration(seconds: 45));
      if (account == null) {
        return false;
      }

      final auth =
          await account.authentication.timeout(const Duration(seconds: 20));
      final idToken = auth.idToken;
      if (idToken == null) throw Exception('No ID token received from Google');

      final profile = await _api.signInWithGoogle(idToken);
      _user = profile;
      _api.setToken(profile.accessToken);

      // Persist session
      await _storage.write(key: 'access_token', value: profile.accessToken);
      await _storage.write(key: 'user_id', value: profile.userId);
      await _storage.write(key: 'email', value: profile.email);
      await _storage.write(key: 'name', value: profile.name);
      if (profile.picture != null) {
        await _storage.write(key: 'picture', value: profile.picture);
      }

      return true;
    } catch (e) {
      final raw = e.toString();
      if (raw.contains('sign_in_failed') && raw.contains(': 10')) {
        _error =
            'Google Sign-In config mismatch (code 10). Check Android package name, SHA-1 and OAuth client IDs in Google Cloud.';
      } else {
        _error = raw;
      }
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _storage.deleteAll();
    _user = null;
    _api.clearToken();
    notifyListeners();
  }
}
