#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Frontend-Patch: Accept-Language-Header bei jedem API-Call mitschicken.

Die App speichert die UI-Sprache in localStorage['dsa.uiLanguage'] (zh/en).
Der apiClient schickt bisher keinen Sprach-Header -> das Backend liefert die
Setup-Status-Texte immer auf Chinesisch. Der Patch fügt einen Request-
Interceptor ein, der den aktuellen Sprachstand als Accept-Language mitschickt.

Idempotent: mehrfaches Ausführen ist unschädlich.
"""
import sys
from pathlib import Path

TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else "apps/dsa-web/src/api/index.ts")
MARKER = "// >>> DSA-I18N-PATCH (vom Proxmox-Installer eingespielt)"

PATCH = """
// >>> DSA-I18N-PATCH (vom Proxmox-Installer eingespielt) >>>
// UI-Sprache (localStorage 'dsa.uiLanguage') als Accept-Language mitschicken,
// damit das Backend die Setup-Status-Texte in der richtigen Sprache liefert.
apiClient.interceptors.request.use((config) => {
  try {
    const stored = window.localStorage.getItem('dsa.uiLanguage');
    const lang = stored === 'en' ? 'en' : 'zh';
    // AxiosRequestHeaders ist immutable-ähnlich – set() statt Index-Zugriff.
    if (config.headers && typeof config.headers.set === 'function') {
      config.headers.set('Accept-Language', lang);
    } else if (config.headers) {
      (config.headers as Record<string, string>)['Accept-Language'] = lang;
    }
  } catch {
    /* localStorage nicht verfügbar – Default (zh) gilt */
  }
  return config;
});
// <<< DSA-I18N-PATCH <<<
"""


def main():
    content = TARGET.read_text(encoding="utf-8")
    if MARKER in content:
        print(f"[i18n-patch] {TARGET} bereits gepatcht – skip")
        return

    # Nach dem apiClient-Block einfügen (vor dem response-Interceptor)
    anchor = "apiClient.interceptors.response.use("
    assert anchor in content, "response-Interceptor nicht gefunden"
    content = content.replace(anchor, PATCH.lstrip("\n") + "\n" + anchor, 1)

    TARGET.write_text(content, encoding="utf-8")
    print(f"[i18n-patch] {TARGET} gepatcht")


if __name__ == "__main__":
    main()