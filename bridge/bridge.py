#!/usr/bin/env python3
# Bridge: принимает JSON по UDP от Factorio, кладёт в модель, отправляет JSON-ответ обратно.
# - слушает 127.0.0.1:38767 (от Factorio)
# - отправляет ответы на 127.0.0.1:38766 (Factorio)
# API endpoint и модель заданы требованиями.
# API_KEY НЕ хардкодится; читается из OPENAI_API_KEY или вводится при запуске.

import socket
import os
import sys
import json
import requests
import traceback

BRIDGE_BIND_IP = "127.0.0.1"
BRIDGE_BIND_PORT = 38767
FACTORIO_IP = "127.0.0.1"
FACTORIO_PORT = 38766

API_URL = "https://shprotoness-ai.jq9gfk.workers.dev/v1/chat/completions"
MODEL_NAME = "gpt-5.6-terra"

SYSTEM_PROMPT = (
    "Ты Олег — ИИ-компаньон внутри игры Factorio.\n"
    "Ты находишься вместе с игроком на планете, где строится фабрика.\n"
    "Твоя задача помогать игроку развивать базу, автоматизацию и выживание.\n\n"
    "Всегда воспринимай разговор как происходящий внутри Factorio.\n"
    "Если игрок говорит про завод, производство, ресурсы или строительство — речь идёт о фабрике в игре.\n\n"
    "Отвечай как инженер-напарник:\n"
    "- помогай строить производственные цепочки;\n"
    "- советуй по оптимизации;\n"
    "- объясняй рецепты;\n"
    "- помогай с логистикой;\n"
    "- предлагай следующие шаги развития.\n\n"
    "Не говори:\n"
    "- что ты не можешь зайти в игру;\n"
    "- что ты не можешь играть;\n"
    "- что ты можешь только сделать мод.\n\n"
    "Ты уже находишься внутри Factorio и помогаешь игроку."
)


def get_api_key():
    key = os.environ.get("OPENAI_API_KEY")
    if key and key.strip():
        return key.strip()
    try:
        return input("Enter API key (will not be saved): ").strip()
    except Exception:
        return None


def call_model(api_key, user_text):
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }
    payload = {
        "model": MODEL_NAME,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_text}
        ],
        "max_tokens": 800
    }
    resp = requests.post(API_URL, headers=headers, json=payload, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    # Try to extract standard OpenAI-like response
    try:
        content = data["choices"][0]["message"]["content"]
        return content
    except Exception:
        return json.dumps(data, ensure_ascii=False)


def main():
    api_key = get_api_key()
    if not api_key:
        print("API key not provided.")
        sys.exit(1)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((BRIDGE_BIND_IP, BRIDGE_BIND_PORT))
    print(f"Bridge listening on {BRIDGE_BIND_IP}:{BRIDGE_BIND_PORT}, sending replies to {FACTORIO_IP}:{FACTORIO_PORT}")

    while True:
        try:
            data, addr = sock.recvfrom(65536)
            try:
                text = data.decode("utf-8")
            except Exception:
                text = data.decode("utf-8", errors="replace")
            # parse JSON
            try:
                obj = json.loads(text)
            except Exception as e:
                print("Invalid JSON from Factorio:", text)
                continue

            if obj.get("type") != "request":
                print("Ignoring non-request object:", obj)
                continue

            player_index = obj.get("player_index")
            message = obj.get("text", "")

            print(f"Request from player {player_index}: {message!r}")

            try:
                reply_text = call_model(api_key, message)
            except Exception as e:
                print("Error calling model:", e)
                traceback.print_exc()
                reply_text = "[Олег-bridge] Ошибка при обращении к модели: " + str(e)

            resp_obj = {
                "type": "response",
                "player_index": player_index,
                "text": reply_text
            }
            out = json.dumps(resp_obj, ensure_ascii=False)
            sock.sendto(out.encode("utf-8"), (FACTORIO_IP, FACTORIO_PORT))
            print(f"Sent response to Factorio for player {player_index}")
        except KeyboardInterrupt:
            print("Exiting on user request")
            break
        except Exception as e:
            print("Unexpected loop error:", e)
            traceback.print_exc()


if __name__ == "__main__":
    main()
