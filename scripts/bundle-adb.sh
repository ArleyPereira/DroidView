#!/bin/sh
# Copia o adb do Android SDK (ou do Homebrew) para dentro do app como fallback.
# Em tempo de execução o DroidView prefere o adb do SDK; o embutido só é usado se não houver outro.
set -e
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/platform-tools"
for CANDIDATE in "${ANDROID_HOME}/platform-tools/adb" "${ANDROID_SDK_ROOT}/platform-tools/adb" "${HOME}/Library/Android/sdk/platform-tools/adb" "/opt/homebrew/bin/adb" "/usr/local/bin/adb"; do
  if [ -x "$CANDIDATE" ]; then
    SRC="$(cd "$(dirname "$CANDIDATE")" && pwd -P)/$(basename "$CANDIDATE")"
    mkdir -p "$DEST"
    if [ ! -f "$DEST/adb" ] || ! cmp -s "$SRC" "$DEST/adb"; then
      cp -f "$SRC" "$DEST/adb"
      codesign --force --sign - "$DEST/adb" >/dev/null 2>&1 || true
    fi
    echo "adb embutido a partir de $SRC"
    exit 0
  fi
done
echo "warning: nenhum adb encontrado para embutir; o app usará o adb do sistema em tempo de execução"
