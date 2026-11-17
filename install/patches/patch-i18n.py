#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Patch für daily_stock_analysis: Setup-Status-Checks mehrsprachig machen.

Das Backend (src/services/system_config_service.py) liefert die Setup-Status-
Karten (LLM 主渠道, 自选股, …) bisher IMMER auf Chinesisch. Der Patch:

1. fügt eine Übersetzungs-Tabelle (zh -> en) für alle Setup-Status-Texte ein
2. erweitert get_setup_status() um einen language-Parameter (default 'zh')
3. lokalisiert die Checks nach dem Bauen (Titel/message/next_step)
4. der Endpoint liest Accept-Language aus dem Request (patch #2)

Idempotent: mehrfaches Ausführen ist unschädlich (Marker-basierter Check).
"""
import re
import sys
from pathlib import Path

TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else "src/services/system_config_service.py")
ENDPOINT = Path(sys.argv[2] if len(sys.argv) > 2 else "api/v1/endpoints/system_config.py")
MARKER = "# >>> DSA-I18N-PATCH (vom Proxmox-Installer eingespielt)"

zh_to_en = {
    # Titel
    "LLM 主渠道": "LLM primary channel",
    "Agent 渠道": "Agent channel",
    "自选股": "Watchlist",
    "通知渠道": "Notification channels",
    "数据库 / 本地存储": "Database / local storage",
    # message / next_step
    "尚未检测到主模型配置": "No primary model configured yet",
    "主模型未出现在当前启用渠道模型列表中": "Primary model not found in the enabled channel model list",
    "主模型缺少可用渠道或匹配的 API Key": "Primary model has no usable channel or matching API key",
    "请配置 LITELLM_MODEL、LLM_CHANNELS、LITELLM_CONFIG 或 legacy provider API Key。":
        "Configure LITELLM_MODEL, LLM_CHANNELS, LITELLM_CONFIG or a legacy provider API key.",
    "已选择 codex_cli，但 DSA 后端进程当前 PATH 中找不到 codex 可执行文件。":
        "codex_cli selected, but the codex executable was not found in the backend PATH.",
    "请确认 Codex CLI 已安装到后端 PATH 可见目录；桌面端请完全退出并重开。":
        "Make sure Codex CLI is installed in a directory visible to the backend PATH.",
    "打开 Codex CLI 交互窗口不会改变已运行后端的 PATH；若找到后仍失败，再检查 Codex CLI 登录态，":
        "Opening an interactive Codex CLI window does not change the running backend's PATH.",
    "或将 GENERATION_BACKEND 设回 litellm。": "or set GENERATION_BACKEND back to litellm.",
    "请先安装并登录对应 CLI，或将 GENERATION_BACKEND 设回 litellm。":
        "Install and log in to the CLI first, or set GENERATION_BACKEND back to litellm.",
    "显式主模型": "explicit primary model",
    "LLM 渠道": "LLM channel",
    "legacy provider": "legacy provider",
    "已检测到 {source_label}: {model}": "Detected {source_label}: {model}",
    "Agent 工具调用暂不支持 {agent_backend} text-only backend。":
        "Agent tool calls are not supported with the {agent_backend} text-only backend.",
    "请将 AGENT_GENERATION_BACKEND 设为 auto 或 litellm，并配置 LiteLLM 工具调用渠道。":
        "Set AGENT_GENERATION_BACKEND to auto or litellm and configure a LiteLLM tool-call channel.",
    "普通分析使用 Codex CLI；但当前 LiteLLM Agent 路径继承的是 Hermes-only 模型，":
        "Normal analysis uses Codex CLI, but the LiteLLM agent path inherits a Hermes-only model.",
    "Hermes Phase 3 不支持 Agent 工具调用。": "Hermes Phase 3 does not support agent tool calls.",
    "如需使用 Ask-Stock Agent，请配置非 Hermes 的 AGENT_LITELLM_MODEL，":
        "To use the Ask-Stock agent, configure a non-Hermes AGENT_LITELLM_MODEL,",
    "或配置包含非 Hermes deployment 的 mixed Agent route。":
        "or a mixed agent route with a non-Hermes deployment.",
    "普通分析使用 Codex CLI；Agent 工具调用仍使用 LiteLLM 主模型: {model}":
        "Normal analysis uses Codex CLI; agent tool calls use the LiteLLM primary model: {model}",
    "AGENT_GENERATION_BACKEND 已选择 litellm，但未检测到可用 LiteLLM 模型配置。":
        "AGENT_GENERATION_BACKEND is set to litellm, but no usable LiteLLM model was found.",
    "如需使用 Ask-Stock Agent，请配置 AGENT_LITELLM_MODEL、LITELLM_MODEL、LLM_CHANNELS 或 LITELLM_CONFIG。":
        "To use the Ask-Stock agent, configure AGENT_LITELLM_MODEL, LITELLM_MODEL, LLM_CHANNELS or LITELLM_CONFIG.",
    "Agent 工具调用需要 LiteLLM 模型配置；local CLI 主生成方式不会被自动继承。":
        "Agent tool calls need a LiteLLM model config; the local CLI primary method is not inherited.",
    "如需使用 Ask-Stock Agent，请配置 LiteLLM 模型，或将 AGENT_GENERATION_BACKEND 固定为 litellm 后补齐模型配置。":
        "To use the Ask-Stock agent, configure a LiteLLM model, or pin AGENT_GENERATION_BACKEND to litellm and add the model config.",
    "Hermes Phase 3 不支持 Agent 工具调用，且当前继承的主模型没有非 Hermes deployment。":
        "Hermes Phase 3 does not support agent tool calls, and the inherited primary model has no non-Hermes deployment.",
    "请选择非 Hermes Agent 模型，或配置包含非 Hermes deployment 的 mixed Agent route。":
        "Select a non-Hermes agent model, or configure a mixed agent route with a non-Hermes deployment.",
    "未单独配置 Agent 主模型，将继承 LLM 主渠道。":
        "No separate agent primary model configured; it will inherit the LLM primary channel.",
    "Agent 未配置独立模型，且 LLM 主渠道尚不可用。":
        "The agent has no separate model, and the LLM primary channel is unavailable.",
    "请先补齐 LLM 主渠道配置。": "Configure the LLM primary channel first.",
    "Agent 主模型 {agent_model} 只有 Hermes deployment，Phase 3 不支持 Agent 工具调用。":
        "Agent primary model {agent_model} has only a Hermes deployment; Phase 3 does not support agent tool calls.",
    "请选择非 Hermes Agent 模型，或配置 mixed route 中的非 Hermes deployment。":
        "Select a non-Hermes agent model, or configure a non-Hermes deployment in the mixed route.",
    "已配置 Agent 主模型: {agent_model}": "Agent primary model configured: {agent_model}",
    "Agent 主模型 {agent_model} 缺少可用渠道或匹配的 API Key。":
        "Agent primary model {agent_model} has no usable channel or matching API key.",
    "请调整 AGENT_LITELLM_MODEL 或补齐对应渠道配置。":
        "Adjust AGENT_LITELLM_MODEL or complete the corresponding channel configuration.",
    "已配置 {count} 只股票。": "{count} stock(s) configured.",
    "当前 STOCK_LIST 为空。": "STOCK_LIST is currently empty.",
    "请至少添加 1 只股票用于首次试跑。": "Add at least 1 stock for the first test run.",
    "已检测到至少一个通知渠道配置。": "At least one notification channel is configured.",
    "通知为可选项，未配置也不影响首次跑通。": "Notifications are optional and do not block the first run.",
    "需要推送时可稍后配置飞书、钉钉、Telegram、邮件或其他通知渠道。":
        "Configure Feishu, DingTalk, Telegram, email or another channel later when you need push notifications.",
    "数据库路径父目录不可用: {parent}": "Database parent directory unavailable: {parent}",
    "请检查 DATABASE_PATH 或上级目录权限。": "Check DATABASE_PATH or the parent directory permissions.",
    "数据库路径可用: {db_path}": "Database path is writable: {db_path}",
    "数据库上级目录可创建: {parent}": "Database parent directory will be created: {parent}",
    "数据库路径上级目录不可写: {probe}": "Database parent directory not writable: {probe}",
    "请调整 DATABASE_PATH 或目录权限。": "Adjust DATABASE_PATH or the directory permissions.",
}

PATCH_CODE = '''

# >>> DSA-I18N-PATCH (vom Proxmox-Installer eingespielt) >>>
# Lokalisierung der Setup-Status-Checks. Das Backend liefert die Karten
# bisher nur auf Chinesisch; mit language='en' werden die bekannten Texte
# übersetzt. Unbekannte Texte bleiben unverändert (Fallback = Chinesisch).
_SETUP_CHECK_I18N_EN = ''' + repr(zh_to_en) + '''


def _localize_setup_checks(checks, language):
    """Übersetzt die Setup-Checks (title/message/next_step) bei Bedarf."""
    if not language or not str(language).lower().startswith("en"):
        return checks
    table = _SETUP_CHECK_I18N_EN

    def _translate(text):
        if not isinstance(text, str) or not text:
            return text
        if text in table:
            return table[text]
        # Format-Strings mit Platzhaltern (z. B. "{count}") behandeln
        for zh_fmt, en_fmt in table.items():
            if zh_fmt in text and "{" in zh_fmt:
                return text.replace(zh_fmt, en_fmt)
        return text

    localized = []
    for check in checks:
        item = dict(check)
        item["title"] = _translate(item.get("title"))
        item["message"] = _translate(item.get("message"))
        item["next_step"] = _translate(item.get("next_step"))
        localized.append(item)
    return localized
# <<< DSA-I18N-PATCH <<<
'''


def patch_service():
    content = TARGET.read_text(encoding="utf-8")
    if MARKER in content:
        print(f"[i18n-patch] {TARGET} bereits gepatcht – skip")
        return

    # 1) Übersetzungs-Code VOR der Klasse einfügen (nach den Imports)
    #    Anker: die erste Klassendefinition "class SystemConfigService" o. Ä.
    #    Falls nicht gefunden: vor der ersten "def " auf Modul-Ebene.
    anchor = re.search(r"^class \w+Service", content, re.MULTILINE)
    if anchor:
        insert_at = anchor.start()
    else:
        m = re.search(r"^def \w+", content, re.MULTILINE)
        insert_at = m.start() if m else 0
    content = content[:insert_at] + PATCH_CODE.lstrip("\n") + "\n" + content[insert_at:]

    # 2) get_setup_status: language-Parameter + Localize-Aufruf
    old_sig = "def get_setup_status(self) -> Dict[str, Any]:"
    new_sig = "def get_setup_status(self, language: str = 'zh') -> Dict[str, Any]:"
    assert old_sig in content, "get_setup_status Signatur nicht gefunden"
    content = content.replace(old_sig, new_sig, 1)

    old_build = """        checks = [
            llm_check,
            agent_check,
            self._build_setup_stock_list_check(effective_map),
            self._build_setup_notification_check(effective_map),
            self._build_setup_storage_check(effective_map),
        ]"""
    new_build = """        checks = [
            llm_check,
            agent_check,
            self._build_setup_stock_list_check(effective_map),
            self._build_setup_notification_check(effective_map),
            self._build_setup_storage_check(effective_map),
        ]
        checks = _localize_setup_checks(checks, language)"""
    assert old_build in content, "checks-Block nicht gefunden"
    content = content.replace(old_build, new_build, 1)

    TARGET.write_text(content, encoding="utf-8")
    print(f"[i18n-patch] {TARGET} gepatcht")


def patch_endpoint():
    content = ENDPOINT.read_text(encoding="utf-8")
    if MARKER in content or "service.get_setup_status(language=" in content:
        print(f"[i18n-patch] {ENDPOINT} bereits gepatcht – skip")
        return

    # Request-Objekt in die Signatur + Accept-Language an den Service durchreichen
    old = """def get_setup_status(
    service: SystemConfigService = Depends(get_system_config_service),
) -> SetupStatusResponse:
    \"\"\"Return first-run setup status without writing config or reloading runtime state.\"\"\"
    try:
        payload = service.get_setup_status()"""
    new = """def get_setup_status(
    request: Request,
    service: SystemConfigService = Depends(get_system_config_service),
) -> SetupStatusResponse:
    \"\"\"Return first-run setup status without writing config or reloading runtime state.\"\"\"
    try:
        # DSA-I18N-PATCH: Sprache aus Accept-Language ableiten (en -> englische
        # Setup-Status-Texte, sonst chinesisch wie bisher).
        _accept_language = request.headers.get("Accept-Language", "zh")
        _language = "en" if _accept_language.lower().startswith("en") else "zh"
        payload = service.get_setup_status(language=_language)"""
    assert old in content, "endpoint get_setup_status nicht gefunden"
    content = content.replace(old, new, 1)

    ENDPOINT.write_text(content, encoding="utf-8")
    print(f"[i18n-patch] {ENDPOINT} gepatcht")


if __name__ == "__main__":
    patch_service()
    patch_endpoint()
    print("[i18n-patch] fertig")