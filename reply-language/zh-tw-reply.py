#!/usr/bin/env python3
"""Owner's standing rule: every reply to the owner is in Traditional Chinese (正體中文).

  zh-tw-reply.py remind   UserPromptSubmit: put the rule in front of the model on every turn.
  zh-tw-reply.py stop     Stop: if any text the model showed the owner this turn is mostly English, block once and ask for a rewrite.

Code blocks, inline code, URLs and paths are ignored when measuring, so commit hashes, file names and
commands inside a Chinese reply never trigger it. Sub-agents are not affected (they end with SubagentStop).
"""
import json
import re
import sys

RULE = (
    "擁有者的永久規則:給擁有者看的每一句話一律用正體中文(白話、少術語),"
    "包括工具動作之間的短句與最後的回覆。程式碼、指令、檔名、commit 訊息、給其他 AI 的訊息可用英文。"
)


def remind():
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": RULE}}, ensure_ascii=False))


def turn_texts(transcript_path):
    texts = []
    with open(transcript_path, encoding="utf-8") as f:
        for line in f:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("isSidechain"):
                continue
            message = entry.get("message") or {}
            role = message.get("role") or entry.get("type")
            content = message.get("content")
            if role == "user":
                is_tool_result = isinstance(content, list) and any(
                    isinstance(c, dict) and c.get("type") == "tool_result" for c in content)
                if not is_tool_result:
                    texts = []  # a new owner turn starts
                continue
            if role != "assistant" or not isinstance(content, list):
                continue
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    texts.append(c.get("text", ""))
    return texts


def prose_is_mostly_english(text):
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"`[^`]*`", " ", text)
    # [/\\]: a Windows path (D:\WorkSpace\...) is a path too - with "/" alone a Chinese reply
    # citing two of them was blocked as "mostly English" (W1, measured on Windows 2026-11-02)
    text = re.sub(r"https?://\S+|\S*[/\\]\S+", " ", text)
    cjk = len(re.findall(r"[㐀-鿿豈-﫿]", text))
    latin = len(re.findall(r"[A-Za-z]", text))
    if latin < 60:
        return False
    # One CJK character carries about as much as three Latin letters.
    return cjk * 3 < latin


def stop():
    data = json.load(sys.stdin)
    if data.get("stop_hook_active"):
        return  # already asked once this turn: never loop
    path = data.get("transcript_path")
    if not path:
        return
    if any(prose_is_mostly_english(t) for t in turn_texts(path)):
        print(json.dumps({
            "decision": "block",
            "reason": "你這一輪給擁有者看的文字裡有一段主要是英文。" + RULE + " 請用正體中文把這一輪該告訴擁有者的內容完整重寫一次再結束。",
        }, ensure_ascii=False))


if __name__ == "__main__":
    {"remind": remind, "stop": stop}[sys.argv[1]]()
