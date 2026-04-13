# Contributing

Thanks for contributing to Auric.

## Development Rules

- Never commit secrets (`.env`, API keys, private credentials).
- Keep commits small and focused.
- Follow existing code style and naming patterns.
- Prefer clear, user-facing error handling.

## Commit Style

Use conventional-style prefixes when possible:

- `feat:` new user-visible functionality
- `fix:` bug fixes
- `refactor:` internal improvements without behavior changes
- `docs:` documentation-only changes
- `chore:` tooling/config maintenance

Examples:

- `feat(chat): improve sidebar animations and transitions`
- `fix(security): harden cors and deny unknown routes`

## Verification Before PR

Backend:

```bash
cd backend
mvn -q -DskipTests compile
```

Flutter:

```bash
cd flutter_app
flutter analyze
```

## Pull Request Checklist

- [ ] No secrets added
- [ ] Build/analyze checks pass
- [ ] Changes are scoped and explained clearly
- [ ] Screenshots attached for UI changes
