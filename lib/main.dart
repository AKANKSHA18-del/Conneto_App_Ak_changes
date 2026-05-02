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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final prefs = await SharedPreferences.getInstance();
  final loggedIn = prefs.getBool(_prefKeyLoggedIn) ?? false;
  String startUrl;

  if (loggedIn) {
    startUrl = prefs.getString(_prefKeyUrl) ?? _dashboardUrl;
    if (_isLoginPageUrl(startUrl)) startUrl = _dashboardUrl;
  } else {
    startUrl = '$_baseUrl/';
  }

  runApp(MyApp(startUrl: startUrl));
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

class MyApp extends StatelessWidget {
  final String startUrl;
  const MyApp({super.key, required this.startUrl});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Conneto Internship Portal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.blue),
      home: WebViewScreen(startUrl: startUrl),
    );
  }
}

// Removed SplashScreen for faster startup.

// ─────────────────────────────────────────────────────────────
//  Main WebView Screen
// ─────────────────────────────────────────────────────────────
class WebViewScreen extends StatefulWidget {
  final String startUrl;
  const WebViewScreen({super.key, required this.startUrl});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  WebViewController? _controller;
  SharedPreferences? _prefs;

  final Map<String, DateTime> _recentNavigations = {};
  bool _handlingDiaryRedirect = false;
  bool _isInitialLoad = true;
  String _currentUrl = '';

  // ── URL helpers ─────────────────────────────────────────────

  bool _isInternalUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('conneto-internship-portal.vercel.app') || 
           lower.contains('conneto.in') ||
           lower.contains('conneto.com');
  }

  bool _isDashboardUrl(String url) =>
      url.contains('/student/dashboard') ||
      url.contains('/mentor/dashboard') ||
      url.contains('/admin/dashboard') ||
      url.contains('/dashboard') && !url.contains('/login');

  bool _isLoginPageUrl(String url) {
    final lower = url.toLowerCase();
    // Exclude API and Auth callbacks from being treated as "login pages"
    if (lower.contains('/api/auth') || lower.contains('callback')) return false;

    // We only treat explicit /login, /signin etc as login pages.
    // This allows the root landing page to be seen as "Home".
    return lower.contains('/login') ||
        lower.contains('/signin') ||
        lower.contains('/signup') ||
        lower.contains('/register');
  }

  bool _isLogoutAction(String url) {
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
    final now = DateTime.now();
    final last = _recentNavigations[url];
    if (last != null && now.difference(last).inMilliseconds < 1000) return true;
    _recentNavigations[url] = now;
    return false;
  }

  // ── Session ─────────────────────────────────────────────────

  Future<void> _onUserLoggedIn(String url) async {
    if (_isLoginPageUrl(url)) return; 
    await _prefs?.setBool(_prefKeyLoggedIn, true);
    if (_isInternalUrl(url)) {
      await _prefs?.setString(_prefKeyUrl, url);
    }
    debugPrint('SESSION: Active - $url');
  }

  Future<void> _onUserLoggedOut() async {
    await _prefs?.setBool(_prefKeyLoggedIn, false);
    await _prefs?.remove(_prefKeyUrl);
    debugPrint('SESSION: Logged Out');
  }

  Future<void> _saveCurrentUrl(String url) async {
    if (_isInternalUrl(url) && !_isLoginPageUrl(url)) {
      await _prefs?.setString(_prefKeyUrl, url);
      // Auto-set logged in if we are on a dashboard
      if (_isDashboardUrl(url)) {
        final loggedIn = _prefs?.getBool(_prefKeyLoggedIn) ?? false;
        if (!loggedIn) await _onUserLoggedIn(url);
      }
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
    _currentUrl = widget.startUrl;
    _setupWebView();
  }

  Future<void> _setupWebView() async {
    _prefs = await SharedPreferences.getInstance();
    
    // Cookies are persistent by default in this version
    final cookieManager = WebViewCookieManager();

    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent("Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36")
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
        onPageStarted: (url) {
          // Check for session markers in URL
          if (_isDashboardUrl(url)) {
            _onUserLoggedIn(url);
          } else if (_isLogoutAction(url)) {
            _onUserLoggedOut();
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

          // Force Google Account Chooser so users can select an account like a native app
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
            _controller?.loadRequest(Uri.parse(newUrl));
            return NavigationDecision.prevent;
          }

          if (_isLogoutAction(url)) {
            await _onUserLoggedOut();
            return NavigationDecision.navigate;
          }

          // Proactively redirect to dashboard if logged in and hitting a login page
          final bool loggedIn = _prefs?.getBool(_prefKeyLoggedIn) ?? false;
          if (loggedIn && _isLoginPageUrl(url)) {
            debugPrint('NAV: Already logged in, skipping login page for dashboard.');
            _controller?.loadRequest(Uri.parse(_dashboardUrl));
            return NavigationDecision.prevent;
          }

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

          // Session persistence logic
          final bool loggedIn = _prefs?.getBool(_prefKeyLoggedIn) ?? false;

          if (_isInternalUrl(url)) {
            if (_isDashboardUrl(url)) {
              await _onUserLoggedIn(url);
            } else if (_isLoginPageUrl(url)) {
              if (loggedIn) {
                final lastRedirect = _prefs?.getInt('last_dash_redirect') ?? 0;
                final now = DateTime.now().millisecondsSinceEpoch;
                if (now - lastRedirect < 5000) {
                  debugPrint('SESSION: Redirect loop detected. Clearing session.');
                  await _onUserLoggedOut();
                } else {
                  debugPrint('SESSION: Logged in but hit login page. Attempting auto-login.');
                  await _prefs?.setInt('last_dash_redirect', now);
                  _controller?.loadRequest(Uri.parse(_dashboardUrl));
                  return;
                }
              }
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
        },

        onWebResourceError: (error) {
          if (mounted) setState(() => _isInitialLoad = false);
          debugPrint('WEB ERR: ${error.description}');
        },
      ));

    _controller = ctrl;

    if (ctrl.platform is AndroidWebViewController) {
      final android = ctrl.platform as AndroidWebViewController;
      android.setOnShowFileSelector(_handleFileSelection);
      // Ensure third-party cookies are allowed for Google Sign-In persistence
      final androidCookieManager = WebViewCookieManager().platform as AndroidWebViewCookieManager;
      androidCookieManager.setAcceptThirdPartyCookies(android, true);
    }

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

    // Logout button detection - more specific to avoid accidental triggers
    await _controller?.runJavaScript(r'''
      (function() {
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

        // Google OAuth popup → redirect in same tab
        window.open = function(url, target, features) {
          if (url && url !== 'about:blank') {
            // Force EVERYTHING from window.open to load in the current webview
            // NavigationDelegate in Flutter will catch actual files/downloads
            window.location.href = url;
          }
          return null;
        };

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

    if (loggedIn) {
      if (_isDashboardUrl(_currentUrl)) {
        // If on dashboard, maybe try to go back to landing page if it exists in history
        if (await ctrl.canGoBack()) {
          await ctrl.goBack();
          return false;
        }
        return true; // Exit if no more history
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
