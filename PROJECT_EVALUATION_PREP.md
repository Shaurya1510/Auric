# Auric Evaluation Prep (Safe Mode)

Use this to prepare for viva/demo. It is focused on what teachers usually ask.

## 1) 30-second intro (memorize)

Auric is a Flutter mobile app with a Spring Boot backend and SQLite database. Users sign in with Google, use a scientific calculator with saved history, and chat with an AI assistant. AI replies are streamed live using SSE. Chat sessions/messages and calculator history are stored per authenticated user.

## 2) Must-know architecture

- Frontend: `flutter_app` (UI + state + API calls)
- Backend: `backend` (auth, APIs, AI integration, persistence)
- DB: SQLite (`backend/auric.db`)
- Auth: Google ID token verification + bearer token protected endpoints
- AI: OpenAI via backend `OpenAiService`

## 3) Critical folders and what they contain

### Backend
- `config/`: security and OpenAI web client config
- `controller/`: API endpoints (auth/calc/ai)
- `service/`: business logic (OpenAI streaming, migration)
- `model/`: DB entities (`CalcHistory`, `ChatSession`, `ChatMessage`)
- `repository/`: DB query interfaces
- `dto/`: request/response payload classes

### Flutter
- `screens/`: app pages (login/home/calculator/chat/settings)
- `services/`: API and app logic (`api_service`, `auth_provider`, `settings_provider`)
- `models/`: JSON data models
- `theme/`: light/dark theme config
- `widgets/`: reusable UI widgets

## 4) 5 flows you must explain clearly

## A) Login flow
1. User taps Google sign-in in Flutter.
2. Flutter gets Google `idToken`.
3. Flutter calls backend `/api/auth/google`.
4. Backend verifies token and returns profile + access token.
5. Flutter stores token securely and uses it for protected APIs.

## B) Calculator flow
1. User enters expression in Flutter calculator screen.
2. Flutter parser computes live/final result locally.
3. On valid result, Flutter calls `/api/calc/history` to save.
4. Backend stores equation/result with authenticated `userId`.
5. History is fetched/deleted via calc endpoints.

## C) AI chat streaming flow
1. User sends text/image.
2. Flutter adds user bubble instantly (optimistic UI).
3. Flutter calls `/api/ai/chat` with history + mode.
4. Backend creates/uses session, saves user message.
5. `OpenAiService` calls OpenAI and streams token chunks.
6. Backend emits SSE events: `meta`, `token`, `title`, `done`.
7. Flutter appends tokens live in assistant bubble.
8. Backend saves assistant message after stream completes.

## D) Session management flow
1. Sidebar loads sessions from `/api/ai/sessions`.
2. Create session: POST sessions.
3. Rename session: PATCH sessions/{id}.
4. Delete session: DELETE sessions/{id}.
5. Select session loads messages by session ID.

## E) Image flow
1. User picks camera/gallery image.
2. Flutter converts to base64 and sends with message.
3. Backend forwards image context to OpenAI vision model.
4. Image-containing messages are stored.
5. Gallery (`My Stuff`) loads from `/api/ai/images`.

## 5) Security and ownership (high-scoring answers)

- Protected routes: `/api/calc/**`, `/api/ai/**`
- User identity source: JWT subject (`jwt.getSubject()`)
- Data isolation: repository queries scoped by user (e.g., `findByIdAndUserId`)
- Backend is stateless (no server session auth)

## 6) File-level talking points (if asked “open this file and explain”)

- `backend/src/main/java/com/auric/config/SecurityConfig.java`
  - defines public/protected routes, JWT verification, CORS.

- `backend/src/main/java/com/auric/controller/AiChatController.java`
  - chat/session/message APIs + SSE response stream endpoint.

- `backend/src/main/java/com/auric/service/OpenAiService.java`
  - builds prompt, handles history/images, streams OpenAI tokens, title generation.

- `flutter_app/lib/services/api_service.dart`
  - all HTTP calls + SSE parsing into typed events.

- `flutter_app/lib/screens/ai_chat_screen.dart`
  - UI state, sessions, optimistic messages, stream rendering, image/voice controls.

## 7) 40 viva questions with short answers

1) Q: What is your tech stack?
A: Flutter frontend, Spring Boot backend, SQLite database.

2) Q: Why split frontend and backend?
A: Better separation of UI and business/data logic; easier scaling and maintenance.

3) Q: Where is app entry point in backend?
A: `AuricApplication.java`.

4) Q: Where is app entry point in Flutter?
A: `flutter_app/lib/main.dart`.

5) Q: How does login work?
A: Google sign-in in Flutter, token verified in backend auth endpoint.

6) Q: How are protected APIs secured?
A: Spring Security OAuth2 resource server validates bearer JWT.

7) Q: Which APIs are public?
A: `/api/auth/**` and health endpoint.

8) Q: Which APIs are protected?
A: `/api/calc/**`, `/api/ai/**`.

9) Q: How is user identity obtained in backend?
A: From `@AuthenticationPrincipal Jwt`, using `jwt.getSubject()`.

10) Q: How do you prevent one user seeing another’s data?
A: User-scoped DB queries (`findByIdAndUserId`) + JWT-derived userId.

11) Q: What is stored in calculator history?
A: Equation, result, userId, timestamp.

12) Q: Where is calculator computation done?
A: In Flutter locally for instant response.

13) Q: Why still store calculator history on backend?
A: Account-based persistence and consistent retrieval.

14) Q: What is SSE in your app?
A: Server-Sent Events used to stream AI response token-by-token.

15) Q: Why use SSE for chat?
A: Real-time UX; user sees output progressively.

16) Q: Which stream events are used?
A: `meta`, `token`, `title`, `done`.

17) Q: Where is SSE parsing done in Flutter?
A: `ApiService.streamChatMessage()`.

18) Q: Where is SSE produced in backend?
A: `AiChatController.chat()`.

19) Q: What does `OpenAiService` do?
A: Builds messages, calls OpenAI, streams chunks, handles fallback/title generation.

20) Q: How are sessions handled?
A: Create/list/update/delete via `/api/ai/sessions` endpoints.

21) Q: How are chat messages stored?
A: In `chat_messages` table linked to `chat_sessions`.

22) Q: What’s the relation between session and message?
A: One session has many messages.

23) Q: How are images sent?
A: Base64 + mime type fields in AI request.

24) Q: How are images shown later?
A: Load image messages from `/api/ai/images`, decode and render in Flutter.

25) Q: What is optimistic UI in chat?
A: User message appears immediately before server finishes.

26) Q: Why have assistant placeholder message?
A: To append streamed tokens into one bubble smoothly.

27) Q: What if AI stream fails?
A: Flutter shows warning text/snackbar and ends loading safely.

28) Q: What if OpenAI key is missing?
A: Backend returns warning text in stream.

29) Q: How is theme handled?
A: `SettingsProvider` + `SharedPreferences`.

30) Q: How is auth token stored in Flutter?
A: `flutter_secure_storage`.

31) Q: What does `Dtos.java` contain?
A: Request/response DTO classes for auth/calc/chat/session APIs.

32) Q: Why use DTOs instead of entities in API?
A: Cleaner contract and safer decoupling from DB schema.

33) Q: Why use repository interfaces?
A: Simpler CRUD/query logic via Spring Data JPA.

34) Q: Why CORS config is needed?
A: To allow approved client origins to call backend APIs.

35) Q: Is backend stateful or stateless?
A: Stateless auth session policy.

36) Q: What DB migration helper exists?
A: `LegacyDataMigrationService` for blank legacy user IDs.

37) Q: Why title generation is async?
A: Start response quickly, update title later without blocking stream.

38) Q: What is response mode in chat?
A: `fast` or `detailed`, used to adjust prompt depth/token behavior.

39) Q: What are likely scale limits?
A: SQLite limits and base64 image storage growth.

40) Q: Future improvements?
A: Move to Postgres + object storage + caching/horizontal scaling.

## 8) Quick self-test checklist

If you can explain all below without notes, you are safe:

- I can explain login flow end-to-end.
- I can explain AI chat stream end-to-end.
- I can explain calculator local compute + backend persistence.
- I can explain how user data is isolated.
- I can explain key files in controller/service/api layers.

## 9) Emergency answering pattern (if stuck)

Use this template:

- "At UI level this starts in `<screen/service>`"
- "Then request goes to `<backend controller endpoint>`"
- "Business logic is handled in `<service>`"
- "Data is read/written via `<repository/entity>`"
- "Response returns to Flutter and updates `<state/UI>`"

This pattern works for almost every technical question in your project.
