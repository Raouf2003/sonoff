import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _usernameCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  final _confirmCtl = TextEditingController();
  final _api = ApiService();
  final _auth = AuthService();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _usernameCtl.dispose();
    _passwordCtl.dispose();
    _confirmCtl.dispose();
    super.dispose();
  }

  Future<void> _signup() async {
    if (_loading) return;
    final u = _usernameCtl.text.trim();
    final p = _passwordCtl.text;
    final c = _confirmCtl.text;
    if (u.isEmpty || p.isEmpty || c.isEmpty) { _err('Fill in all fields'); return; }
    if (p != c) { _err('Passwords do not match'); return; }
    if (p.length < 6) { _err('Password must be at least 6 characters'); return; }
    setState(() => _loading = true);
    try {
      final data = await _api.signup(u, p);
      await _auth.saveToken(data['token'] as String);
      await _auth.saveUsername(data['user']['username'] as String);
      if (mounted) Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
    } catch (e) { _err(_friendly(e)); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  // ApiException already carries a user-safe message; anything else is a
  // programming/server edge case we never surface verbatim.
  String _friendly(Object e) =>
      e is ApiException ? e.message : 'Something went wrong. Please try again.';

  void _err(String m) {
    if (!mounted) return;
    final colors = context.steesColors;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m, style: const TextStyle(fontSize: 13)),
        backgroundColor: colors.danger, behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [colors.well, Theme.of(context).colorScheme.surfaceContainerHighest, colors.well],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Create Account', style: GoogleFonts.sora(fontSize: 24, fontWeight: FontWeight.w700, color: colors.foam)),
                  const SizedBox(height: 6),
                  Text('Join STEES', style: GoogleFonts.inter(fontSize: 13, color: colors.mist)),
                  const SizedBox(height: 36),
                  _Field(controller: _usernameCtl, hint: 'Username', icon: Icons.person_outline, next: true),
                  const SizedBox(height: 14),
                  _Field(controller: _passwordCtl, hint: 'Password', icon: Icons.lock_outline, obscure: _obscure, next: true),
                  const SizedBox(height: 14),
                  _Field(
                    controller: _confirmCtl, hint: 'Confirm Password', icon: Icons.lock_outline, obscure: _obscure,
                    suffix: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 18, color: colors.mist),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    onSubmit: () => _signup(),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity, height: 52,
                    child: FilledButton(
                      onPressed: _loading ? null : _signup,
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.stream,
                        foregroundColor: colors.well,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: _loading
                          ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.well))
                          : Text('Create Account', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: RichText(
                      text: TextSpan(
                        text: 'Already have an account?  ',
                        style: GoogleFonts.inter(fontSize: 13, color: colors.mist),
                        children: [TextSpan(text: 'Sign In', style: TextStyle(color: colors.stream, fontWeight: FontWeight.w600))],
                      ),
                    ),
                  ),
                ],
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
        fillColor: colors.submerged,
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
