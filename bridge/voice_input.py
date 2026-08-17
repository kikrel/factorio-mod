#!/usr/bin/env python3
"""
bridge/voice_input.py

Voice input for Oleg (Factorio bridge) with VAD, silence trimming and basic audio checks.

Behavior:
- Hotkey mode (default): press and hold the hotkey (default F9) to record; release to transcribe and send.
- Manual mode (Enter) as fallback.

Features:
- VAD trimming using webrtcvad to remove leading/trailing silence before transcription (optional)
- Fallback energy-based trimming when webrtcvad is not installed
- Filter too-short or too-quiet recordings
- Configurable energy threshold and minimum duration
- faster-whisper transcription with tuned beam_size for speed
- Optional assistant mode: voice_input listens for bridge replies on a local UDP port and prints them
- Post-transcription blacklist to avoid common false positives

Output: sends JSON UDP to bridge (default 127.0.0.1:38767) in the same format the mod expects.
"""

import argparse
import os
import socket
import json
import tempfile
import time
import sys
import threading
import math
import datetime

import numpy as np
import sounddevice as sd
import soundfile as sf

# VAD (optional)
try:
    import webrtcvad
    HAVE_VAD = True
except Exception:
    HAVE_VAD = False

# keyboard hotkey
try:
    import keyboard
    HAVE_KEYBOARD = True
except Exception:
    HAVE_KEYBOARD = False

# faster-whisper
try:
    from faster_whisper import WhisperModel
    HAVE_FASTER_WHISPER = True
except Exception:
    HAVE_FASTER_WHISPER = False


# simple blacklist of common mis-recognitions to ignore
BLACKLIST = [
    "спокойная музыка",
    "редактор субтитров",
]


def send_udp_text(text, player_index, udp_ip="127.0.0.1", udp_port=38767, reply_back_ip=None, reply_back_port=None):
    obj = {"type": "request", "player_index": player_index, "text": text, "lang": "ru"}
    # optionally request bridge to send a copy back to us (assistant mode)
    if reply_back_ip and reply_back_port:
        obj["reply_back_ip"] = reply_back_ip
        obj["reply_back_port"] = int(reply_back_port)
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
        # store frames as numpy 1-D float32 arrays (mono)
        self._frames = []
        self._lock = threading.Lock()
        self.recording = False

    def _callback(self, indata, frames, time_info, status):
        # Convert to numpy float32 mono array and append.
        if status:
            pass
        with self._lock:
            if not self.recording:
                return
            try:
                # If indata is a memoryview (cffi buffer), convert to bytes then to numpy
                if isinstance(indata, memoryview):
                    b = indata.tobytes()
                    arr = np.frombuffer(b, dtype=np.int16).astype(np.float32) / 32768.0
                elif isinstance(indata, (bytes, bytearray)):
                    b = bytes(indata)
                    arr = np.frombuffer(b, dtype=np.int16).astype(np.float32) / 32768.0
                else:
                    # indata likely numpy array-like; make a copy
                    arr = np.array(indata, copy=True)
                    # If multi-channel, take first channel
                    if arr.ndim > 1:
                        arr = arr[:, 0]
                    # If integer type, normalize by dtype max
                    if np.issubdtype(arr.dtype, np.integer):
                        try:
                            maxv = np.iinfo(arr.dtype).max
                            arr = arr.astype(np.float32) / float(maxv if maxv > 0 else 32768.0)
                        except Exception:
                            arr = arr.astype(np.float32) / 32768.0
                    else:
                        # float types: ensure float32
                        arr = arr.astype(np.float32)
                        # if floats appear to be in int-range, rescale
                        max_abs = float(np.max(np.abs(arr))) if arr.size else 0.0
                        if max_abs > 1.0:
                            arr = arr / max_abs
                # final ensure 1-D float32
                if arr.ndim > 1:
                    arr = arr.ravel()
                arr = arr.astype(np.float32, copy=False)
                self._frames.append(arr)
            except Exception:
                return

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

    def get_wav(self):
        with self._lock:
            if not self._frames:
                return None
            try:
                audio = np.concatenate(self._frames, axis=0)
                return audio
            except Exception:
                parts = []
                for f in self._frames:
                    if isinstance(f, (bytes, bytearray)):
                        a = np.frombuffer(bytes(f), dtype=np.int16).astype(np.float32) / 32768.0
                    else:
                        a = np.asarray(f, dtype=np.float32)
                    parts.append(a)
                if not parts:
                    return None
                return np.concatenate(parts, axis=0)


# VAD trimming utility (webrtcvad) with energy fallback
def vad_trim(audio, sample_rate, aggressiveness=2, frame_ms=30, padding_ms=150, energy_threshold=0.01):
    """Trim leading and trailing silence using webrtcvad if available.
    If webrtcvad is not installed, use simple energy-based trimming.
    audio: float32 array [-1,1]
    returns trimmed float32 array
    """
    if audio is None or len(audio) == 0:
        return np.array([], dtype=np.float32)
    if HAVE_VAD:
        # Convert to 16-bit PCM
        int16 = (audio * 32767).astype(np.int16)
        pcm_bytes = int16.tobytes()
        vad = webrtcvad.Vad(aggressiveness)
        frame_bytes = int(sample_rate * (frame_ms / 1000.0) * 2)  # 2 bytes per sample
        if frame_bytes <= 0:
            return audio
        frames = [pcm_bytes[i:i+frame_bytes] for i in range(0, len(pcm_bytes), frame_bytes)]
        if not frames:
            return np.array([], dtype=np.float32)
        speech_flags = [vad.is_speech(f, sample_rate) if len(f) == frame_bytes else False for f in frames]
        try:
            first = next(i for i, v in enumerate(speech_flags) if v)
            last = len(speech_flags) - 1 - next(i for i, v in enumerate(reversed(speech_flags)) if v)
        except StopIteration:
            return np.array([], dtype=np.float32)
        start_byte = max(0, first * frame_bytes - int(padding_ms/1000.0*sample_rate*2))
        end_byte = min(len(pcm_bytes), (last+1) * frame_bytes + int(padding_ms/1000.0*sample_rate*2))
        trimmed = np.frombuffer(pcm_bytes[start_byte:end_byte], dtype=np.int16).astype(np.float32) / 32768.0
        return trimmed
    else:
        # simple energy-based trimming (fallback)
        frame_len = int(sample_rate * frame_ms / 1000.0)
        if frame_len <= 0:
            return audio
        # pad to full frames
        n_frames = int(math.ceil(len(audio) / frame_len))
        energies = []
        for i in range(n_frames):
            start = i * frame_len
            stop = min(len(audio), (i+1) * frame_len)
            frame = audio[start:stop]
            energies.append(float(np.mean(frame.astype(np.float32)**2)) if len(frame) else 0.0)
        energies = np.array(energies)
        speech = energies > (energy_threshold ** 2)
        # find speech segments
        if not np.any(speech):
            return np.array([], dtype=np.float32)
        first = int(np.argmax(speech))
        last = len(speech) - 1 - int(np.argmax(speech[::-1]))
        start_sample = max(0, first * frame_len - int(padding_ms/1000.0*sample_rate))
        end_sample = min(len(audio), (last+1) * frame_len + int(padding_ms/1000.0*sample_rate))
        return audio[start_sample:end_sample]


def rms_level(audio):
    if audio is None or len(audio) == 0:
        return 0.0
    return math.sqrt(float(np.mean(audio.astype(np.float32) ** 2)))


def is_blacklisted(text):
    if not text:
        return False
    t = text.strip().lower()
    for bad in BLACKLIST:
        if bad in t:
            return True
    return False


def transcribe_and_send(model, audio_array, samplerate, player_index, udp_ip, udp_port,
                        min_duration=0.4, energy_threshold=0.01, vad_aggr=2, assistant=False, assistant_port=38768,
                        min_words=1):
    # 1) ensure audio is float32
    if audio_array is None or len(audio_array) == 0:
        print("No audio frames captured.")
        return
    audio_array = np.asarray(audio_array, dtype=np.float32)
    # 2) apply VAD trimming (or fallback)
    trimmed = vad_trim(audio_array, samplerate, aggressiveness=vad_aggr, energy_threshold=energy_threshold)
    if trimmed is None or len(trimmed) == 0:
        print("VAD removed all audio — nothing to send.")
        return
    # 3) check duration
    duration = len(trimmed) / float(samplerate)
    if duration < min_duration:
        print(f"Recording too short after trim: {duration:.2f}s (<{min_duration}s). Ignoring.")
        return
    # 4) check energy
    level = rms_level(trimmed)
    print(f"Post-VAD duration={duration:.2f}s rms={level:.5f}")
    if level < energy_threshold:
        print(f"Audio below energy threshold ({level:.5f} < {energy_threshold}). Ignoring.")
        return
    # 5) write temp wav and transcribe
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
        tmpname = f.name
    try:
        sf.write(tmpname, trimmed, samplerate, subtype='PCM_16')
        try:
            # smaller beam_size speeds up and is usually fine for short phrases
            segments, info = model.transcribe(tmpname, language='ru', beam_size=2)
            text = " ".join([seg.text.strip() for seg in segments]).strip()
        except Exception as e:
            print("Transcription error:", e)
            text = ""
        if not text:
            print("No speech recognized or transcription failed.")
            return
        # 6) simple post-filters
        low_words = len([w for w in text.split() if w.strip()])
        if low_words < min_words:
            print(f"Transcribed too short ({low_words} words). Ignoring: {text}")
            return
        if is_blacklisted(text):
            print(f"Transcribed text blacklisted, ignoring: {text}")
            return
        print(f"Transcribed: {text}")
        if assistant:
            # request bridge to send a copy back by including reply_back fields
            send_udp_text(text, player_index, udp_ip, udp_port, reply_back_ip='127.0.0.1', reply_back_port=assistant_port)
        else:
            send_udp_text(text, player_index, udp_ip, udp_port)
    finally:
        try:
            os.remove(tmpname)
        except Exception:
            pass


def check_microphone():
    try:
        sd.check_input_settings(device=None, channels=1, samplerate=16000)
        return True
    except Exception as e:
        print("Microphone check failed:", e)
        return False


def assistant_listener(listen_ip, listen_port, stop_event):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((listen_ip, listen_port))
    except Exception as e:
        print(f"Assistant listener failed to bind {listen_ip}:{listen_port}: {e}")
        return
    sock.settimeout(1.0)
    print(f"Assistant listening for replies on {listen_ip}:{listen_port}")
    while not stop_event.is_set():
        try:
            data, addr = sock.recvfrom(65536)
            try:
                text = data.decode('utf-8')
            except Exception:
                text = data.decode('utf-8', errors='replace')
            # try parse JSON and display text
            try:
                obj = json.loads(text)
                if isinstance(obj, dict) and obj.get('type') == 'response':
                    print(f"Assistant received response for player {obj.get('player_index')}: {obj.get('text')}")
                else:
                    print(f"Assistant received: {text}")
            except Exception:
                print(f"Assistant received raw: {text}")
        except socket.timeout:
            continue
        except Exception as e:
            print("Assistant listener error:", e)
            break
    sock.close()


def main():
    parser = argparse.ArgumentParser(description="Voice input for Oleg (Factorio bridge)")
    parser.add_argument("--player-index", type=int, default=1, help="player_index to send in JSON (default 1)")
    parser.add_argument("--udp-ip", default="127.0.0.1", help="bridge UDP IP (default 127.0.0.1)")
    parser.add_argument("--udp-port", type=int, default=38767, help="bridge UDP port (default 38767)")
    parser.add_argument("--model-size", default="small", help="faster-whisper model size (tiny, base, small, medium, large)")
    parser.add_argument("--device", default="cpu", help="device for model: cpu or cuda")
    parser.add_argument("--hotkey", default="f9", help="hotkey to record (default: F9)")
    parser.add_argument("--mode", choices=["hotkey", "manual"], default="hotkey", help="hotkey or manual enter-based mode")
    parser.add_argument("--min-duration", type=float, default=0.4, help="minimum duration after VAD to accept (s)")
    parser.add_argument("--energy-threshold", type=float, default=0.01, help="RMS energy threshold to accept audio")
    parser.add_argument("--vad-aggr", type=int, default=2, help="webrtcvad aggressiveness 0-3")
    parser.add_argument("--assistant", action='store_true', help="receive bridge replies locally and print them (assistant mode)")
    parser.add_argument("--assistant-port", type=int, default=38768, help="local UDP port to receive assistant replies")
    parser.add_argument("--min-words", type=int, default=1, help="minimum words in transcription to accept")
    args = parser.parse_args()

    # microphone check
    if not check_microphone():
        print("No usable microphone detected. Exiting.")
        sys.exit(1)

    if not HAVE_FASTER_WHISPER:
        print("faster-whisper not installed. Install dependencies listed in bridge/requirements_voice.txt and ensure torch is installed.")
        sys.exit(1)

    if args.assistant:
        # start assistant listener thread
        stop_event = threading.Event()
        t = threading.Thread(target=assistant_listener, args=('127.0.0.1', args.assistant_port, stop_event), daemon=True)
        t.start()

    if not HAVE_VAD:
        print("webrtcvad not installed — using energy-based trimming fallback. Install webrtcvad for better results.")

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

        # handlers
        def on_press(e):
            if not rec.recording:
                print("Start recording...")
                rec.start()

        def on_release(e):
            if rec.recording:
                rec.stop()
                print("Stop recording, trimming and transcribing...")
                audio = rec.get_wav()
                if audio is None:
                    print("No audio captured.")
                    return
                transcribe_and_send(model, audio, rec.samplerate, args.player_index, args.udp_ip, args.udp_port,
                                    min_duration=args.min_duration, energy_threshold=args.energy_threshold, vad_aggr=args.vad_aggr,
                                    assistant=args.assistant, assistant_port=args.assistant_port, min_words=args.min_words)

        keyboard.on_press_key(hotkey, lambda e: on_press(e))
        keyboard.on_release_key(hotkey, lambda e: on_release(e))

        print("Press Ctrl+C to exit.")
        try:
            keyboard.wait()
        except KeyboardInterrupt:
            print("Exiting...")
            if args.assistant:
                stop_event.set()
                t.join(timeout=1.0)

    else:
        print("Manual mode: press Enter to start recording, Enter again to stop (Ctrl+C to quit).")
        try:
            while True:
                input("Press Enter to start recording...")
                rec.start()
                print("Recording... press Enter to stop")
                input()
                rec.stop()
                print("Stopped. Trimming and transcribing...")
                audio = rec.get_wav()
                if audio is None:
                    print("No audio captured.")
                    continue
                transcribe_and_send(model, audio, rec.samplerate, args.player_index, args.udp_ip, args.udp_port,
                                    min_duration=args.min_duration, energy_threshold=args.energy_threshold, vad_aggr=args.vad_aggr,
                                    assistant=args.assistant, assistant_port=args.assistant_port, min_words=args.min_words)
        except KeyboardInterrupt:
            print("Exiting...")
            if args.assistant:
                stop_event.set()
                t.join(timeout=1.0)


if __name__ == '__main__':
    main()
