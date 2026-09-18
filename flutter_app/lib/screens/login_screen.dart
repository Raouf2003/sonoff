import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../l10n/gen/app_localizations.dart';
import '../l10n/l10n_helpers.dart';
import '../l10n/locale_controller.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import 'signup_screen.dart';
import '../widgets/language_menu_button.dart';

class LoginScreen extends StatefulWidget {
  final ThemeController? themeController;
  final LocaleController? localeController;
  const LoginScreen({super.key, this.themeController, this.localeController});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final _usernameCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  final _api = ApiService();
  final _auth = AuthService();
  bool _loading = false;
  bool _obscure = true;
  late AnimationController _fade;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..forward();
  }

  @override
  void dispose() {
    _usernameCtl.dispose();
    _passwordCtl.dispose();
    _fade.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_loading) return;
    final u = _usernameCtl.text.trim();
    final p = _passwordCtl.text;
    final l10n = AppLocalizations.of(context)!;
    if (u.isEmpty || p.isEmpty) { _err(l10n.authFillAll); return; }
    setState(() => _loading = true);
    try {
      final data = await _api.login(u, p);
      await _auth.saveToken(data['token'] as String);
      await _auth.saveUsername(data['user']['username'] as String);
      if (mounted) Navigator.of(context).pushReplacementNamed('/home');
    } catch (e) { if (mounted) _err(friendlyError(e, l10n)); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  // ApiException already carries a user-safe message; anything else is a
  // programming/server edge case we never surface verbatim.

  void _err(String m) {
    if (!mounted) return;
    final colors = context.steesColors;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onError)),
        backgroundColor: colors.danger,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [colors.well, scheme.surfaceContainerHighest, colors.well],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fade,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.localeController != null)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: LanguageMenuButton(
                          controller: widget.localeController!,
                        ),
                      ),
                    Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft, end: Alignment.bottomRight,
                          colors: [colors.stream, colors.leaf],
                        ),
                        boxShadow: [BoxShadow(color: colors.border, blurRadius: 14, spreadRadius: 0)],
                      ),
                      padding: const EdgeInsets.all(12),
                      child: Center(child: Image.asset('assets/logo.png', fit: BoxFit.contain)),
                    ),
                    const SizedBox(height: 20),
                    Text(l10n.appTitle, style: GoogleFonts.sora(fontSize: 28, fontWeight: FontWeight.w700, color: colors.foam, letterSpacing: 3)),
                    const SizedBox(height: 6),
                    Text(l10n.appTagline, style: GoogleFonts.inter(fontSize: 13, color: colors.mist)),
                    const SizedBox(height: 48),
                    _Field(
                      controller: _usernameCtl,
                      hint: l10n.authUsername,
                      icon: Icons.person_outline,
                      next: true,
                    ),
                    const SizedBox(height: 14),
                    _Field(
                      controller: _passwordCtl,
                      hint: l10n.authPassword,
                      icon: Icons.lock_outline,
                      obscure: _obscure,
                      suffix: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 18, color: colors.mist),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                      onSubmit: () => _login(),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity, height: 52,
                      child: FilledButton(
                        onPressed: _loading ? null : _login,
                        child: _loading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                            : Text(l10n.authSignIn, style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SignupScreen(localeController: widget.localeController))),
                      child: RichText(
                        text: TextSpan(
                          text: l10n.authNoAccount,
                          style: GoogleFonts.inter(fontSize: 13, color: colors.mist),
                          children: [TextSpan(text: l10n.authSignUp, style: TextStyle(color: colors.stream, fontWeight: FontWeight.w600))],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;
  final bool next;
  final VoidCallback? onSubmit;

  const _Field({required this.controller, required this.hint, required this.icon, this.obscure = false, this.suffix, this.next = false, this.onSubmit});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
      textInputAction: next ? TextInputAction.next : TextInputAction.done,
      onSubmitted: (_) => onSubmit?.call(),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.inter(fontSize: 14, color: colors.mist.withValues(alpha: 0.6)),
        prefixIcon: Icon(icon, size: 18, color: colors.mist),
        suffixIcon: suffix,
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.stream, width: 1.5),
        ),
      ),
    );
  }
}
