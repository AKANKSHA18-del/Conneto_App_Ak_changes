import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────
//  Constants
// ─────────────────────────────────────────────────────────────
const String _baseUrl = 'https://conneto-internship-portal.vercel.app';
const String _dashboardUrl = '$_baseUrl/student/dashboard';
const String _prefKeyUrl = 'last_url';
const String _prefKeyLoggedIn = 'is_logged_in';
const String _prefKeyCookieJar = 'cookie_jar_v2';
const String _prefKeyWebStorage = 'web_storage_v2';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final prefs = await SharedPreferences.getInstance();
  final loggedIn = prefs.getBool(_prefKeyLoggedIn) ?? false;
  final lastSavedUrl = prefs.getString(_prefKeyUrl);
  String startUrl = loggedIn
      ? _dashboardLandingUrlFor(lastSavedUrl)
      : '$_baseUrl/';

  if (_isLoginPageUrl(startUrl)) {
    startUrl = loggedIn ? _dashboardLandingUrlFor(lastSavedUrl) : '$_baseUrl/';
  }

  runApp(MyApp(startUrl: startUrl, prefs: prefs));
}

bool _isLoginPageUrl(String url) {
  final lower = url.toLowerCase();
  // Specifically avoid matching auth callbacks or internal API paths
  if (lower.contains('/api/auth') || lower.contains('callback')) return false;
  
  // Root URL is often a landing page, not strictly a "login page"
  // unless it contains explicit login paths.
  return lower.contains('/login') ||
      lower.contains('/signin') ||
      lower.contains('/signup') ||
      lower.contains('/register');
}

String _dashboardLandingUrlFor(String? url) {
  final lower = url?.toLowerCase() ?? '';

  if (lower.contains('/company/')) {
    return '$_baseUrl/company/dashboard';
  }
  if (lower.contains('/mentor/')) {
    return '$_baseUrl/mentor/dashboard';
  }
  if (lower.contains('/admin/')) {
    return '$_baseUrl/admin/dashboard';
  }

  return _dashboardUrl;
}

class MyApp extends StatelessWidget {
  final String startUrl;
  final SharedPreferences prefs;
  const MyApp({super.key, required this.startUrl, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Conneto Internship Portal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: WebViewScreen(startUrl: startUrl, prefs: prefs),
    );
  }
}

// Removed SplashScreen for faster startup.

// ─────────────────────────────────────────────────────────────
//  Main WebView Screen
// ─────────────────────────────────────────────────────────────
class WebViewScreen extends StatefulWidget {
  final String startUrl;
  final SharedPreferences prefs;
  const WebViewScreen({super.key, required this.startUrl, required this.prefs});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _sessionChannel = MethodChannel(
    'conneto/session',
  );
  WebViewController? _controller;
  SharedPreferences? _prefs;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();

  final Map<String, DateTime> _recentNavigations = {};
  final Set<String> _restoredStorageHosts = <String>{};
  bool _handlingDiaryRedirect = false;
  bool _isInitialLoad = true;
  String _currentUrl = '';
  Timer? _initialLoadGuardTimer;
  // Use a stable Chrome-on-Android UA so auth pages behave like a normal
  // Android browser instead of the default WebView identity.
  final String _permanentUA =
      "Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) "
      "AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/125.0.0.0 Mobile Safari/537.36";

  // ── URL helpers ─────────────────────────────────────────────

  bool _isInternalUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('conneto-internship-portal.vercel.app') || 
           lower.contains('conneto.in') ||
           lower.contains('conneto.com');
  }

  bool _isDashboardUrl(String url) {
    if (!_isInternalUrl(url)) return false;
    final lower = url.toLowerCase();
    
    // Explicitly logged in if on dashboard or callback/success pages
    if (lower.contains('/dashboard') || 
        lower.contains('/api/auth/callback') || 
        lower.contains('success=true') ||
        lower.contains('/auth/success')) {
      return true;
    }
    
    // Also logged in if on protected student/company/mentor/admin paths
    if (lower.contains('/student/') ||
        lower.contains('/company/') ||
        lower.contains('/mentor/') ||
        lower.contains('/admin/')) {
       // But not if it's just a login/signup path
       if (!lower.contains('/login') && !lower.contains('/signup') && !lower.contains('/register')) {
         return true;
       }
    }
    
    return false;
  }

  bool _isLoginPageUrl(String url) {
    if (!_isInternalUrl(url)) return false;
    final lower = url.toLowerCase();
    // Exclude API and Auth callbacks
    if (lower.contains('/api/auth') || lower.contains('callback')) return false;

    return lower.contains('/login') ||
        lower.contains('/signin') ||
        lower.contains('/signup') ||
        lower.contains('/register');
  }

  bool _isLogoutAction(String url) {
    if (!_isInternalUrl(url)) return false;
    final lower = url.toLowerCase();
    return (lower.endsWith('/logout') || 
            lower.endsWith('/signout') || 
            lower.contains('logout=true') || 
            lower.contains('/api/auth/signout')) && 
           !lower.contains('success=');
  }

  bool _isFileUrl(String url) {
    if (_isGoogleAuthUrl(url)) return false;

    return url.contains('firebasestorage') ||
        url.contains('supabase') ||
        url.contains('amazonaws') ||
        url.contains('googleusercontent') ||
        url.contains('storage.googleapis') ||
        url.contains('blob.core.windows') ||
        url.contains('cloudinary') ||
        url.contains('cloudfront.net') ||
        url.contains('/uploads/') ||
        url.contains('/documents/') ||
        url.contains('/files/') ||
        url.contains('/certificate/') ||
        url.contains('/download') ||
        url.endsWith('.pdf') ||
        url.endsWith('.png') ||
        url.endsWith('.jpg') ||
        url.endsWith('.jpeg') ||
        url.endsWith('.doc') ||
        url.endsWith('.docx');
  }

  bool _isDocumentViewerUrl(String url) => url.contains('/view-document');

  bool _isGoogleAuthUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('accounts.google') ||
        lower.contains('google.com/o/oauth2') ||
        lower.contains('oauth2.googleapis.com') ||
        lower.contains('auth/google') ||
        lower.contains('google.com/signin') ||
        lower.contains('google-signin') ||
        lower.contains('accounts.youtube.com') ||
        lower.contains('google.co.in/signin') ||
        lower.contains('google.com/accounts') ||
        lower.contains('google.com/amp/s/accounts.google.com');
  }

  bool _isTrulyExternal(String url) {
    // If it's our site or google login, it's NOT external. Keep it in app.
    if (_isInternalUrl(url) || _isGoogleAuthUrl(url)) return false;
    
    final lower = url.toLowerCase();
    
    // Explicitly prevent these from EVER jumping to Chrome
    if (lower.contains('vercel.app') || 
        lower.contains('google.com') || 
        lower.contains('accounts.google') || 
        lower.contains('google.co') ||
        lower.contains('oauth')) return false;

    // Only allow non-web intents to launch externally
    if (lower.startsWith('tel:') || lower.startsWith('mailto:') || lower.startsWith('whatsapp:')) {
       return true;
    }
    
    // Never launch intent:// links externally to avoid bouncing to Chrome
    if (lower.startsWith('intent:')) {
       return false;
    }
    
    // Everything else stays in app by default unless it's a completely different website
    // and we are NOT in a login flow.
    return !lower.contains('conneto');
  }

  bool _isDuplicateNavigation(String url) {
    if (_isAuthFlowUrl(url)) return false;

    final now = DateTime.now();
    final last = _recentNavigations[url];
    if (last != null && now.difference(last).inMilliseconds < 1000) return true;
    _recentNavigations[url] = now;
    return false;
  }

  bool _isAuthFlowUrl(String url) {
    final lower = url.toLowerCase();
    return _isGoogleAuthUrl(url) ||
        lower.contains('/api/auth') ||
        lower.contains('callback') ||
        lower.contains('/login') ||
        lower.contains('/signin') ||
        lower.contains('/signup') ||
        lower.contains('/register');
  }

  bool _shouldPersistWebState(String url) {
    return _isInternalUrl(url);
  }

  String? _hostForUrl(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase();
    if (host == null || host.isEmpty) return null;
    return host;
  }

  Map<String, dynamic> _decodeJsonObject(String? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      // Ignore invalid persisted data and fall back to an empty object.
    }

    return <String, dynamic>{};
  }

  String _normalizeJavaScriptResult(Object result) {
    final text = result.toString();
    if (text == 'null' || text == 'undefined') return '';

    try {
      final decoded = jsonDecode(text);
      if (decoded is String) return decoded;
      return jsonEncode(decoded);
    } catch (_) {
      return text;
    }
  }

  Map<String, String> _parseCookieString(String cookieString) {
    final cookies = <String, String>{};

    for (final segment in cookieString.split(';')) {
      final item = segment.trim();
      if (item.isEmpty) continue;

      final separatorIndex = item.indexOf('=');
      if (separatorIndex <= 0) continue;

      final name = item.substring(0, separatorIndex).trim();
      final value = item.substring(separatorIndex + 1).trim();
      if (name.isEmpty) continue;

      cookies[name] = value;
    }

    return cookies;
  }

  bool _isConnetoHost(String host) {
    final lower = host.toLowerCase();
    return lower.contains('conneto-internship-portal.vercel.app') ||
        lower.contains('conneto.in') ||
        lower.contains('conneto.com');
  }

  // ── Session ─────────────────────────────────────────────────

  Future<void> _onUserLoggedIn(String url) async {
    if (_isLoginPageUrl(url)) return; 
    await _prefs?.setBool(_prefKeyLoggedIn, true);
    if (_isInternalUrl(url) && !_isAuthFlowUrl(url)) {
      await _prefs?.setString(_prefKeyUrl, _dashboardLandingUrlFor(url));
    }
    debugPrint('SESSION: Active - $url');
  }

  Future<void> _onUserLoggedOut() async {
    await _prefs?.setBool(_prefKeyLoggedIn, false);
    await _prefs?.remove(_prefKeyUrl);
    await _clearPersistedAppSessionState();
    // Note: We no longer clear cookies here. This allows Google to "store" 
    // accounts so the user can "choose different account" or "use another" 
    // easily, while still being logged out of the Conneto app session.
    debugPrint('SESSION: Logged Out');
  }

  Future<void> _saveCurrentUrl(String url) async {
    if (_isInternalUrl(url) && !_isLoginPageUrl(url)) {
      await _prefs?.setString(_prefKeyUrl, _dashboardLandingUrlFor(url));
      // Auto-set logged in if we are on a dashboard
      if (_isDashboardUrl(url)) {
        final loggedIn = _prefs?.getBool(_prefKeyLoggedIn) ?? false;
        if (!loggedIn) await _onUserLoggedIn(url);
      }
    }
  }

  Future<void> _restorePersistedCookies() async {
    final prefs = _prefs;
    if (prefs == null) return;

    final savedCookieJar = _decodeJsonObject(prefs.getString(_prefKeyCookieJar));

    for (final entry in savedCookieJar.entries) {
      if (entry.value is! Map) continue;

      final host = entry.key.trim();
      if (host.isEmpty || !_isConnetoHost(host)) continue;

      final cookies = Map<String, dynamic>.from(entry.value as Map);
      for (final cookieEntry in cookies.entries) {
        final name = cookieEntry.key.trim();
        final value = cookieEntry.value?.toString() ?? '';
        if (name.isEmpty) continue;

        try {
          await _cookieManager.setCookie(
            WebViewCookie(
              name: name,
              value: value,
              domain: host,
            ),
          );
        } catch (e) {
          debugPrint('COOKIE RESTORE ERROR [$host/$name]: $e');
        }
      }
    }
  }

  Future<void> _clearPersistedAppSessionState() async {
    final prefs = _prefs;
    if (prefs == null) return;

    final savedCookieJar = _decodeJsonObject(prefs.getString(_prefKeyCookieJar));
    savedCookieJar.removeWhere(
      (host, _) => _isConnetoHost(host),
    );
    await prefs.setString(_prefKeyCookieJar, jsonEncode(savedCookieJar));

    final savedStorage = _decodeJsonObject(prefs.getString(_prefKeyWebStorage));
    savedStorage.removeWhere(
      (host, _) => _isConnetoHost(host),
    );
    await prefs.setString(_prefKeyWebStorage, jsonEncode(savedStorage));
  }

  Future<bool> _restorePersistedWebStorage(String url) async {
    final ctrl = _controller;
    final prefs = _prefs;
    final host = _hostForUrl(url);

    if (ctrl == null ||
        prefs == null ||
        host == null ||
        !_shouldPersistWebState(url) ||
        _restoredStorageHosts.contains(host)) {
      return false;
    }

    _restoredStorageHosts.add(host);

    final savedStorage = _decodeJsonObject(prefs.getString(_prefKeyWebStorage));
    final rawHostState = savedStorage[host];
    if (rawHostState is! Map) return false;

    final hostState = Map<String, dynamic>.from(rawHostState);
    final localStorageState = hostState['localStorage'] is Map
        ? Map<String, dynamic>.from(hostState['localStorage'] as Map)
        : <String, dynamic>{};

    if (localStorageState.isEmpty) {
      return false;
    }

    final payload = jsonEncode(<String, dynamic>{
      'localStorage': localStorageState,
    });

    try {
      final rawResult = await ctrl.runJavaScriptReturningResult('''
        (function() {
          try {
            var payload = $payload;
            var changed = false;

            function applyStore(store, values) {
              var keys = Object.keys(values || {});
              for (var i = 0; i < keys.length; i++) {
                var key = keys[i];
                var value = values[key];
                if (store.getItem(key) !== value) {
                  if (value === null || value === undefined) {
                    store.removeItem(key);
                  } else {
                    store.setItem(key, value);
                  }
                  changed = true;
                }
              }
            }

            applyStore(localStorage, payload.localStorage);

            return JSON.stringify({ changed: changed });
          } catch (e) {
            return JSON.stringify({ changed: false, error: String(e) });
          }
        })();
      ''');

      final result = _decodeJsonObject(_normalizeJavaScriptResult(rawResult));
      return result['changed'] == true;
    } catch (e) {
      debugPrint('WEB STORAGE RESTORE ERROR [$host]: $e');
      return false;
    }
  }

  Future<void> _persistWebSnapshot(String url) async {
    final ctrl = _controller;
    final prefs = _prefs;
    final host = _hostForUrl(url);

    if (ctrl == null ||
        prefs == null ||
        host == null ||
        !_shouldPersistWebState(url)) {
      return;
    }

    try {
      final rawSnapshot = await ctrl.runJavaScriptReturningResult('''
        (function() {
          try {
            var snapshot = {
              cookie: document.cookie || '',
              localStorage: {}
            };

            for (var i = 0; i < localStorage.length; i++) {
              var localKey = localStorage.key(i);
              snapshot.localStorage[localKey] = localStorage.getItem(localKey);
            }

            return JSON.stringify(snapshot);
          } catch (e) {
            return JSON.stringify({
              cookie: '',
              localStorage: {},
              error: String(e)
            });
          }
        })();
      ''');

      final snapshot =
          _decodeJsonObject(_normalizeJavaScriptResult(rawSnapshot));

      final cookies = _parseCookieString(snapshot['cookie']?.toString() ?? '');
      final savedCookieJar =
          _decodeJsonObject(prefs.getString(_prefKeyCookieJar));
      if (cookies.isNotEmpty) {
        savedCookieJar[host] = cookies;
      } else {
        savedCookieJar.remove(host);
      }
      await prefs.setString(_prefKeyCookieJar, jsonEncode(savedCookieJar));

      final localStorageState = snapshot['localStorage'] is Map
          ? Map<String, dynamic>.from(snapshot['localStorage'] as Map)
          : <String, dynamic>{};

      final savedStorage =
          _decodeJsonObject(prefs.getString(_prefKeyWebStorage));
      if (localStorageState.isNotEmpty) {
        savedStorage[host] = <String, dynamic>{
          'localStorage': localStorageState,
        };
      } else {
        savedStorage.remove(host);
      }
      await prefs.setString(_prefKeyWebStorage, jsonEncode(savedStorage));
    } catch (e) {
      debugPrint('WEB SNAPSHOT SAVE ERROR [$host]: $e');
    }
  }

  Future<void> _flushNativeCookies() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    try {
      await _sessionChannel.invokeMethod('flushCookies');
    } catch (e) {
      debugPrint('COOKIE FLUSH ERROR: $e');
    }
  }

  // ── External launch ─────────────────────────────────────────

  Future<bool> _tryLaunchExternal(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }
    } catch (e) {
      debugPrint('Launch error: $e');
    }
    return false;
  }

  // ── Diary / Leave redirects ─────────────────────────────────

  void _handleDiaryRedirect(String url, {required bool isDuplicate}) {
    if (_handlingDiaryRedirect) return;
    _handlingDiaryRedirect = true;

    final uri = Uri.parse(url);
    final internshipId = uri.queryParameters['viewInternshipId'];

    final target = Uri(
      scheme: 'https',
      host: 'conneto-internship-portal.vercel.app',
      path: '/student/dashboard',
      queryParameters: {
        'tab': 'diary',
        if (internshipId != null) 'viewInternshipId': internshipId,
      },
    ).toString();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isDuplicate
            ? 'You already have a diary entry for this date.'
            : 'Diary entry saved successfully!'),
        backgroundColor: isDuplicate ? Colors.orange[700] : Colors.green[700],
        duration: const Duration(seconds: 3),
      ));
    }

    _controller?.loadRequest(Uri.parse(target));
    Future.delayed(const Duration(seconds: 2), () => _handlingDiaryRedirect = false);
  }

  void _handleLeaveRedirect(String url) {
    final target = Uri(
      scheme: 'https',
      host: 'conneto-internship-portal.vercel.app',
      path: '/student/dashboard',
      queryParameters: {'tab': 'leaves'},
    ).toString();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Leave application submitted successfully!'),
        backgroundColor: Colors.green[700],
        duration: const Duration(seconds: 3),
      ));
    }
    _controller?.loadRequest(Uri.parse(target));
  }

  // ── Init ────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUrl = widget.startUrl;
    _initialLoadGuardTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted && _isInitialLoad) {
        setState(() {
          _isInitialLoad = false;
        });
      }
    });
    _setupWebView();
  }

  @override
  void dispose() {
    _initialLoadGuardTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_currentUrl.isNotEmpty) {
        _persistWebSnapshot(_currentUrl);
      }
      _flushNativeCookies();
    }
  }

  Future<void> _setupWebView() async {
    _prefs = widget.prefs;

    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_permanentUA)
      ..setBackgroundColor(const Color(0x00000000))
      ..setOnConsoleMessage((msg) => debugPrint('JS: ${msg.message}'))

      // ── Download channel ────────────────────────────────
      ..addJavaScriptChannel(
        'FlutterDownload',
        onMessageReceived: (JavaScriptMessage msg) async {
          final url = msg.message;
          if (url.startsWith('data:') || _isDocumentViewerUrl(url) || _isFileUrl(url)) {
            await _tryLaunchExternal(url);
            return;
          }
          if (_isInternalUrl(url) || _isGoogleAuthUrl(url)) {
            // Force it to load in the current controller, don't let it jump out
            await _controller?.loadRequest(Uri.parse(url));
            return;
          }
          await _tryLaunchExternal(url);
        },
      )

      // ── Session channel ─────────────────────────────────
      ..addJavaScriptChannel(
        'FlutterSession',
        onMessageReceived: (JavaScriptMessage msg) async {
          final data = msg.message;
          debugPrint('SESSION MSG: $data');
          if (data == 'logout') {
            await _onUserLoggedOut();
          } else if (data.startsWith('login:')) {
            final url = data.substring(6);
            await _onUserLoggedIn(url);
          }
        },
      )

      // ── Navigation delegate ─────────────────────────────
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (progress) {
          if (progress > 35 && _isInitialLoad) {
            if (mounted) {
              setState(() {
                _isInitialLoad = false;
              });
            }
          }
        },
        onPageStarted: (url) {
          _currentUrl = url;

          // Check for session markers in URL
          if (_isDashboardUrl(url)) {
            _onUserLoggedIn(url);
          }
        },

        onNavigationRequest: (NavigationRequest request) async {
          final url = request.url;
          debugPrint('NAV: $url');

          if (_isDocumentViewerUrl(url) || _isFileUrl(url)) {
            await _tryLaunchExternal(url);
            return NavigationDecision.prevent;
          }

          if (_isTrulyExternal(url)) {
            await _tryLaunchExternal(url);
            return NavigationDecision.prevent;
          }

          // Keep Google auth inside the WebView, but normalize the account picker
          // so repeat sign-in/sign-up attempts behave consistently.
          if (_isGoogleAuthUrl(url) && 
              (url.contains('oauth2/v2/auth') || url.contains('oauth2/auth')) && 
              !url.contains('prompt=select_account')) {
            
            String newUrl = url;
            if (newUrl.contains('prompt=')) {
              // Replace existing prompt with select_account
              newUrl = newUrl.replaceAll(RegExp(r'prompt=[^&]+'), 'prompt=select_account');
            } else {
              newUrl += (newUrl.contains('?') ? '&' : '?') + 'prompt=select_account';
            }
            
            debugPrint('FORCING ACCOUNT PICKER: $newUrl');
            await _controller?.loadRequest(Uri.parse(newUrl));
            return NavigationDecision.prevent;
          }

          if (_isLogoutAction(url)) {
            return NavigationDecision.navigate;
          }

          // Keep a stable Chrome-on-Android identity for auth-related pages.

          if (url.contains('error=You+have+already+submitted+a+diary+log')) {
            _handleDiaryRedirect(url, isDuplicate: true);
            return NavigationDecision.prevent;
          }
          if (url.contains('/student/dashboard') &&
              url.contains('success=') &&
              url.contains('tab=diary')) {
            _handleDiaryRedirect(url, isDuplicate: false);
            return NavigationDecision.prevent;
          }
          if (url.contains('/student/dashboard') &&
              url.contains('success=') &&
              url.contains('tab=leaves')) {
            _handleLeaveRedirect(url);
            return NavigationDecision.prevent;
          }
          if (_isDuplicateNavigation(url)) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },

        onPageFinished: (String url) async {
          if (mounted) {
            setState(() {
              _isInitialLoad = false;
              _currentUrl = url;
            });
          }
          debugPrint('LOADED: $url');
          _initialLoadGuardTimer?.cancel();

          final restoredStorage = await _restorePersistedWebStorage(url);
          if (restoredStorage) {
            debugPrint('SESSION: Restored web storage for $url, reloading once.');
            await _controller?.reload();
            return;
          }

          // Session persistence logic
          final bool loggedIn = _prefs?.getBool(_prefKeyLoggedIn) ?? false;

          if (_isInternalUrl(url)) {
            if (_isDashboardUrl(url)) {
              await _onUserLoggedIn(url);
            } else if (_isLoginPageUrl(url)) {
              // If we are on a login page but the app thinks we are logged in,
              // we don't force a logout anymore. We just let the user log in again.
              // This satisfies the "no logout on restart/shutdown" requirement.
              debugPrint('SESSION: On login page. App state: ${loggedIn ? "Logged In" : "Logged Out"}');
            } else {
              await _saveCurrentUrl(url);
            }
          }

          // Diary/leave redirect safety nets
          if (url.contains('error=You+have+already+submitted+a+diary+log')) {
            _handleDiaryRedirect(url, isDuplicate: true);
            return;
          }
          if (url.contains('/student/dashboard') &&
              url.contains('success=') &&
              url.contains('tab=diary')) {
            _handleDiaryRedirect(url, isDuplicate: false);
            return;
          }
          if (url.contains('/student/dashboard') &&
              url.contains('success=') &&
              url.contains('tab=leaves')) {
            _handleLeaveRedirect(url);
            return;
          }

          // Inject JS
          await _injectSessionDetection(url);
          _injectJsBridge();
          await _persistWebSnapshot(url);
          await _flushNativeCookies();
        },

        onWebResourceError: (error) {
          _initialLoadGuardTimer?.cancel();
          if (mounted) setState(() => _isInitialLoad = false);
          debugPrint('WEB ERR: ${error.description}');
        },
      ));

    _controller = ctrl;

    if (ctrl.platform is AndroidWebViewController) {
      final android = ctrl.platform as AndroidWebViewController;
      android.setOnShowFileSelector(_handleFileSelection);
      
      // Ensure third-party cookies are allowed for Google Sign-In persistence
      final androidCookieManager =
          _cookieManager.platform as AndroidWebViewCookieManager;
      androidCookieManager.setAcceptThirdPartyCookies(android, true);
    }

    await _restorePersistedCookies();
    await ctrl.loadRequest(Uri.parse(widget.startUrl));
    if (mounted) setState(() {});
  }

  // ── JS helpers ──────────────────────────────────────────────

  Future<void> _injectSessionDetection(String url) async {
    if (!_isInternalUrl(url)) return;

    if (_isDashboardUrl(url)) {
      await _controller?.runJavaScript(
          "FlutterSession.postMessage('login:${url.replaceAll("'", "\\'")}');");
    }

    // Keep the website's own long-session option enabled for email/password
    // logins, and only treat explicit logout actions as app logout.
    await _controller?.runJavaScript(r'''
      (function() {
        if (location.pathname === '/auth/login') {
          var remember = document.querySelector('input[name="remember"]');
          if (remember && !remember.checked) {
            remember.checked = true;
            remember.dispatchEvent(new Event('change', { bubbles: true }));
          }
        }

        var hasAuthenticatedUi =
          !!document.querySelector('a[href*="/logout"], a[href*="/signout"], form[action*="/logout"], form[action*="/signout"]') ||
          !!document.querySelector('a[href*="/student/dashboard"], a[href*="/company/dashboard"], a[href*="/mentor/dashboard"], a[href*="/admin/dashboard"]');

        if (hasAuthenticatedUi && location.pathname.indexOf('/auth/') === -1) {
          FlutterSession.postMessage('login:' + location.href);
        }

        if (window.__logoutListenerAdded) return;
        window.__logoutListenerAdded = true;
        document.addEventListener('click', function(e) {
          var el = e.target.closest('a, button');
          if (!el) return;
          
          var txt = (el.innerText || el.textContent || '').trim().toLowerCase();
          var href = (el.href || '').toLowerCase();
          
          // Specific check for logout keywords in text or specific logout paths in href
          var isLogoutText = (txt === 'logout' || txt === 'sign out' || txt === 'log out');
          var isLogoutHref = (href.indexOf('/logout') !== -1 || href.indexOf('/signout') !== -1 || href.indexOf('logout=true') !== -1);
          
          if (isLogoutText || isLogoutHref) {
            console.log('Logout detected via JS bridge');
            FlutterSession.postMessage('logout');
          }
        }, true);

        document.addEventListener('submit', function(e) {
          var form = e.target;
          if (!form || !form.action) return;

          var action = String(form.action).toLowerCase();
          var isLogoutForm =
            action.indexOf('/logout') !== -1 ||
            action.indexOf('/signout') !== -1 ||
            action.indexOf('logout=true') !== -1;

          if (isLogoutForm) {
            console.log('Logout form detected via JS bridge');
            FlutterSession.postMessage('logout');
          }
        }, true);
      })();
    ''');
  }

  void _injectJsBridge() {
    _controller?.runJavaScript(r'''
      (function() {
        if (window.__flutterInjected) return;
        window.__flutterInjected = true;

        document.addEventListener('click', function(e) {
          var el = e.target.closest('a');
          if (el && el.href) {
            var href = el.href;
            if (href.startsWith('blob:')) {
              e.preventDefault(); e.stopPropagation();
              fetch(href).then(function(r){return r.blob();})
                .then(function(blob){
                  var reader=new FileReader();
                  reader.onload=function(){FlutterDownload.postMessage(reader.result);};
                  reader.readAsDataURL(blob);
                }).catch(function(err){console.log('Blob error: '+err);});
              return;
            }
            var isFile=el.hasAttribute('download')||
              /\.(pdf|png|jpg|jpeg|doc|docx)([?#]|$)/i.test(href)||
              href.indexOf('firebasestorage')!==-1||href.indexOf('supabase')!==-1||
              href.indexOf('amazonaws')!==-1||
              (href.indexOf('googleusercontent')!==-1 && href.indexOf('accounts.google')===-1)||
              href.indexOf('storage.googleapis')!==-1||href.indexOf('cloudinary')!==-1||
              href.indexOf('cloudfront.net')!==-1||href.indexOf('/uploads/')!==-1||
              href.indexOf('/documents/')!==-1||href.indexOf('/files/')!==-1||
              href.indexOf('/certificate/')!==-1||href.indexOf('/download')!==-1||
              href.indexOf('/view-document')!==-1;
            if(isFile){e.preventDefault();e.stopPropagation();FlutterDownload.postMessage(href);}
          }
          var btn=e.target.closest('button');
          if(btn){
            var txt=(btn.innerText||btn.textContent||'').trim().substring(0,40);
            var lowerTxt=txt.toLowerCase();
            if(lowerTxt.indexOf('open')!==-1||lowerTxt.indexOf('view')!==-1||
               lowerTxt.indexOf('pan')!==-1||lowerTxt.indexOf('cert')!==-1){
              var nearestLink=btn.closest('a')||btn.querySelector('a');
              if(nearestLink&&nearestLink.href){FlutterDownload.postMessage(nearestLink.href);}
            }
          }
        }, true);

        // BROWSER DECEPTION: Shims to satisfy Google's security checks
        (function() {
          // Shim window.chrome which Google's security library checks for
          window.chrome = {
            runtime: {},
            loadTimes: function() { return {}; },
            csi: function() { return {}; },
            app: {}
          };
          
          // Override navigator.userAgent in JS to match the controller
          Object.defineProperty(navigator, 'userAgent', {
            get: function () { return 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36'; }
          });
          
          // Shim navigator.platform to look like Chrome on Android
          Object.defineProperty(navigator, 'platform', {
            get: function () { return 'Linux armv8l'; }
          });
          
          // Force Google Identity Services (GSI) to use redirect mode instead of popup
          var _origProp = Object.defineProperty;
          Object.defineProperty = function(obj, prop, descriptor) {
            if (prop === 'ux_mode' && descriptor) {
              descriptor.value = 'redirect';
              console.log('Forced GSI ux_mode to redirect');
            }
            return _origProp.apply(this, arguments);
          };
        })();

        // Google OAuth popup → redirect in same tab
        window.open = function(url, target, features) {
          if (url && url !== 'about:blank') {
            console.log('Intercepted window.open: ' + url);
            window.location.href = url;
          }
          var win = {
            closed: false,
            name: target || 'google_auth_window',
            opener: window,
            close: function() { console.log('Popup close requested'); },
            focus: function() { console.log('Popup focus requested'); },
            postMessage: function(msg) { console.log('Popup postMessage: ' + msg); }
          };
          win.window = win;
          return win;
        };

        // MutationObserver to fix Google Sign-In buttons dynamically
        var authObserver = new MutationObserver(function(mutations) {
          mutations.forEach(function(mutation) {
            if (mutation.addedNodes) {
              mutation.addedNodes.forEach(function(node) {
                if (node.nodeType === 1) {
                  if (node.hasAttribute('data-ux_mode')) {
                    node.setAttribute('data-ux_mode', 'redirect');
                  }
                  var gbtns = node.querySelectorAll('[data-ux_mode="popup"]');
                  for (var i = 0; i < gbtns.length; i++) {
                    gbtns[i].setAttribute('data-ux_mode', 'redirect');
                  }
                }
              });
            }
          });
        });

        function fixGAuthButtons() {
          var gbtns = document.querySelectorAll('[data-ux_mode="popup"]');
          for (var i = 0; i < gbtns.length; i++) {
            gbtns[i].setAttribute('data-ux_mode', 'redirect');
          }
        }

        // Run once immediately and then observe for dynamic changes
        fixGAuthButtons();
        authObserver.observe(document.body, { childList: true, subtree: true });

        // Force all _blank links to open in the same window
        document.addEventListener('click', function(e) {
          var el = e.target.closest('a');
          if (el && (el.target === '_blank' || el.getAttribute('target') === '_blank')) {
            el.target = '_self';
            console.log('Forced _blank to _self for: ' + el.href);
          }
        }, true);

        var _origFetch=window.fetch;
        window.fetch=function(input,init){
          var reqUrl=typeof input==='string'?input:(input&&input.url)||'';
          return _origFetch.call(this,input,init).then(function(response){
            var ct=response.headers.get('content-type')||'';
            var isFile=ct.indexOf('application/pdf')!==-1||
              ct.indexOf('application/msword')!==-1||
              ct.indexOf('application/vnd.openxmlformats')!==-1||
              ct.indexOf('application/octet-stream')!==-1||
              ct.indexOf('image/jpeg')!==-1||ct.indexOf('image/png')!==-1;
            if(isFile){
              response.clone().blob().then(function(blob){
                var reader=new FileReader();
                reader.onload=function(){FlutterDownload.postMessage(reader.result);};
                reader.readAsDataURL(blob);
              });
            }
            return response;
          });
        };

        var observer=new MutationObserver(function(mutations){
          for(var i=0;i<mutations.length;i++){
            for(var j=0;j<mutations[i].addedNodes.length;j++){
              var node=mutations[i].addedNodes[j];
              if(node.nodeType===1&&node.querySelectorAll){
                var links=node.querySelectorAll('a[href]');
                for(var k=0;k<links.length;k++){
                  var href=links[k].href||'';
                  if(href.indexOf('/view-document')!==-1||
                     href.indexOf('firebasestorage')!==-1||
                     href.indexOf('amazonaws')!==-1){
                    console.log('DYNAMIC LINK: '+href);
                  }
                }
              }
            }
          }
        });
        observer.observe(document.body,{childList:true,subtree:true});
        console.log('Bridge injected');
      })();
    ''');
  }

  Future<List<String>> _handleFileSelection(FileSelectorParams params) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: params.mode == FileSelectorMode.openMultiple,
      type: FileType.any,
    );
    if (result != null && result.files.isNotEmpty) {
      return result.files.where((f) => f.path != null).map((f) => 'file://${f.path}').toList();
    }
    return [];
  }

  // ── Back button handler ─────────────────────────────────────

  Future<bool> _onBackPressed() async {
    final ctrl = _controller;
    if (ctrl == null) return true;

    final loggedIn = _prefs?.getBool(_prefKeyLoggedIn) ?? false;
    final treatAsAuthenticated =
        loggedIn &&
        !_isLoginPageUrl(_currentUrl) &&
        !_isAuthFlowUrl(_currentUrl);

    if (treatAsAuthenticated) {
      if (_isDashboardUrl(_currentUrl)) {
        return true;
      } else {
        if (await ctrl.canGoBack()) {
          await ctrl.goBack();
          return false;
        }
        // If no history, go to dashboard as home base
        await ctrl.loadRequest(Uri.parse(_dashboardUrl));
        return false;
      }
    }

    if (await ctrl.canGoBack()) {
      await ctrl.goBack();
      return false;
    }

    return true;
  }

  // ── Build ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final should = await _onBackPressed();
        if (should && mounted) SystemNavigator.pop();
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              if (_controller != null)
                WebViewWidget(controller: _controller!),
              if (_isInitialLoad)
                Container(
                  color: Colors.white,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset(
                          'assets/icon/conneto_icon.png',
                          width: 120,
                          height: 120,
                          errorBuilder: (_, __, ___) => const Icon(Icons.business, size: 80, color: Colors.blue),
                        ),
                        const SizedBox(height: 30),
                        const CircularProgressIndicator(color: Colors.blue),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
