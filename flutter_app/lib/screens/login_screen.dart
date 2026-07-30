import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

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
    final u = _usernameCtl.text.trim();
    final p = _passwordCtl.text;
    if (u.isEmpty || p.isEmpty) { _err('Fill in all fields'); return; }
    setState(() => _loading = true);
    try {
      final data = await _api.login(u, p);
      await _auth.saveToken(data['token'] as String);
      await _auth.saveUsername(data['user']['username'] as String);
      if (mounted) Navigator.of(context).pushReplacementNamed('/home');
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
          child: FadeTransition(
            opacity: _fade,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft, end: Alignment.bottomRight,
                          colors: [Color(0xFF2DD4BF), Color(0xFF34D399)],
                        ),
                        boxShadow: const [BoxShadow(color: Color(0x332DD4BF), blurRadius: 24, spreadRadius: 2)],
                      ),
                      child: const Center(
                        child: Text('S', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: Color(0xFF0B1922))),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('STEES', style: GoogleFonts.sora(fontSize: 28, fontWeight: FontWeight.w700, color: const Color(0xFFF1F5F9), letterSpacing: 3)),
                    const SizedBox(height: 6),
                    Text('Smart Irrigation', style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8))),
                    const SizedBox(height: 48),
                    _Field(
                      controller: _usernameCtl,
                      hint: 'Username',
                      icon: Icons.person_outline,
                      next: true,
                    ),
                    const SizedBox(height: 14),
                    _Field(
                      controller: _passwordCtl,
                      hint: 'Password',
                      icon: Icons.lock_outline,
                      obscure: _obscure,
                      suffix: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 18, color: const Color(0xFF94A3B8)),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                      onSubmit: () => _login(),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity, height: 52,
                      child: FilledButton(
                        onPressed: _loading ? null : _login,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2DD4BF),
                          foregroundColor: const Color(0xFF0B1922),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: _loading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF0B1922)))
                            : Text('Sign In', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SignupScreen())),
                      child: RichText(
                        text: TextSpan(
                          text: "Don't have an account?  ",
                          style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF94A3B8)),
                          children: const [TextSpan(text: 'Sign Up', style: TextStyle(color: Color(0xFF2DD4BF), fontWeight: FontWeight.w600))],
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
