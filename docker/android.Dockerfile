# syntax=docker/dockerfile:1
FROM eclipse-temurin:21-jdk-jammy AS toolchain
ARG FLUTTER_VERSION=3.47.4
ARG ANDROID_COMMAND_TOOLS=16111833
ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    PATH=/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:$PATH \
    PUB_CACHE=/root/.pub-cache
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils zip clang ninja-build pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter \
    && flutter config --no-analytics --android-sdk "$ANDROID_HOME" \
    && flutter precache --android
RUN mkdir -p "$ANDROID_HOME/cmdline-tools" \
    && curl --fail --location --retry 3 "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_COMMAND_TOOLS}_latest.zip" -o /tmp/android-tools.zip \
    && unzip -q /tmp/android-tools.zip -d "$ANDROID_HOME/cmdline-tools" \
    && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
    && rm /tmp/android-tools.zip
RUN yes | sdkmanager --licenses >/dev/null
RUN sdkmanager 'platform-tools' 'platforms;android-36' 'platforms;android-35' \
    'build-tools;36.0.0' 'ndk;28.2.13676358' 'cmake;3.22.1'

FROM toolchain AS checks
WORKDIR /workspace/src/shared
COPY src/shared/pubspec.yaml src/shared/pubspec.lock ./
RUN --mount=type=cache,target=/root/.pub-cache,sharing=locked flutter pub get --enforce-lockfile
COPY src/shared/lib/ ./lib/
COPY src/shared/resources/ ./resources/
COPY src/shared/analysis_options.yaml ./
COPY tests/shared/ /workspace/tests/shared/
COPY tests/backend_api/receipt_schema.json /workspace/tests/backend_api/receipt_schema.json
RUN --mount=type=cache,target=/root/.pub-cache,sharing=locked \
    dart format --output=none --set-exit-if-changed lib /workspace/tests/shared \
    && flutter analyze \
    && cd /workspace/tests/shared && flutter pub get --enforce-lockfile \
    && flutter analyze && flutter test domain database ui --reporter expanded

FROM checks AS build
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace/build/flutter
COPY src/shared/pubspec.yaml src/shared/pubspec.lock ./
RUN --mount=type=cache,target=/root/.pub-cache,sharing=locked flutter pub get --enforce-lockfile
COPY src/shared/lib/ ./lib/
COPY src/shared/resources/ ./resources/
COPY src/android/ ./android/
COPY docker/apply_mobile_defaults.py /apply_mobile_defaults.py
COPY docker/android_release.py /workspace/docker/android_release.py
COPY tests/docker/ /workspace/tests/docker/
RUN python3 -m unittest discover -s /workspace/tests/docker
ARG ANDROID_BUILD_NUMBER
ARG MOBILE_CONFIG_FINGERPRINT
ARG SIGNING_FINGERPRINT
RUN test -n "$SIGNING_FINGERPRINT" && mkdir -p /root/.android
# The persistent development signing key is supplied as a secret, never copied into a layer.
RUN --mount=type=cache,target=/root/.pub-cache,sharing=locked \
    --mount=type=cache,target=/root/.gradle,sharing=locked \
    --mount=type=secret,id=android_debug_key,target=/root/.android/debug.keystore,required=true \
    --mount=type=secret,id=mobile_defaults,target=/run/secrets/mobile_defaults,required=true \
    test -n "$MOBILE_CONFIG_FINGERPRINT" \
    && python3 /apply_mobile_defaults.py /run/secrets/mobile_defaults \
    && flutter pub get --enforce-lockfile \
    && flutter build apk --debug --no-pub --build-number="$ANDROID_BUILD_NUMBER" \
    && flutter build apk --release --split-per-abi --no-pub --build-number="$ANDROID_BUILD_NUMBER" \
    && mkdir /artifacts \
    && cp build/app/outputs/flutter-apk/app-debug.apk /artifacts/receipt-master-debug.apk \
    && cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk /artifacts/receipt-master-arm64.apk \
    && cp build/app/outputs/flutter-apk/app-x86_64-release.apk /artifacts/receipt-master-x86_64.apk \
    && python3 /workspace/docker/android_release.py describe --artifacts /artifacts --aapt "$ANDROID_HOME/build-tools/36.0.0/aapt2" --number "$ANDROID_BUILD_NUMBER" \
    && cd /artifacts \
    && for apk in *.apk; do \
         echo "$apk"; \
         "$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose --print-certs "$apk" || exit 1; \
       done > APK-VERIFICATION.txt \
    && sha256sum *.apk > SHA256SUMS

FROM scratch AS artifacts
COPY --from=build /artifacts/ /
