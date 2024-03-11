import 'package:faker/faker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_login/flutter_login.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'rooms.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final faker = Faker();

  @override
  Widget build(BuildContext context) => FlutterLogin(
        logo: const AssetImage('assets/flyer_logo.png'),
        savedEmail: faker.internet.email(),
        savedPassword: 'Qawsed1-', //faker.internet.password(),
        navigateBackAfterRecovery: true,
        additionalSignupFields: [
          UserFormField(
            keyName: 'first_name',
            displayName: 'First name',
            defaultValue: faker.person.firstName(),
            fieldValidator: (value) {
              if (value == null || value == '') return 'Required';
              return null;
            },
          ),
          UserFormField(
            keyName: 'last_name',
            displayName: 'Last name',
            defaultValue: faker.person.lastName(),
            fieldValidator: (value) {
              if (value == null || value == '') return 'Required';
              return null;
            },
          ),
        ],
        passwordValidator: (value) {
          if (value!.isEmpty) {
            return 'Password is empty';
          }
          return null;
        },
        onLogin: (loginData) async {
          try {
            await Supabase.instance.client.auth.signInWithPassword(
              email: loginData.name,
              password: loginData.password,
            );
          } catch (e) {
            return e.toString();
          }
          return null;
        },
        onSignup: (signupData) async {
          try {
            final response = await Supabase.instance.client.auth.signUp(
              email: signupData.name,
              password: signupData.password!,
            );
            await SupabaseChatCore.instance.updateUser(
              types.User(
                firstName: signupData.additionalSignupData!['first_name'],
                id: response.user!.id,
                lastName: signupData.additionalSignupData!['last_name'],
              ),
            );
          } catch (e) {
            return e.toString();
          }
          return null;
        },
        onSubmitAnimationCompleted: () {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => const RoomsPage(),
            ),
          );
        },
        onRecoverPassword: (name) async {
          try {
            await Supabase.instance.client.auth.resetPasswordForEmail(
              name,
            );
          } catch (e) {
            return e.toString();
          }
          return null;
        },
        //headerWidget: const IntroWidget(),
        initialAuthMode: AuthMode.signup,
      );
}

class IntroWidget extends StatelessWidget {
  const IntroWidget({super.key});

  @override
  Widget build(BuildContext context) => const Column(
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'You are trying to login/sign up on server hosted on ',
                ),
                TextSpan(
                  text: 'example.com',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            textAlign: TextAlign.justify,
          ),
          Row(
            children: <Widget>[
              Expanded(child: Divider()),
              Padding(
                padding: EdgeInsets.all(8.0),
                child: Text('Authenticate'),
              ),
              Expanded(child: Divider()),
            ],
          ),
        ],
      );
}
