#!/usr/bin/env python3
"""
bridge/voice_input.py

Simple local voice input for Oleg (Factorio bridge).
Records audio from the default microphone and sends recognized text as a JSON
UDP message to the existing bridge (127.0.0.1:38767) in the same format the
mod expects:

{ "type": "request", "player_index": <int>, "text": "<transcribed>", "lang": "ru" }

Behavior:
- Hotkey mode (default): press and hold the hotkey (default F9) to record; release to transcribe and send.
- If the `keyboard` module is not available or hotkey mode disabled, an interactive manual mode is provided
  where you press Enter to start and Enter to stop recording.

This script uses faster-whisper for transcription by default. On CPU it may be slow
for larger models; for best interactive performance use a small model or GPU.

Requirements (see bridge/requirements_voice.txt). You must install torch separately
following the official instructions for your platform if you plan to use faster-whisper.

Usage examples:
  python bridge/voice_input.py --player-index 1
  python bridge/voice_input.py --hotkey F9 --model-size small --device cpu

"""

import argparse
import os
import socket
import json
import tempfile
import time
import sys
import threading

import numpy as np
import sounddevice as sd
import soundfile as sf

# Try to import keyboard for global hotkey; if not available we'll fall back to manual mode
try:
    import keyboard
    HAVE_KEYBOARD = True
except Exception:
    HAVE_KEYBOARD = False

# Try to import faster_whisper; if not available we will error with instructions
try:
    from faster_whisper import WhisperModel
    HAVE_FASTER_WHISPER = True
except Exception:
    HAVE_FASTER_WHISPER = False


def send_udp_text(text, player_index, udp_ip="127.0.0.1", udp_port=38767):
    obj = {"type": "request", "player_index": player_index, "text": text, "lang": "ru"}
    data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.sendto(data, (udp_ip, udp_port))
        sock.close()
        print(f"Sent text to bridge ({udp_ip}:{udp_port}): {text}")
    except Exception as e:
        print(f"Failed to send to bridge at {udp_ip}:{udp_port}: {e}")


class Recorder:
    def __init__(self, samplerate=16000, channels=1, dtype='int16'):
        self.samplerate = samplerate
        self.channels = channels
        self.dtype = dtype
        self._stream = None
        self._frames = []
        self._lock = threading.Lock()
        self.recording = False

    def _callback(self, indata, frames, time_info, status):
        if status:
            # print(status, file=sys.stderr)
            pass
        with self._lock:
            if self.recording:
                # indata is bytes when using RawInputStream
                self._frames.append(indata.copy())

    def start(self):
        self._frames = []
        self.recording = True
        if self._stream is None:
            try:
                self._stream = sd.RawInputStream(samplerate=self.samplerate, blocksize=2048,
                                                dtype=self.dtype, channels=self.channels, callback=self._callback)
                self._stream.start()
            except Exception as e:
                print("Failed to open microphone input stream:", e)
                print("Check that a microphone is connected and that your system allows microphone access.")
                sys.exit(1)

    def stop(self):
        self.recording = False
        # do not stop the stream; keep it for subsequent recordings

    def get_wav(self):
        with self._lock:
            if not self._frames:
                return None
            data = b"".join(self._frames)
            # raw int16 bytes -> numpy int16
            try:
                audio = np.frombuffer(data, dtype=np.int16)
            except Exception:
                # try float32
                audio = np.frombuffer(data, dtype=np.float32)
                audio = (audio * 32768.0).astype(np.int16)
            # normalize to float32 in range [-1,1]
            audio = audio.astype(np.float32) / 32768.0
            # ensure mono shape (-1,)
            return audio


def transcribe_and_send(model, audio_array, samplerate, player_index, udp_ip, udp_port):
    # Save to a temporary WAV file and ask model to transcribe it (safer compatibility)
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
        tmpname = f.name
    try:
        sf.write(tmpname, audio_array, samplerate, subtype='PCM_16')
        # faster-whisper accepts filename
        try:
            segments, info = model.transcribe(tmpname, language='ru')
            text = " ".join([seg.text.strip() for seg in segments]).strip()
        except Exception as e:
            print("Transcription error:", e)
            text = ""
        if text:
            print(f"Transcribed: {text}")
            send_udp_text(text, player_index, udp_ip, udp_port)
        else:
            print("No speech recognized or transcription failed.")
    finally:
        try:
            os.remove(tmpname)
        except Exception:
            pass


def check_microphone():
    try:
        # This will raise if no default input device or unsupported settings
        sd.check_input_settings(device=None, channels=1, samplerate=16000)
        return True
    except Exception as e:
        print("Microphone check failed:", e)
        return False


def main():
    parser = argparse.ArgumentParser(description="Voice input for Oleg (Factorio bridge)")
    parser.add_argument("--player-index", type=int, default=1, help="player_index to send in JSON (default 1)")
    parser.add_argument("--udp-ip", default="127.0.0.1", help="bridge UDP IP (default 127.0.0.1)")
    parser.add_argument("--udp-port", type=int, default=38767, help="bridge UDP port (default 38767)")
    parser.add_argument("--model-size", default="small", help="faster-whisper model size (tiny, base, small, medium, large)")
    parser.add_argument("--device", default="cpu", help="device for model: cpu or cuda")
    parser.add_argument("--hotkey", default="f9", help="hotkey to record (default: F9)")
    parser.add_argument("--mode", choices=["hotkey", "manual"], default="hotkey", help="hotkey or manual enter-based mode")
    args = parser.parse_args()

    # microphone check
    if not check_microphone():
        print("No usable microphone detected. Exiting.")
        sys.exit(1)

    if not HAVE_FASTER_WHISPER:
        print("faster-whisper not installed. Install dependencies listed in bridge/requirements_voice.txt and ensure torch is installed.")
        sys.exit(1)

    print("Loading model (this may take a while)... model size:", args.model_size)
    try:
        model = WhisperModel(args.model_size, device=args.device)
    except Exception as e:
        print("Failed to load Whisper model:", e)
        sys.exit(1)

    rec = Recorder(samplerate=16000, channels=1, dtype='int16')

    print("Voice input ready. Mode:", args.mode)
    if args.mode == 'hotkey' and not HAVE_KEYBOARD:
        print("keyboard module not available — falling back to manual mode. Install 'keyboard' for hotkey support.")
        args.mode = 'manual'

    if args.mode == 'hotkey':
        hotkey = args.hotkey.lower()
        print(f"Hold {hotkey.upper()} to record, release to transcribe and send (player_index={args.player_index}).")

        # register handlers
        def on_press(e):
            # start recording
            if not rec.recording:
                print("Start recording...")
                rec.start()

        def on_release(e):
            # stop, get audio, transcribe
            if rec.recording:
                rec.stop()
                print("Stop recording, transcribing...")
                audio = rec.get_wav()
                if audio is None:
                    print("No audio captured.")
                    return
                transcribe_and_send(model, audio, rec.samplerate, args.player_index, args.udp_ip, args.udp_port)

        keyboard.on_press_key(hotkey, lambda e: on_press(e))
        keyboard.on_release_key(hotkey, lambda e: on_release(e))

        print("Press Ctrl+C to exit.")
        try:
            keyboard.wait()
        except KeyboardInterrupt:
            print("Exiting...")

    else:
        print("Manual mode: press Enter to start recording, Enter again to stop (Ctrl+C to quit).")
        try:
            while True:
                input("Press Enter to start recording...")
                rec.start()
                print("Recording... press Enter to stop")
                input()
                rec.stop()
                print("Stopped. Transcribing...")
                audio = rec.get_wav()
                if audio is None:
                    print("No audio captured.")
                    continue
                transcribe_and_send(model, audio, rec.samplerate, args.player_index, args.udp_ip, args.udp_port)
        except KeyboardInterrupt:
            print("Exiting...")


if __name__ == '__main__':
    main()
