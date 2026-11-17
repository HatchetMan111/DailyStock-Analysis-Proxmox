#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Frontend-Patch: Validierungs-Fehlermeldungen (error.ts) übersetzbar machen.

Die Fehlermeldungen des Backends (z. B. "missing_api_key" ->
"请填写此渠道的 API Key。") sind in apps/dsa-web/src/api/error.ts hart auf
Chinesisch. Der Patch:

1. fügt eine kleine EN-Mapping-Tabelle für die bekannten Codes ein
2. extractConfigValidationIssues übersetzt bei EN-Locale (via localStorage,
   analog zum Sprach-Umschalter der App) ins Englische
3. die generischen Titel ("配置需要调整", "请修正以下配置后重试") ebenfalls

Idempotent: mehrfaches Ausführen ist unschädlich.
"""
import sys
from pathlib import Path

TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else "apps/dsa-web/src/api/error.ts")
MARKER = "// >>> DSA-I18N-PATCH-ERROR-TS (vom Proxmox-Installer eingespielt)"

PATCH = '''
// >>> DSA-I18N-PATCH-ERROR-TS (vom Proxmox-Installer eingespielt) >>>
// Übersetzt die bekannten Validierungs-Fehlermeldungen bei EN-Locale.
// Die App speichert die UI-Sprache in localStorage['dsa.uiLanguage'].
const ERROR_I18N_EN: Record<string, string> = {
  '请填写此渠道的 API Key。': 'Please fill in the API key for this channel.',
  '请填写账号可用的模型。': 'Please enter the models available for this account.',
  '请选择当前启用渠道中的模型，或清空无效的模型选项。':
    'Select a model from the enabled channels, or clear the invalid model options.',
  '配置需要调整': 'Configuration needs adjustment',
  '请修正以下配置后重试：': 'Please fix the following configuration and retry:',
  '请检查渠道的 API Key、模型和运行参数后重试。':
    'Check the channel API key, models and runtime parameters, then retry.',
  '请求未成功完成，请稍后重试。': 'The request could not be completed, please try again later.',
};

function getUiLanguageForError(): string {
  try {
    return window.localStorage.getItem('dsa.uiLanguage') === 'en' ? 'en' : 'zh';
  } catch {
    return 'zh';
  }
}

function translateErrorText(text: string): string {
  if (getUiLanguageForError() !== 'en') return text;
  return ERROR_I18N_EN[text] ?? text;
}
// <<< DSA-I18N-PATCH-ERROR-TS <<<
'''


def main():
    content = TARGET.read_text(encoding="utf-8")
    if MARKER in content:
        print(f"[i18n-patch] {TARGET} bereits gepatcht – skip")
        return

    # 1) Mapping + Helper NACH den Imports einfügen (vor der ersten Funktion).
    #    Anker: "function extractConfigValidationIssues" – wir fügen DAVOR ein.
    anchor = "function extractConfigValidationIssues(data: unknown): string | null {"
    assert anchor in content, "extractConfigValidationIssues nicht gefunden"
    content = content.replace(anchor, PATCH.lstrip("\n") + "\n" + anchor, 1)

    # 2) Die 4 bekannten Codes durch die Mapping-Tabelle leiten
    old = """    const key = pickString(issue.key);
    let message = pickString(issue.message);
    if (issue.code === 'missing_api_key') message = '请填写此渠道的 API Key。';
    if (issue.code === 'missing_models') message = '请填写账号可用的模型。';
    if (issue.code === 'unknown_model') message = '请选择当前启用渠道中的模型，或清空无效的模型选项。';
    return message ? [key, message].filter(Boolean).join('：') : null;"""
    new = """    const key = pickString(issue.key);
    let message = pickString(issue.message);
    if (issue.code === 'missing_api_key') message = '请填写此渠道的 API Key。';
    if (issue.code === 'missing_models') message = '请填写账号可用的模型。';
    if (issue.code === 'unknown_model') message = '请选择当前启用渠道中的模型，或清空无效的模型选项。';
    // DSA-I18N-PATCH-ERROR-TS: bekannte Meldungen bei EN-Locale übersetzen.
    // (message kann null sein – nur nicht-leere Strings übersetzen.)
    if (message) message = translateErrorText(message);
    return message ? [key, message].filter(Boolean).join('：') : null;"""
    assert old in content, "issue codes block nicht gefunden"
    content = content.replace(old, new, 1)

    # 3) Generische Titel/Meldungen übersetzen
    old = """    const message = issues
      ? `请修正以下配置后重试：\\n${issues}`
      : '请检查渠道的 API Key、模型和运行参数后重试。';
    return createParsedApiError({
      title: '配置需要调整',"""
    new = """    const message = issues
      ? `${translateErrorText('请修正以下配置后重试：')}\\n${issues}`
      : translateErrorText('请检查渠道的 API Key、模型和运行参数后重试。');
    return createParsedApiError({
      title: translateErrorText('配置需要调整'),"""
    assert old in content, "generic title block nicht gefunden"
    content = content.replace(old, new, 1)

    # 4) Fallback-Meldung
    old = """    ?? '请求未成功完成，请稍后重试。';"""
    new = """    ?? translateErrorText('请求未成功完成，请稍后重试。');"""
    assert old in content, "fallback message nicht gefunden"
    content = content.replace(old, new, 1)

    TARGET.write_text(content, encoding="utf-8")
    print(f"[i18n-patch] {TARGET} gepatcht")


if __name__ == "__main__":
    main()