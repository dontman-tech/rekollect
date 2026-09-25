import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'firebase_options.dart';
import 'models/app_user.dart';
import 'screens/auth_screen.dart';
import 'screens/collector_screen.dart';
import 'screens/generator_screen.dart';
import 'services/firestore_service.dart';
import 'services/messaging_service.dart';
import 'widgets/eco_background.dart';
import 'widgets/glass_card.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const RekollectApp());
}

class RekollectApp extends StatelessWidget {
  const RekollectApp({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = GoogleFonts.plusJakartaSansTextTheme(ThemeData.dark().textTheme);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Re-kollect',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF064E3B),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10B981),
          brightness: Brightness.dark,
          primary: const Color(0xFF10B981),
          secondary: const Color(0xFF4ADE80),
        ),
        textTheme: textTheme.copyWith(
          headlineLarge: textTheme.headlineLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
          titleLarge: textTheme.titleLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
          bodyMedium: textTheme.bodyMedium?.copyWith(
            color: const Color(0xFFE2E8F0),
            fontWeight: FontWeight.w500,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withOpacity(0.10),
          labelStyle: const TextStyle(color: Color(0xFFE2E8F0)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.20)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF4ADE80), width: 1.2),
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final firestore = FirestoreService(FirebaseFirestore.instance);
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnapshot) {
        final firebaseUser = authSnapshot.data;
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          return const _LoadingScreen();
        }
        if (firebaseUser == null) {
          return AuthScreen(firestore: firestore, auth: FirebaseAuth.instance);
        }
        return StreamBuilder<AppUser?>(
          stream: firestore.streamUser(firebaseUser.uid),
          builder: (context, userSnapshot) {
            if (userSnapshot.connectionState == ConnectionState.waiting) {
              return const _LoadingScreen();
            }
            final appUser = userSnapshot.data;
            if (appUser == null) {
              return AuthScreen(firestore: firestore, auth: FirebaseAuth.instance);
            }
            return _RoleHome(user: appUser, firestore: firestore);
          },
        );
      },
    );
  }
}

class _RoleHome extends StatefulWidget {
  const _RoleHome({required this.user, required this.firestore});

  final AppUser user;
  final FirestoreService firestore;

  @override
  State<_RoleHome> createState() => _RoleHomeState();
}

class _RoleHomeState extends State<_RoleHome> {
  @override
  void initState() {
    super.initState();
    MessagingService(FirebaseMessaging.instance).initializeForRole(widget.user.role, uid: widget.user.uid);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.user.isCollector) {
      return CollectorScreen(user: widget.user, firestore: widget.firestore);
    }
    return GeneratorScreen(user: widget.user, firestore: widget.firestore);
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: EcoBackground(
        child: Center(
          child: GlassCard(
            child: CircularProgressIndicator(color: Color(0xFF4ADE80)),
          ),
        ),
      ),
    );
  }
}
