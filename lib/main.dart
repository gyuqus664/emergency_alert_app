import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:vibration/vibration.dart';
//import 'splash_screen.dart';

import 'firebase_options.dart';

import 'dart:convert';
import 'package:http/http.dart' as http;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

String? currentOpenAlertId;
bool isOpeningAlert = false;

Future<void> openAlertScreen({
  required String alertId,
  required Map<String, dynamic> alertData,
}) async {
  final nav = navigatorKey.currentState;
  if (nav == null) return;

  if (isOpeningAlert) return;
  if (currentOpenAlertId == alertId) return;

  isOpeningAlert = true;
  currentOpenAlertId = alertId;

  try {
    await nav.push(
      MaterialPageRoute(
        builder: (_) => AlertScreen(alertId: alertId, alertData: alertData),
      ),
    );
  } finally {
    if (currentOpenAlertId == alertId) {
      currentOpenAlertId = null;
    }
    isOpeningAlert = false;
  }
}

Future<void> triggerCriticalVibration(String severity) async {
  if (severity.toLowerCase() != 'critical') return;

  final hasVibrator = await Vibration.hasVibrator() ?? false;
  if (!hasVibrator) return;

  final hasAmplitudeControl = await Vibration.hasAmplitudeControl() ?? false;

  if (hasAmplitudeControl) {
    await Vibration.vibrate(
      pattern: [0, 500, 250, 500, 250, 700],
      intensities: [0, 255, 0, 255, 0, 255],
    );
  } else {
    await Vibration.vibrate(pattern: [0, 500, 250, 500, 250, 700]);
  }
}

Future<void> openAlertFromNotification(String alertId) async {
  try {
    final doc = await FirebaseFirestore.instance
        .collection('alerts')
        .doc(alertId)
        .get();

    if (!doc.exists) return;

    final data = doc.data();
    if (data == null) return;

    final status = data['status']?.toString() ?? 'active';
    if (status != 'active') return;

    final severity = data['severity']?.toString() ?? 'low';
    await triggerCriticalVibration(severity);

    await openAlertScreen(alertId: doc.id, alertData: data);
  } catch (e) {
    debugPrint('Failed to open alert from notification: $e');
  }
}

Future<void> sendPushViaWorker({
  required String title,
  required String message,
  required String severity,
  required String location,
  required String alertId,
}) async {
  final usersSnapshot = await FirebaseFirestore.instance
      .collection('users')
      .where('role', isEqualTo: 'user')
      .get();

  final oneSignalIds = <String>[];

  for (final doc in usersSnapshot.docs) {
    final data = doc.data();
    final oneSignalId = data['oneSignalId'];

    if (oneSignalId is String && oneSignalId.isNotEmpty) {
      oneSignalIds.add(oneSignalId);
    }
  }

  if (oneSignalIds.isEmpty) return;

  final response = await http.post(
    Uri.parse('https://alert-worker.emergency-alert-app.workers.dev'),
    headers: {
      'Content-Type': 'application/json',
      'x-app-secret': 'kaleb-emergency-alert-2026-secure-key-9x7p2m',
    },
    body: jsonEncode({
      'title': title,
      'message': message,
      'severity': severity,
      'location': location,
      'alertId': alertId,
      'oneSignalIds': oneSignalIds,
    }),
  );

  debugPrint('Worker push response: ${response.body}');
}

Future<UserCredential> signInWithGoogleAndCreateUserDoc() async {
  const webClientId =
      '223648767420-sit4bdavteepelbjg38mv1rt11701tta.apps.googleusercontent.com';

  final GoogleSignIn googleSignIn = GoogleSignIn.instance;

  await googleSignIn.initialize(serverClientId: webClientId);

  final GoogleSignInAccount googleUser = await googleSignIn.authenticate();
  final GoogleSignInAuthentication googleAuth = googleUser.authentication;

  final credential = GoogleAuthProvider.credential(idToken: googleAuth.idToken);

  final userCredential = await FirebaseAuth.instance.signInWithCredential(
    credential,
  );

  final user = userCredential.user;

  if (user != null) {
    final userDoc = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);

    final existing = await userDoc.get();
    final existingData = existing.data() ?? {};

    await userDoc.set({
      'fullName': user.displayName ?? existingData['fullName'] ?? '',
      'email': user.email ?? existingData['email'] ?? '',
      'role': existingData['role'] ?? 'user',
      'createdAt': existing.exists
          ? existingData['createdAt']
          : FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  return userCredential;
}

Future<void> saveOneSignalIdForCurrentUser() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  final subscriptionId = OneSignal.User.pushSubscription.id;
  if (subscriptionId == null) return;

  await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
    'oneSignalId': subscriptionId,
  }, SetOptions(merge: true));
}

Future<void> initializeOneSignalForCurrentUser() async {
  await OneSignal.Notifications.requestPermission(false);
  await saveOneSignalIdForCurrentUser();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
  OneSignal.initialize('21431963-9a53-406e-9558-21ab9f643ce4');

  OneSignal.Notifications.addClickListener((event) async {
    final data = event.notification.additionalData;
    final alertId = data?['alertId']?.toString();

    if (alertId != null && alertId.isNotEmpty) {
      await openAlertFromNotification(alertId);
    }
  });

  runApp(const MyApp());
}

const Color kBackground = Color(0xFF111315);
const Color kSurface = Color(0xFF171A1D);
const Color kSurfaceBorder = Color(0xFF262A2F);
const Color kPrimary = Color(0xFFB3261E);
const Color kTextPrimary = Color(0xFFF2F4F7);
const Color kTextSecondary = Color(0xFF9DA4AE);
const Color kInputFill = Color(0xFF1B1F23);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Emergency Alert App',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBackground,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kPrimary,
          brightness: Brightness.dark,
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            color: kTextPrimary,
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
          titleLarge: TextStyle(
            color: kTextPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
          bodyMedium: TextStyle(
            color: kTextSecondary,
            fontSize: 14,
            height: 1.45,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: kInputFill,
          labelStyle: const TextStyle(color: kTextSecondary),
          hintStyle: const TextStyle(color: kTextSecondary),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 18,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: kSurfaceBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: kSurfaceBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: kPrimary, width: 1.2),
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
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const LoadingScreen();
        }

        if (snapshot.hasData) {
          return const RoleChecker();
        }

        return const LoginScreen();
      },
    );
  }
}

class RoleChecker extends StatefulWidget {
  const RoleChecker({super.key});

  @override
  State<RoleChecker> createState() => _RoleCheckerState();
}

class _RoleCheckerState extends State<RoleChecker> {
  bool _initializedOneSignal = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (!_initializedOneSignal) {
      _initializedOneSignal = true;
      initializeOneSignalForCurrentUser();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const LoginScreen();
    }

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const LoadingScreen();
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Text(
                'Error loading role: ${snapshot.error}',
                style: const TextStyle(color: kTextPrimary),
              ),
            ),
          );
        }

        final data = snapshot.data?.data();
        final role = data?['role'] ?? 'user';

        if (role == 'admin') {
          return const AdminHomeScreen();
        }

        return const UserHomeScreen();
      },
    );
  }
}

class LoadingScreen extends StatelessWidget {
  const LoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator(color: kPrimary)),
    );
  }
}

class AuthShell extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const AuthShell({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Emergency Alert',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: kPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 10),
                  Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 28),
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: kSurface,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: kSurfaceBorder),
                    ),
                    child: child,
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

class PrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;

  const PrimaryButton({
    super.key,
    required this.onPressed,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: kPrimary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: child,
      ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String text;
  final IconData icon;

  const SecondaryButton({
    super.key,
    required this.onPressed,
    required this.text,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18, color: kTextPrimary),
        label: Text(
          text,
          style: const TextStyle(
            color: kTextPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: kSurfaceBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;

  const SectionTitle({super.key, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class InfoCard extends StatelessWidget {
  final String label;
  final String value;

  const InfoCard({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kInputFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kSurfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: kTextSecondary, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: kTextPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool isLoading = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      showMessage('Please enter email and password.');
      return;
    }

    setState(() => isLoading = true);

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      final code = e.code.toLowerCase();

      if (code == 'user-not-found' ||
          code == 'invalid-credential' ||
          code == 'invalid-login-credentials') {
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SignupScreen(initialEmail: email),
            ),
          );
        }
        showMessage('Account not found. Please sign up.');
      } else {
        showMessage(e.message ?? 'Login failed.');
      }
    } catch (e) {
      showMessage('Unexpected error: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> loginWithGoogle() async {
    setState(() => isLoading = true);

    try {
      await signInWithGoogleAndCreateUserDoc();
    } on FirebaseAuthException catch (e) {
      showMessage(e.message ?? 'Google sign-in failed.');
    } catch (e) {
      showMessage('Google sign-in failed: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF24282D),
        content: Text(message),
      ),
    );
  }

  void openSignup() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SignupScreen(initialEmail: emailController.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuthShell(
      title: 'Sign in',
      subtitle: 'Access your account to receive alerts and updates.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            title: 'Welcome back',
            subtitle: 'Use your email or continue with Google.',
          ),
          const SizedBox(height: 22),
          TextField(
            controller: emailController,
            keyboardType: TextInputType.emailAddress,
            style: const TextStyle(color: kTextPrimary),
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: passwordController,
            obscureText: true,
            style: const TextStyle(color: kTextPrimary),
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          const SizedBox(height: 22),
          PrimaryButton(
            onPressed: isLoading ? null : login,
            child: isLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Login',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
          ),
          const SizedBox(height: 12),
          SecondaryButton(
            onPressed: isLoading ? null : loginWithGoogle,
            text: 'Continue with Google',
            icon: Icons.login,
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: openSignup,
              child: const Text(
                "Don't have an account? Sign up",
                style: TextStyle(
                  color: kTextSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SignupScreen extends StatefulWidget {
  final String? initialEmail;

  const SignupScreen({super.key, this.initialEmail});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    emailController.text = widget.initialEmail ?? '';
  }

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> signUp() async {
    final fullName = nameController.text.trim();
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (fullName.isEmpty || email.isEmpty || password.isEmpty) {
      showMessage('Please fill in all fields.');
      return;
    }

    if (password.length < 6) {
      showMessage('Password must be at least 6 characters.');
      return;
    }

    setState(() => isLoading = true);

    try {
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);

      await FirebaseFirestore.instance
          .collection('users')
          .doc(credential.user!.uid)
          .set({
            'fullName': fullName,
            'email': email,
            'role': 'user',
            'createdAt': FieldValue.serverTimestamp(),
          });

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF24282D),
            content: Text('Account created successfully.'),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      showMessage(e.message ?? 'Signup failed.');
    } catch (e) {
      showMessage('Unexpected error: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> signUpWithGoogle() async {
    setState(() => isLoading = true);

    try {
      await signInWithGoogleAndCreateUserDoc();
    } on FirebaseAuthException catch (e) {
      showMessage(e.message ?? 'Google signup failed.');
    } catch (e) {
      showMessage('Google signup failed: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF24282D),
        content: Text(message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuthShell(
      title: 'Create account',
      subtitle: 'Set up your access for alerts and emergency updates.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            title: 'Get started',
            subtitle: 'Create an account or continue with Google.',
          ),
          const SizedBox(height: 22),
          TextField(
            controller: nameController,
            style: const TextStyle(color: kTextPrimary),
            decoration: const InputDecoration(labelText: 'Full name'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: emailController,
            keyboardType: TextInputType.emailAddress,
            style: const TextStyle(color: kTextPrimary),
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: passwordController,
            obscureText: true,
            style: const TextStyle(color: kTextPrimary),
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          const SizedBox(height: 22),
          PrimaryButton(
            onPressed: isLoading ? null : signUp,
            child: isLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Create Account',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
          ),
          const SizedBox(height: 12),
          SecondaryButton(
            onPressed: isLoading ? null : signUpWithGoogle,
            text: 'Continue with Google',
            icon: Icons.login,
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Already have an account? Login',
                style: TextStyle(
                  color: kTextSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class UserHomeScreen extends StatefulWidget {
  const UserHomeScreen({super.key});

  @override
  State<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends State<UserHomeScreen> {
  final Set<String> handledCriticalAlertIds = {};

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();
  }

  DateTime _extractCreatedAt(Map<String, dynamic> data) {
    final createdAt = data['createdAt'];
    if (createdAt is Timestamp) return createdAt.toDate();
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _maybeOpenCriticalAlert(String alertId, Map<String, dynamic> alert) {
    final severity = (alert['severity']?.toString() ?? '').toLowerCase();

    if (severity != 'critical') return;
    if (handledCriticalAlertIds.contains(alertId)) return;

    handledCriticalAlertIds.add(alertId);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      await triggerCriticalVibration(severity);

      await openAlertScreen(alertId: alertId, alertData: alert);
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: kSurface,
        title: const Text('User Home'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UserProfileScreen()),
              );
            },
            icon: const Icon(Icons.person_outline),
          ),
          IconButton(
            onPressed: () async => logout(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('alerts')
            .where('status', isEqualTo: 'active')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: kPrimary),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading alerts: ${snapshot.error}',
                style: const TextStyle(color: kTextPrimary),
                textAlign: TextAlign.center,
              ),
            );
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            handledCriticalAlertIds.clear();

            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'No active alerts',
                      style: TextStyle(
                        color: kTextPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'You are logged in as:\n${user?.email ?? ''}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          docs.sort((a, b) {
            final aDate = _extractCreatedAt(a.data());
            final bDate = _extractCreatedAt(b.data());
            return bDate.compareTo(aDate);
          });

          final activeIds = docs.map((doc) => doc.id).toSet();
          handledCriticalAlertIds.removeWhere((id) => !activeIds.contains(id));

          QueryDocumentSnapshot<Map<String, dynamic>>? newestUnhandledCritical;

          for (final doc in docs) {
            final data = doc.data();
            final severity = (data['severity']?.toString() ?? '').toLowerCase();

            if (severity == 'critical' &&
                !handledCriticalAlertIds.contains(doc.id)) {
              newestUnhandledCritical = doc;
              break;
            }
          }

          if (newestUnhandledCritical != null) {
            _maybeOpenCriticalAlert(
              newestUnhandledCritical.id,
              newestUnhandledCritical.data(),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(24),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final alert = doc.data();
              final alertId = doc.id;

              final title = alert['title']?.toString() ?? 'Untitled Alert';
              final message = alert['message']?.toString() ?? 'No message';
              final location =
                  alert['location']?.toString() ?? 'Unknown location';
              final severity = alert['severity']?.toString() ?? 'low';

              Color severityColor = kPrimary;
              if (severity == 'medium') severityColor = Colors.orange;
              if (severity == 'high') severityColor = Colors.deepOrange;
              if (severity == 'critical') severityColor = Colors.redAccent;

              return Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: kSurface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: kSurfaceBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: severityColor),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: kTextPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Severity: ${severity.toUpperCase()}',
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Location: $location',
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 16),
                    PrimaryButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                AlertScreen(alertId: alertId, alertData: alert),
                          ),
                        );
                      },
                      child: const Text(
                        'Open Alert',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key});

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  final TextEditingController nameController = TextEditingController();
  bool isSaving = false;

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  Future<void> saveProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final fullName = nameController.text.trim();
    if (fullName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF24282D),
          content: Text('Name cannot be empty.'),
        ),
      );
      return;
    }

    setState(() => isSaving = true);

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(
        {'fullName': fullName},
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF24282D),
            content: Text('Profile updated successfully.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF24282D),
            content: Text('Failed to update profile: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authUser = FirebaseAuth.instance.currentUser;

    if (authUser == null) {
      return const Scaffold(
        backgroundColor: kBackground,
        body: Center(
          child: Text(
            'No user is logged in.',
            style: TextStyle(color: kTextPrimary),
          ),
        ),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(authUser.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: kBackground,
            body: Center(child: CircularProgressIndicator(color: kPrimary)),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            backgroundColor: kBackground,
            appBar: AppBar(
              backgroundColor: kSurface,
              title: const Text('Profile'),
            ),
            body: Center(
              child: Text(
                'Error loading profile: ${snapshot.error}',
                style: const TextStyle(color: kTextPrimary),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final data = snapshot.data?.data() ?? {};
        final fullName = data['fullName']?.toString() ?? '';
        final email = data['email']?.toString() ?? authUser.email ?? '';
        final role = data['role']?.toString() ?? 'user';
        final oneSignalId = data['oneSignalId']?.toString() ?? 'Not available';

        if (nameController.text.isEmpty) {
          nameController.text = fullName;
        }

        return Scaffold(
          appBar: AppBar(
            backgroundColor: kSurface,
            title: const Text('Profile'),
            actions: [
              IconButton(
                onPressed: () async => logout(),
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: kSurface,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: kSurfaceBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionTitle(
                          title: 'User Profile',
                          subtitle: 'View and update your account details.',
                        ),
                        const SizedBox(height: 22),
                        TextField(
                          controller: nameController,
                          style: const TextStyle(color: kTextPrimary),
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                          ),
                        ),
                        const SizedBox(height: 14),
                        InfoCard(label: 'Email', value: email),
                        const SizedBox(height: 12),
                        InfoCard(label: 'Role', value: role.toUpperCase()),
                        const SizedBox(height: 12),
                        InfoCard(label: 'OneSignal ID', value: oneSignalId),
                        const SizedBox(height: 22),
                        PrimaryButton(
                          onPressed: isSaving ? null : saveProfile,
                          child: isSaving
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Save Profile',
                                  style: TextStyle(fontWeight: FontWeight.w600),
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
      },
    );
  }
}

class AlertScreen extends StatefulWidget {
  final String alertId;
  final Map<String, dynamic> alertData;

  const AlertScreen({
    super.key,
    required this.alertId,
    required this.alertData,
  });

  @override
  State<AlertScreen> createState() => _AlertScreenState();
}

class _AlertScreenState extends State<AlertScreen> {
  bool isSubmittingResponse = false;
  final TextEditingController customMessageController = TextEditingController();

  @override
  void dispose() {
    customMessageController.dispose();
    super.dispose();
  }

  Future<void> submitResponse(String responseType) async {
    final user = FirebaseAuth.instance.currentUser;
    final customMessage = customMessageController.text.trim();

    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF24282D),
          content: Text('You must be logged in to respond.'),
        ),
      );
      return;
    }

    if (responseType == 'Send Update' && customMessage.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF24282D),
          content: Text('Please type a message first.'),
        ),
      );
      return;
    }

    setState(() => isSubmittingResponse = true);

    try {
      await FirebaseFirestore.instance
          .collection('alerts')
          .doc(widget.alertId)
          .collection('responses')
          .doc(user.uid)
          .set({
            'userId': user.uid,
            'email': user.email ?? '',
            'responseType': responseType,
            'customMessage': responseType == 'Send Update' ? customMessage : '',
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      if (responseType == 'Send Update') {
        customMessageController.clear();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF24282D),
            content: Text('Response sent: $responseType'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF24282D),
            content: Text('Failed to send response: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isSubmittingResponse = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('alerts')
          .doc(widget.alertId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: kBackground,
            body: Center(child: CircularProgressIndicator(color: kPrimary)),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            backgroundColor: kBackground,
            appBar: AppBar(
              backgroundColor: kSurface,
              title: const Text('Alert Details'),
            ),
            body: Center(
              child: Text(
                'Error loading alert: ${snapshot.error}',
                style: const TextStyle(color: kTextPrimary),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final doc = snapshot.data;

        if (doc == null || !doc.exists || doc.data() == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context);
          });

          return const Scaffold(
            backgroundColor: kBackground,
            body: Center(
              child: Text(
                'Alert no longer exists.',
                style: TextStyle(color: kTextPrimary),
              ),
            ),
          );
        }

        final alertData = doc.data()!;
        final status = alertData['status']?.toString() ?? 'active';

        if (status == 'resolved') {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;

            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                backgroundColor: Color(0xFF24282D),
                content: Text('This alert has been resolved.'),
              ),
            );

            Navigator.pop(context);
          });

          return const Scaffold(
            backgroundColor: kBackground,
            body: Center(
              child: Text(
                'This alert has been resolved.',
                style: TextStyle(color: kTextPrimary),
              ),
            ),
          );
        }

        final title = alertData['title']?.toString() ?? 'Untitled Alert';
        final message = alertData['message']?.toString() ?? 'No message';
        final location =
            alertData['location']?.toString() ?? 'Unknown location';
        final severity =
            alertData['severity']?.toString().toLowerCase() ?? 'low';

        final isCritical = severity == 'critical';

        Color severityColor = kPrimary;
        if (severity == 'medium') severityColor = Colors.orange;
        if (severity == 'high') severityColor = Colors.deepOrange;
        if (severity == 'critical') severityColor = Colors.redAccent;

        return Scaffold(
          backgroundColor: isCritical ? const Color(0xFF180909) : kBackground,
          appBar: AppBar(
            backgroundColor: isCritical ? const Color(0xFF2A0D0D) : kSurface,
            title: Text(isCritical ? 'Critical Alert' : 'Alert Details'),
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: isCritical ? const Color(0xFF2A0D0D) : kSurface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isCritical ? Colors.redAccent : kSurfaceBorder,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: severityColor,
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                color: kTextPrimary,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    InfoCard(label: 'Alert ID', value: widget.alertId),
                    const SizedBox(height: 12),
                    InfoCard(label: 'Severity', value: severity.toUpperCase()),
                    const SizedBox(height: 12),
                    InfoCard(label: 'Location', value: location),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: isCritical ? const Color(0xFF221010) : kSurface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isCritical ? Colors.redAccent : kSurfaceBorder,
                        ),
                      ),
                      child: Text(
                        message,
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 16,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Your Response',
                      style: TextStyle(
                        color: kTextPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    PrimaryButton(
                      onPressed: isSubmittingResponse
                          ? null
                          : () => submitResponse("I'm Safe"),
                      child: isSubmittingResponse
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              "I'm Safe",
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                    ),
                    const SizedBox(height: 10),
                    SecondaryButton(
                      onPressed: isSubmittingResponse
                          ? null
                          : () => submitResponse('Need Help'),
                      text: 'Need Help',
                      icon: Icons.support_agent,
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: customMessageController,
                      maxLines: 3,
                      style: const TextStyle(color: kTextPrimary),
                      decoration: const InputDecoration(
                        labelText: 'Type your update here',
                        hintText:
                            'Example: We are in room 4 and need assistance.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    PrimaryButton(
                      onPressed: isSubmittingResponse
                          ? null
                          : () => submitResponse('Send Update'),
                      child: isSubmittingResponse
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Send Update',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  final titleController = TextEditingController();
  final messageController = TextEditingController();
  final locationController = TextEditingController();

  String severity = 'low';
  bool isLoading = false;

  @override
  void dispose() {
    titleController.dispose();
    messageController.dispose();
    locationController.dispose();
    super.dispose();
  }

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();
  }

  Future<void> createAlert() async {
    final title = titleController.text.trim();
    final message = messageController.text.trim();
    final location = locationController.text.trim();
    final user = FirebaseAuth.instance.currentUser;

    if (title.isEmpty || message.isEmpty || location.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF24282D),
          content: Text('Please fill in all fields.'),
        ),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      final alertRef = await FirebaseFirestore.instance
          .collection('alerts')
          .add({
            'title': title,
            'message': message,
            'location': location,
            'severity': severity,
            'status': 'active',
            'createdAt': FieldValue.serverTimestamp(),
            'createdBy': user?.uid,
          });

      await sendPushViaWorker(
        title: title,
        message: message,
        severity: severity,
        location: location,
        alertId: alertRef.id,
      );

      titleController.clear();
      messageController.clear();
      locationController.clear();

      setState(() => severity = 'low');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF24282D),
            content: Text('Alert sent successfully.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF24282D),
            content: Text('Failed to send alert: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> resolveAlert(String alertId) async {
    try {
      await FirebaseFirestore.instance.collection('alerts').doc(alertId).update(
        {'status': 'resolved', 'resolvedAt': FieldValue.serverTimestamp()},
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF24282D),
            content: Text('Alert resolved successfully.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF24282D),
            content: Text('Failed to resolve alert: $e'),
          ),
        );
      }
    }
  }

  Future<void> resolveAllAlerts() async {
    setState(() => isLoading = true);

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('alerts')
          .where('status', isEqualTo: 'active')
          .get();

      for (final doc in snapshot.docs) {
        await doc.reference.update({
          'status': 'resolved',
          'resolvedAt': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF24282D),
            content: Text('All active alerts resolved.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF24282D),
            content: Text('Failed to resolve alerts: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> deleteAllResolvedAlerts() async {
    setState(() => isLoading = true);

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('alerts')
          .where('status', isEqualTo: 'resolved')
          .get();

      for (final alertDoc in snapshot.docs) {
        final responsesSnapshot = await alertDoc.reference
            .collection('responses')
            .get();

        for (final responseDoc in responsesSnapshot.docs) {
          await responseDoc.reference.delete();
        }

        await alertDoc.reference.delete();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF24282D),
            content: Text('All resolved alerts and responses deleted.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF24282D),
            content: Text('Failed to delete resolved alerts: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> confirmDeleteAllResolvedAlerts() async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: kSurface,
          title: const Text(
            'Delete resolved alerts?',
            style: TextStyle(color: kTextPrimary),
          ),
          content: const Text(
            'This will permanently delete all resolved alerts.',
            style: TextStyle(color: kTextSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                'Delete',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        );
      },
    );

    if (shouldDelete == true) {
      await deleteAllResolvedAlerts();
    }
  }

  DateTime _extractCreatedAt(Map<String, dynamic> data) {
    final createdAt = data['createdAt'];
    if (createdAt is Timestamp) return createdAt.toDate();
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  Color _severityColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'medium':
        return Colors.orange;
      case 'high':
        return Colors.deepOrange;
      case 'critical':
        return Colors.redAccent;
      default:
        return kPrimary;
    }
  }

  String _formatTimestamp(dynamic value) {
    if (value is Timestamp) {
      final dt = value.toDate();
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return 'Unknown time';
  }

  Widget _buildResponsesList(String alertId) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('alerts')
          .doc(alertId)
          .collection('responses')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: CircularProgressIndicator(color: kPrimary),
          );
        }

        if (snapshot.hasError) {
          return Text(
            'Error loading responses: ${snapshot.error}',
            style: const TextStyle(color: kTextSecondary),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return const Text(
            'No responses yet.',
            style: TextStyle(color: kTextSecondary),
          );
        }

        int responsePriority(String type) {
          switch (type) {
            case 'Need Help':
              return 0;
            case 'Send Update':
              return 1;
            case "I'm Safe":
              return 2;
            default:
              return 3;
          }
        }

        Color responseColor(String type) {
          switch (type) {
            case 'Need Help':
              return Colors.orange;
            case 'Send Update':
              return kPrimary;
            case "I'm Safe":
              return Colors.green;
            default:
              return kTextSecondary;
          }
        }

        IconData responseIcon(String type) {
          switch (type) {
            case 'Need Help':
              return Icons.support_agent;
            case 'Send Update':
              return Icons.edit_note;
            case "I'm Safe":
              return Icons.check_circle;
            default:
              return Icons.info_outline;
          }
        }

        docs.sort((a, b) {
          final aData = a.data();
          final bData = b.data();

          final aType = aData['responseType']?.toString() ?? '';
          final bType = bData['responseType']?.toString() ?? '';

          final typeCompare = responsePriority(
            aType,
          ).compareTo(responsePriority(bType));
          if (typeCompare != 0) return typeCompare;

          final aDate = _extractCreatedAt(aData);
          final bDate = _extractCreatedAt(bData);
          return bDate.compareTo(aDate);
        });

        return Column(
          children: docs.map((doc) {
            final data = doc.data();
            final email = data['email']?.toString() ?? 'Unknown user';
            final responseType =
                data['responseType']?.toString() ?? 'Unknown response';
            final customMessage = data['customMessage']?.toString() ?? '';
            final createdAt = _formatTimestamp(data['createdAt']);
            final badgeColor = responseColor(responseType);

            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kSurfaceBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          email,
                          style: const TextStyle(
                            color: kTextPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: kInputFill,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: kSurfaceBorder),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              responseIcon(responseType),
                              size: 14,
                              color: badgeColor,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              responseType,
                              style: TextStyle(
                                color: badgeColor,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (customMessage.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: kInputFill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: kSurfaceBorder),
                      ),
                      child: Text(
                        customMessage,
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                    ),
                  if (customMessage.isNotEmpty) const SizedBox(height: 10),
                  Text(
                    'Updated at: $createdAt',
                    style: const TextStyle(color: kTextSecondary, fontSize: 12),
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Map<String, int> _countResponses(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    int safeCount = 0;
    int helpCount = 0;
    int updateCount = 0;

    for (final doc in docs) {
      final data = doc.data();
      final type = data['responseType']?.toString() ?? '';

      if (type == "I'm Safe") {
        safeCount++;
      } else if (type == 'Need Help') {
        helpCount++;
      } else if (type == 'Send Update') {
        updateCount++;
      }
    }

    return {
      "I'm Safe": safeCount,
      'Need Help': helpCount,
      'Send Update': updateCount,
    };
  }

  Widget _buildResponseSummary(String alertId) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('alerts')
          .doc(alertId)
          .collection('responses')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: CircularProgressIndicator(color: kPrimary),
          );
        }

        if (snapshot.hasError) {
          return Text(
            'Error loading summary: ${snapshot.error}',
            style: const TextStyle(color: kTextSecondary),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        final counts = _countResponses(docs);

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kSurfaceBorder),
          ),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _buildSummaryChip(
                "I'm Safe",
                counts["I'm Safe"] ?? 0,
                Colors.green,
              ),
              _buildSummaryChip(
                'Need Help',
                counts['Need Help'] ?? 0,
                Colors.orange,
              ),
              _buildSummaryChip(
                'Send Update',
                counts['Send Update'] ?? 0,
                kPrimary,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSummaryChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kInputFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kSurfaceBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            '$label: $count',
            style: const TextStyle(
              color: kTextPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertsSection({
    required String title,
    required String subtitle,
    required String status,
    required bool showResponses,
    required bool showResolveButton,
  }) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: kSurfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(title: title, subtitle: subtitle),
          const SizedBox(height: 18),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('alerts')
                .where('status', isEqualTo: status)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(color: kPrimary),
                  ),
                );
              }

              if (snapshot.hasError) {
                return Text(
                  'Error loading alerts: ${snapshot.error}',
                  style: const TextStyle(color: kTextPrimary),
                );
              }

              final docs = snapshot.data?.docs ?? [];

              if (docs.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'No $status alerts.',
                    style: const TextStyle(color: kTextSecondary),
                  ),
                );
              }

              docs.sort((a, b) {
                final aDate = _extractCreatedAt(a.data());
                final bDate = _extractCreatedAt(b.data());
                return bDate.compareTo(aDate);
              });

              return Column(
                children: docs.map((doc) {
                  final alert = doc.data();
                  final alertId = doc.id;

                  final alertTitle =
                      alert['title']?.toString() ?? 'Untitled Alert';
                  final message = alert['message']?.toString() ?? 'No message';
                  final location =
                      alert['location']?.toString() ?? 'Unknown location';
                  final severityText = alert['severity']?.toString() ?? 'low';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: kInputFill,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kSurfaceBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: _severityColor(severityText),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                alertTitle,
                                style: const TextStyle(
                                  color: kTextPrimary,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Severity: ${severityText.toUpperCase()}',
                          style: const TextStyle(
                            color: kTextSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Location: $location',
                          style: const TextStyle(
                            color: kTextSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          message,
                          style: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                        if (showResolveButton) ...[
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () => resolveAlert(alertId),
                              icon: const Icon(Icons.check),
                              label: const Text('Resolve This Alert'),
                            ),
                          ),
                        ],
                        if (showResponses) ...[
                          const SizedBox(height: 16),
                          const Text(
                            'Response Summary',
                            style: TextStyle(
                              color: kTextPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildResponseSummary(alertId),
                          const SizedBox(height: 16),
                          const Text(
                            'User Responses',
                            style: TextStyle(
                              color: kTextPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildResponsesList(alertId),
                        ],
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kSurface,
        title: const Text('Admin Panel'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UserProfileScreen()),
              );
            },
            icon: const Icon(Icons.person_outline),
          ),
          IconButton(
            onPressed: () async => logout(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: kSurface,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: kSurfaceBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionTitle(
                          title: 'Create alert',
                          subtitle: 'Send an emergency alert to active users.',
                        ),
                        const SizedBox(height: 22),
                        TextField(
                          controller: titleController,
                          style: const TextStyle(color: kTextPrimary),
                          decoration: const InputDecoration(
                            labelText: 'Alert title',
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: messageController,
                          maxLines: 4,
                          style: const TextStyle(color: kTextPrimary),
                          decoration: const InputDecoration(
                            labelText: 'Alert message',
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: locationController,
                          style: const TextStyle(color: kTextPrimary),
                          decoration: const InputDecoration(
                            labelText: 'Location',
                          ),
                        ),
                        const SizedBox(height: 14),
                        DropdownButtonFormField<String>(
                          value: severity,
                          dropdownColor: kSurface,
                          style: const TextStyle(color: kTextPrimary),
                          decoration: const InputDecoration(
                            labelText: 'Severity',
                          ),
                          items: const [
                            DropdownMenuItem(value: 'low', child: Text('Low')),
                            DropdownMenuItem(
                              value: 'medium',
                              child: Text('Medium'),
                            ),
                            DropdownMenuItem(
                              value: 'high',
                              child: Text('High'),
                            ),
                            DropdownMenuItem(
                              value: 'critical',
                              child: Text('Critical'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => severity = value);
                            }
                          },
                        ),
                        const SizedBox(height: 22),
                        PrimaryButton(
                          onPressed: isLoading ? null : createAlert,
                          child: isLoading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Send Alert',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                        ),
                        const SizedBox(height: 12),
                        SecondaryButton(
                          onPressed: isLoading ? null : resolveAllAlerts,
                          text: 'Resolve Active Alerts',
                          icon: Icons.check_circle_outline,
                        ),
                        const SizedBox(height: 12),
                        SecondaryButton(
                          onPressed: isLoading
                              ? null
                              : confirmDeleteAllResolvedAlerts,
                          text: 'Delete Resolved Alerts',
                          icon: Icons.delete_outline,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildAlertsSection(
                    title: 'Active alerts',
                    subtitle: 'View and manage active alerts and responses.',
                    status: 'active',
                    showResponses: true,
                    showResolveButton: true,
                  ),
                  const SizedBox(height: 20),
                  _buildAlertsSection(
                    title: 'Resolved alerts',
                    subtitle: 'Review alerts that have already been resolved.',
                    status: 'resolved',
                    showResponses: false,
                    showResolveButton: false,
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
