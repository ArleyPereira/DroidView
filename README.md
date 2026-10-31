# DroidView

Espelhamento e controle de dispositivos Android, 100% nativo para macOS 26+ (Swift + SwiftUI/AppKit, VideoToolbox, AVFoundation, Network.framework).

## Como funciona

| Camada | Tecnologia |
|---|---|
| ADB | Cliente nativo do protocolo do servidor adb (porta 5037), compartilhado com o Android Studio. Usa o adb do SDK; o embutido é só fallback |
| Lado Android | `scrcpy-server` v5.0.1 (Apache 2.0) executado via `app_process`, sem instalar nada (mesma técnica do Vysor) |
| Vídeo | H.265 (fallback H.264) → decodificação por hardware via VideoToolbox → `AVSampleBufferDisplayLayer` |
| Áudio | Não é transmitido: o som continua tocando no próprio aparelho |
| Wi‑Fi | QR Code (`WIFI:T:ADB;…`), código de pareamento, IP:porta e `tcpip 5555`. Descoberta Bonjour de `_adb-tls-pairing` e `_adb-tls-connect` |
| Estabilidade | Reconexão automática da sessão na mesma janela (troca de USB↔Wi‑Fi, mudança de IP/porta) |

## Recursos

- Mouse vira toque, botão direito/Esc volta, scroll, pinça do trackpad vira zoom com dois dedos, teclado completo e sincronia de clipboard (⌘C/⌘V)
- Screenshot sem perdas (`screencap`) com prévia: copiar, salvar ou cancelar (⌘S)
- Gravação sem re-encode (.mp4 H.265/H.264) (⌘⇧G)
- Botões power, volume, voltar, início e recentes, rotação, apagar a tela do aparelho, tamanho 1:1, sempre no topo
- Opções do desenvolvedor com um clique: mostrar toques, limites de layout, overdraw, barras HWUI, tema escuro, animações, escala da fonte
- App em primeiro plano: forçar parada, reiniciar, limpar dados; deep links; arrastar APK para instalar e arquivo para enviar
- Logcat ao vivo com filtro por nível, pacote e busca

## Logs

Cada execução registra adb, descoberta mDNS, conexões e espelhamento em
`~/Library/Logs/DroidView/droidview.log` (rotação em 5 MB, mantém `.1` e `.2`) e no
Console.app (subsystem `com.arley.DroidView`). Menu **Ajuda › Mostrar logs do DroidView**.
O log do próprio servidor adb fica em `$TMPDIR/adb.<uid>.log`.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme DroidView -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/DroidView.app
```

Para atualizar o scrcpy-server, troque `DroidView/Resources/scrcpy-server` e `ScrcpyServer.version` (as versões precisam bater).
