#!/usr/bin/env python3
"""Verify structured outputs (JSON-schema enforcement) and tool calling.

The server MUST be started with --no-async-scheduling and, for structured
outputs, additional_config.neuron_config.enable_structured_outputs=true.

Usage: python3 structured_outputs.py [--base URL] [--model NAME]
Reference: docs/guides/features-guide.md
"""
import argparse
import json
import requests


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--model", default="meta-llama/Llama-3.1-8B-Instruct")
    args = ap.parse_args()
    B = f"{args.base}/v1/chat/completions"

    schema = {"type": "object",
              "properties": {"city": {"type": "string"}, "population": {"type": "integer"}},
              "required": ["city", "population"], "additionalProperties": False}
    r = requests.post(B, json={"model": args.model,
        "messages": [{"role": "user", "content": "Give the capital of Japan and its population as JSON."}],
        "max_tokens": 80, "temperature": 0,
        "response_format": {"type": "json_schema", "json_schema": {"name": "cityinfo", "schema": schema}}},
        timeout=120)
    so_ok = False
    if r.status_code == 200:
        content = r.json()["choices"][0]["message"]["content"]
        try:
            parsed = json.loads(content)
            so_ok = isinstance(parsed.get("city"), str) and isinstance(parsed.get("population"), int)
        except Exception:
            pass
        print(f"[structured-outputs] {content!r} -> {'PASS' if so_ok else 'FAIL'}")
    else:
        print(f"[structured-outputs] HTTP {r.status_code}: {r.text[:200]}")

    tools = [{"type": "function", "function": {"name": "get_weather",
              "description": "Get current weather for a city",
              "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
    r2 = requests.post(B, json={"model": args.model,
        "messages": [{"role": "user", "content": "What is the weather in Melbourne? Use the tool."}],
        "max_tokens": 100, "temperature": 0, "tools": tools, "tool_choice": "auto"}, timeout=120)
    tc_ok = False
    if r2.status_code == 200:
        tcs = r2.json()["choices"][0]["message"].get("tool_calls")
        if tcs:
            fn = tcs[0]["function"]
            tc_ok = fn["name"] == "get_weather" and "city" in json.loads(fn["arguments"])
            print(f"[tool-calling] {fn['name']}({fn['arguments']}) -> {'PASS' if tc_ok else 'FAIL'}")
        else:
            print("[tool-calling] no tool_calls -> FAIL")
    else:
        print(f"[tool-calling] HTTP {r2.status_code}: {r2.text[:200]}")

    print("RESULT:", "PASS" if (so_ok and tc_ok) else "PARTIAL" if (so_ok or tc_ok) else "FAIL")


if __name__ == "__main__":
    main()
