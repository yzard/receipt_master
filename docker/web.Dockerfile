# syntax=docker/dockerfile:1
FROM node:22.20.0-bookworm-slim AS checks
WORKDIR /workspace/src/web
COPY src/web/package.json src/web/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts
COPY src/web/ ./
COPY tests/web/ /workspace/tests/web/
COPY src/backend_api/resources/localizations.json /workspace/src/backend_api/resources/localizations.json
RUN npm audit --audit-level=moderate && npm test && npm run build
FROM scratch AS artifacts
COPY --from=checks /workspace/build/web/ /
