import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';

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
    } catch (e) { _err(e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  void _err(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m, style: const TextStyle(fontSize: 13)),
        backgroundColor: Colors.redAccent.shade200, behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Color(0xFF0B1922), Color(0xFF0F2332), Color(0xFF0B1922)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Create Account', style: GoogleFonts.sora(fontSize: 24, fontWeight: FontWeight.w700, color: const Color(0xFFF1F5F9))),
                  const SizedBox(height: 6),
                  Text('Join STEES', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8))),
                  const SizedBox(height: 36),
                  _Field(controller: _usernameCtl, hint: 'Username', icon: Icons.person_outline, next: true),
                  const SizedBox(height: 14),
                  _Field(controller: _passwordCtl, hint: 'Password', icon: Icons.lock_outline, obscure: true, next: true),
                  const SizedBox(height: 14),
                  _Field(
                    controller: _confirmCtl, hint: 'Confirm Password', icon: Icons.lock_outline, obscure: _obscure,
                    suffix: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 18, color: const Color(0xFF94A3B8)),
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
                        backgroundColor: const Color(0xFF2DD4BF),
                        foregroundColor: const Color(0xFF0B1922),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: _loading
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF0B1922)))
                          : Text('Create Account', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: RichText(
                      text: TextSpan(
                        text: 'Already have an account?  ',
                        style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8)),
                        children: const [TextSpan(text: 'Sign In', style: TextStyle(color: Color(0xFF2DD4BF), fontWeight: FontWeight.w600))],
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
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: GoogleFonts.inter(fontSize: 14, color: const Color(0xFFF1F5F9)),
      textInputAction: next ? TextInputAction.next : TextInputAction.done,
      onSubmitted: (_) => onSubmit?.call(),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.inter(fontSize: 14, color: const Color(0xFF94A3B8).withValues(alpha: 0.6)),
        prefixIcon: Icon(icon, size: 18, color: const Color(0xFF94A3B8)),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFF1A2D3D),
        contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF2DD4BF), width: 1.5),
        ),
      ),
    );
  }
}
