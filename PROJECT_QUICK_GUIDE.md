# Auric Project Quick Guide

Short, point-to-point overview for quick study.

## 1) Project structure

- `backend/`
  - Java Spring Boot API.
  - Handles auth, calculator history, AI chat streaming, database.

- `flutter_app/`
  - Flutter mobile app.
  - Handles UI, user actions, chat screen, calculator screen.

## 2) Backend folders and purpose

- `backend/src/main/java/com/auric/config/`
  - App config files.
  - `SecurityConfig`: API security + protected routes.
  - `WebClientConfig`: OpenAI HTTP client setup.

- `backend/src/main/java/com/auric/controller/`
  - REST endpoints.
  - `AuthController`: Google sign-in verification.
  - `CalcController`: calculator history API.
  - `AiChatController`: sessions/messages + chat stream endpoint.

- `backend/src/main/java/com/auric/service/`
  - Core logic.
  - `OpenAiService`: prompt + model call + token streaming.
  - `LegacyDataMigrationService`: old user-data migration helper.

- `backend/src/main/java/com/auric/model/`
  - Database entities.
  - `CalcHistory`, `ChatSession`, `ChatMessage`.

- `backend/src/main/java/com/auric/repository/`
  - DB query layer (JPA repositories).

- `backend/src/main/java/com/auric/dto/`
  - Request/response payload classes (`Dtos.java`).

- `backend/src/main/resources/`
  - `application.properties` config (DB, OpenAI, Google, CORS).

## 3) Flutter folders and purpose

- `flutter_app/lib/main.dart`
  - App start point, loads env, sets providers, routes to login/home.

- `flutter_app/lib/screens/`
  - Main pages:
  - `login_screen.dart`, `home_screen.dart`, `calculator_screen.dart`, `ai_chat_screen.dart`, `settings_screen.dart`.

- `flutter_app/lib/services/`
  - App logic layer:
  - `api_service.dart` (all backend calls + SSE parser)
  - `auth_provider.dart` (Google login + token storage)
  - `settings_provider.dart` (theme settings)

- `flutter_app/lib/models/`
  - Data models from backend JSON.

- `flutter_app/lib/theme/`
  - App color/theme setup.

- `flutter_app/lib/widgets/`
  - Reusable UI components.

## 4) AI Chat feature - how it works

- User sends message (optional image + voice text).
- Flutter adds user bubble instantly (optimistic UI).
- Flutter calls `/api/ai/chat`.
- Backend resolves/creates session, stores user message.
- `OpenAiService` calls OpenAI with history + mode (`fast` or `detailed`).
- Backend streams tokens as SSE events (`meta`, `token`, `title`, `done`).
- Flutter appends tokens live into assistant bubble.
- After complete, backend saves assistant message and may update session title.

Main chat features:
- live streaming response
- chat sessions (new/select/rename/delete)
- image upload and AI image analysis
- voice input with auto-send
- "My Stuff" image gallery from saved messages

## 5) Calculator feature - how it works

- User taps calculator buttons.
- Flutter builds expression and computes live result locally.
- On `=` final result is computed with parser + scientific functions.
- Valid result gets auto-saved to backend history.
- Backend stores equation/result per authenticated user.
- User can load history, filter by date, delete entries, deduplicate.

Main calculator features:
- standard + scientific operations
- RAD/DEG + inverse trig
- expression parser with precedence
- domain checks (invalid math cases)
- history drawer + export/share

## 6) Important overall flow

- Login: Flutter Google Sign-In -> backend verifies token.
- Security: protected APIs need Bearer token.
- Ownership: backend always uses JWT subject as `userId`.
- Storage: SQLite DB in backend (`auric.db`).

## 7) 10-second viva summary

Auric is a Flutter + Spring Boot app. Flutter handles UI and local calculator logic. Spring backend handles auth, calculator history persistence, and AI chat streaming with OpenAI. Chat supports sessions, live token streaming, image input, and voice input.
