# Auric

AI-powered calculator and study assistant built with Flutter (mobile app) and Spring Boot (backend API).

![Flutter](https://img.shields.io/badge/Flutter-3.22+-02569B?logo=flutter&logoColor=white)
![Spring Boot](https://img.shields.io/badge/Spring%20Boot-3.3.4-6DB33F?logo=springboot&logoColor=white)
![Java](https://img.shields.io/badge/Java-17-007396?logo=openjdk&logoColor=white)
![SQLite](https://img.shields.io/badge/Database-SQLite-003B57?logo=sqlite&logoColor=white)

## Highlights

- Live AI chat with token streaming (SSE)
- Chat sessions (create, search, rename, delete)
- Image-assisted AI chat and voice input
- Scientific calculator with expression parser and history
- Google Sign-In authentication with protected backend APIs
- Per-user token usage window and usage insights

## Tech Stack

- Frontend: Flutter, Provider, Dio/HTTP, flutter_animate
- Backend: Spring Boot, Spring Security, Spring Data JPA, WebFlux
- Auth: Google ID token verification + OAuth2 resource server
- Database: SQLite
- AI: OpenAI Chat Completions (text + vision)

## Project Structure

```text
Auric/
  backend/       # Spring Boot API (auth, calc, ai streaming, persistence)
  flutter_app/   # Flutter app (UI, chat, calculator, settings)
```

## Key Features

### AI Chat
- Streaming AI responses in real time
- Fast / detailed response modes
- Session memory with history controls
- Image upload and multimodal analysis
- Voice-to-text input support

### Calculator
- Standard + scientific functions
- Live expression evaluation
- History save/load/delete per user
- Cleaner error handling for invalid expressions

## Security Notes

- Secrets are loaded from local `.env` files and are git-ignored.
- CORS is allowlist-based using `CORS_ALLOWED_ORIGINS`.
- Unknown backend routes are denied by default.
- Do not commit real keys; use `.env.example` templates.

## Local Setup

### 1) Backend

```bash
cd backend
copy .env.example .env
```

Set values in `backend/.env`, especially:
- `OPENAI_API_KEY`
- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_IDS`
- `CORS_ALLOWED_ORIGINS`

Run backend:

```bash
mvn spring-boot:run
```

Default API base URL: `http://127.0.0.1:8080`

### 2) Flutter App

```bash
cd flutter_app
copy .env.example .env
flutter pub get
flutter run
```

Set values in `flutter_app/.env`, especially:
- `API_BASE_URL`
- `GOOGLE_WEB_CLIENT_ID`
- `GOOGLE_ANDROID_CLIENT_ID`

## API Snapshot

- `POST /api/auth/google` - Google sign-in verification
- `GET/POST/DELETE /api/calc/*` - calculator history endpoints
- `POST /api/ai/chat` - streaming chat endpoint
- `GET /api/ai/sessions` - chat sessions
- `GET /api/ai/usage` - token usage info

## Quality Checks

- Backend: `mvn -q -DskipTests compile`
- Flutter: `flutter analyze`

## Roadmap

- Add unit/integration tests for chat and auth flows
- Add CI workflow for backend compile + flutter analyze
- Add demo screenshots and short usage GIFs

---

If you are reviewing this repo, start with `PROJECT_QUICK_GUIDE.md` for a fast architecture overview.
