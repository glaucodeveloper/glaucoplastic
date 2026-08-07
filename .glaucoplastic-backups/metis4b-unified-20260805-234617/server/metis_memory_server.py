from __future__ import annotations

import argparse
import json
import os
import queue
import threading
import time
import traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib import request as urllib_request

import torch
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    BitsAndBytesConfig,
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def atomic_jsonl_append(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(payload, ensure_ascii=False) + "\n")


class MetisMemoryRuntime:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.model_path = Path(args.model).expanduser().resolve()
        self.profile_root = (
            Path(args.data_root).expanduser().resolve() / args.profile
        )
        self.profile_root.mkdir(parents=True, exist_ok=True)

        self.snapshot_path = self.profile_root / "metis-memory.pt"
        self.exchanges_path = self.profile_root / "exchanges.jsonl"
        self.events_path = self.profile_root / "events.jsonl"
        self.offload_path = self.profile_root / "offload"
        self.offload_path.mkdir(parents=True, exist_ok=True)

        self.model_lock = threading.RLock()
        self.queue: queue.Queue[dict[str, Any] | None] = queue.Queue()
        self.stopping = threading.Event()
        self.worker = threading.Thread(
            target=self._worker_loop,
            name="metis-memory-commit",
            daemon=True,
        )

        self.processed = 0
        self.skipped = 0
        self.failed = 0
        self.last_error = ""
        self.active = False
        self.started_at = utc_now()

        torch.set_num_threads(max(1, args.cpu_threads))
        try:
            torch.set_num_interop_threads(1)
        except RuntimeError:
            pass

        if not torch.cuda.is_available():
            raise RuntimeError(
                "CUDA não está disponível no ambiente Python do Metis."
            )

        torch.cuda.empty_cache()

        dtype = {
            "float16": torch.float16,
            "bfloat16": torch.bfloat16,
            "float32": torch.float32,
        }[args.dtype]

        print(
            f"[Metis] carregando tokenizer de {self.model_path}",
            flush=True,
        )
        self.tokenizer = AutoTokenizer.from_pretrained(
            str(self.model_path),
            trust_remote_code=True,
            local_files_only=True,
        )

        if self.tokenizer.pad_token_id is None:
            self.tokenizer.pad_token = self.tokenizer.eos_token

        quantization = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_use_double_quant=True,
            bnb_4bit_compute_dtype=dtype,
        )

        print(
            "[Metis] carregando modelo inteiro em CUDA/4-bit; "
            "offload Accelerate desativado",
            flush=True,
        )

        self.model = AutoModelForCausalLM.from_pretrained(
            str(self.model_path),
            trust_remote_code=True,
            local_files_only=True,
            torch_dtype=dtype,
            device_map={"": 0},
            low_cpu_mem_usage=True,
            quantization_config=quantization,
        )
        self.model.eval()
        self.input_device = torch.device(args.device)

        if self.snapshot_path.exists():
            restored = self.restore_snapshot()
            print(
                f"[Metis] snapshot restaurado: {restored} camada(s)",
                flush=True,
            )

        self.worker.start()
        print(
            f"[Metis] pronto em {args.device}; perfil={args.profile}",
            flush=True,
        )

    def render(
        self,
        messages: list[dict[str, str]],
        add_generation_prompt: bool,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        try:
            text = self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=add_generation_prompt,
                enable_thinking=False,
            )
        except TypeError:
            text = self.tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=add_generation_prompt,
            )

        encoded = self.tokenizer(
            text,
            add_special_tokens=False,
            return_tensors="pt",
        )

        return (
            encoded["input_ids"].to(self.input_device),
            encoded["attention_mask"].to(self.input_device),
        )

    def capture_state(self) -> dict[str, Any]:
        layers: dict[str, dict[str, torch.Tensor]] = {}
        blocks = self.model.model.metis_blocks

        for index, block in enumerate(blocks):
            local_memory = getattr(block, "local_memory", None)
            if local_memory is None:
                continue

            state: dict[str, torch.Tensor] = {}
            for attribute in ("_state", "_key_state", "memory_state"):
                value = getattr(local_memory, attribute, None)
                if torch.is_tensor(value):
                    state[attribute] = (
                        value.detach().to("cpu").contiguous()
                    )

            if state:
                layers[str(index)] = state

        return {
            "format": "metis-runtime-memory-v1",
            "model_id": self.args.model_id,
            "saved_at": utc_now(),
            "layers": layers,
        }

    def save_snapshot(self) -> None:
        temporary = self.snapshot_path.with_suffix(
            f".{int(time.time())}.tmp"
        )
        torch.save(self.capture_state(), temporary)
        os.replace(temporary, self.snapshot_path)

    def restore_snapshot(self) -> int:
        try:
            payload = torch.load(
                self.snapshot_path,
                map_location="cpu",
                weights_only=True,
            )
        except TypeError:
            payload = torch.load(
                self.snapshot_path,
                map_location="cpu",
            )

        if payload.get("format") != "metis-runtime-memory-v1":
            raise RuntimeError("Formato de snapshot Metis desconhecido.")

        if payload.get("model_id") != self.args.model_id:
            raise RuntimeError("O snapshot pertence a outro modelo.")

        self.model.reset()
        blocks = self.model.model.metis_blocks
        restored = 0
        dtype = {
            "float16": torch.float16,
            "bfloat16": torch.bfloat16,
            "float32": torch.float32,
        }[self.args.dtype]

        for index_text, attributes in payload.get("layers", {}).items():
            index = int(index_text)
            if index < 0 or index >= len(blocks):
                continue

            local_memory = getattr(
                blocks[index],
                "local_memory",
                None,
            )
            if local_memory is None:
                continue

            for attribute, tensor in attributes.items():
                setattr(
                    local_memory,
                    attribute,
                    tensor.to(
                        device=self.input_device,
                        dtype=dtype,
                    ),
                )
            restored += 1

        return restored

    def commit(self, user_text: str, assistant_text: str) -> None:
        input_ids, attention_mask = self.render(
            [
                {"role": "user", "content": user_text},
                {"role": "assistant", "content": assistant_text},
            ],
            add_generation_prompt=False,
        )

        with torch.inference_mode():
            self.model(
                input_ids=input_ids,
                attention_mask=attention_mask,
                commit_memory=True,
                use_cache=False,
                logits_to_keep=1,
            )

    def query_memory(self, text: str) -> str:
        input_ids, attention_mask = self.render(
            [
                {
                    "role": "system",
                    "content": (
                        "Você lê a sua memória nativa persistente para "
                        "auxiliar outro modelo. Recupere somente informações "
                        "anteriormente fornecidas pelo usuário que sejam "
                        "relevantes à consulta atual. Não use conhecimento "
                        "geral, não invente e não explique o mecanismo. "
                        "Responda em português, em itens curtos. Se não "
                        "houver memória relevante, responda exatamente: "
                        "SEM_MEMORIA_RELEVANTE"
                    ),
                },
                {
                    "role": "user",
                    "content": "Consulta atual:\n" + text,
                },
            ],
            add_generation_prompt=True,
        )

        with torch.inference_mode():
            output = self.model.generate(
                input_ids=input_ids,
                attention_mask=attention_mask,
                max_new_tokens=self.args.query_tokens,
                do_sample=False,
                use_cache=True,
                eos_token_id=self.tokenizer.eos_token_id,
                pad_token_id=self.tokenizer.pad_token_id,
            )

        generated = output[0, input_ids.shape[1] :]
        result = self.tokenizer.decode(
            generated,
            skip_special_tokens=True,
        ).strip()

        return result or "SEM_MEMORIA_RELEVANTE"

    def extract_durable(
        self,
        user_text: str,
        assistant_text: str,
    ) -> str:
        endpoint = self.args.gemma_endpoint.rstrip("/")
        url = endpoint + "/chat/completions"

        payload = {
            "model": self.args.gemma_model,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "Você consolida memória de longo prazo. Extraia "
                        "somente fatos duráveis explicitamente fornecidos "
                        "pelo usuário: identidade, preferências, projetos, "
                        "decisões, restrições, relações e objetivos "
                        "persistentes. Não memorize saudações, perguntas "
                        "momentâneas, hipóteses ou afirmações inventadas "
                        "pelo assistente. Escreva frases declarativas "
                        "curtas em português. Se não houver fato durável, "
                        "responda exatamente SEM_MEMORIA_DURAVEL."
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        "Mensagem do usuário:\n"
                        + user_text
                        + "\n\nResposta produzida:\n"
                        + assistant_text
                    ),
                },
            ],
            "max_tokens": self.args.worker_max_tokens,
            "temperature": 0,
            "stream": False,
        }

        body = json.dumps(payload).encode("utf-8")
        req = urllib_request.Request(
            url,
            data=body,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method="POST",
        )

        with urllib_request.urlopen(
            req,
            timeout=self.args.gemma_timeout,
        ) as response:
            parsed = json.loads(
                response.read().decode("utf-8")
            )

        return (
            parsed["choices"][0]["message"]["content"]
            .strip()
        )

    @staticmethod
    def is_no_durable_memory(text: str) -> bool:
        normalized = (
            text.strip()
            .upper()
            .replace(" ", "_")
            .replace(".", "")
        )
        return (
            not text.strip()
            or normalized == "SEM_MEMORIA_DURAVEL"
        )

    def enqueue(
        self,
        session: str,
        user_text: str,
        assistant_text: str,
    ) -> None:
        event = {
            "timestamp": utc_now(),
            "session": session,
            "user": user_text,
            "assistant": assistant_text,
            "state": "queued",
        }
        atomic_jsonl_append(self.exchanges_path, event)
        self.queue.put(event)

    def _worker_loop(self) -> None:
        while not self.stopping.is_set():
            job = self.queue.get()
            if job is None:
                self.queue.task_done()
                break

            self.active = True
            try:
                try:
                    durable = self.extract_durable(
                        job["user"],
                        job["assistant"],
                    )
                except Exception as error:
                    print(
                        "[Metis] consolidação pelo Gemma falhou; "
                        f"usando mensagem integral: {error}",
                        flush=True,
                    )
                    durable = (
                        "Mensagem durável fornecida pelo usuário:\n"
                        + job["user"]
                    )

                if self.is_no_durable_memory(durable):
                    self.skipped += 1
                    atomic_jsonl_append(
                        self.events_path,
                        {
                            "kind": "memory_skip",
                            "timestamp": utc_now(),
                            "session": job["session"],
                        },
                    )
                else:
                    with self.model_lock:
                        self.commit(
                            (
                                "Informações duráveis fornecidas pelo "
                                "usuário e destinadas à memória de longo "
                                "prazo:\n" + durable
                            ),
                            "Memória consolidada e registrada.",
                        )
                        self.save_snapshot()

                    self.processed += 1
                    atomic_jsonl_append(
                        self.events_path,
                        {
                            "kind": "memory_commit",
                            "timestamp": utc_now(),
                            "session": job["session"],
                            "memory": durable,
                        },
                    )

            except Exception as error:
                self.failed += 1
                self.last_error = str(error)
                traceback.print_exc()
            finally:
                self.active = False
                self.queue.task_done()

    def flush(self) -> None:
        self.queue.join()
        with self.model_lock:
            self.save_snapshot()

    def reset(self) -> None:
        self.flush()
        with self.model_lock:
            self.model.reset()
            if self.snapshot_path.exists():
                self.snapshot_path.unlink()

    def rebuild(self) -> int:
        self.flush()

        exchanges: list[dict[str, Any]] = []
        if self.exchanges_path.exists():
            for line in self.exchanges_path.read_text(
                encoding="utf-8"
            ).splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    exchanges.append(json.loads(line))
                except json.JSONDecodeError:
                    continue

        with self.model_lock:
            self.model.reset()
            count = 0
            for event in exchanges:
                user = str(event.get("user", ""))
                assistant = str(event.get("assistant", ""))
                if not user:
                    continue
                self.commit(user, assistant)
                count += 1
            self.save_snapshot()

        return count

    def health(self) -> dict[str, Any]:
        free_bytes, total_bytes = torch.cuda.mem_get_info()
        return {
            "ok": True,
            "model": self.args.model_id,
            "profile": self.args.profile,
            "device": self.args.device,
            "quantization": "4bit-nf4",
            "gpuFreeMiB": free_bytes // 1024 // 1024,
            "placement": "cuda-4bit-no-offload",
            "gpuTotalMiB": total_bytes // 1024 // 1024,
            "snapshot": str(self.snapshot_path),
            "snapshotExists": self.snapshot_path.exists(),
            "queued": self.queue.qsize(),
            "active": self.active,
            "processed": self.processed,
            "skipped": self.skipped,
            "failed": self.failed,
            "lastError": self.last_error,
            "startedAt": self.started_at,
        }


class Handler(BaseHTTPRequestHandler):
    runtime: MetisMemoryRuntime

    def log_message(
        self,
        format: str,
        *args: Any,
    ) -> None:
        print(
            "[Metis HTTP] " + format % args,
            flush=True,
        )

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}

        value = json.loads(
            self.rfile.read(length).decode("utf-8")
        )
        if not isinstance(value, dict):
            raise ValueError("O corpo JSON deve ser um objeto.")
        return value

    def send_json(
        self,
        status: int,
        payload: dict[str, Any],
    ) -> None:
        body = json.dumps(
            payload,
            ensure_ascii=False,
        ).encode("utf-8")

        self.send_response(status)
        self.send_header(
            "Content-Type",
            "application/json; charset=utf-8",
        )
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        try:
            if self.path in {"/health", "/v1/health"}:
                self.send_json(200, self.runtime.health())
                return

            if self.path == "/v1/models":
                self.send_json(
                    200,
                    {
                        "object": "list",
                        "data": [
                            {
                                "id": self.runtime.args.model_id,
                                "object": "model",
                            }
                        ],
                    },
                )
                return

            self.send_json(
                404,
                {"error": {"message": "Not found"}},
            )
        except Exception as error:
            traceback.print_exc()
            self.send_json(
                500,
                {"error": {"message": str(error)}},
            )

    def do_POST(self) -> None:
        try:
            payload = self.read_json()

            if self.path == "/v1/memory/query":
                text = str(payload.get("text", ""))
                with self.runtime.model_lock:
                    memory = self.runtime.query_memory(text)
                self.send_json(
                    200,
                    {
                        "ok": True,
                        "memory": memory,
                    },
                )
                return

            if self.path == "/v1/memory/record":
                self.runtime.enqueue(
                    str(payload.get("session", "default")),
                    str(payload.get("user", "")),
                    str(payload.get("assistant", "")),
                )
                self.send_json(
                    202,
                    {
                        "ok": True,
                        "queued": self.runtime.queue.qsize(),
                    },
                )
                return

            if self.path == "/v1/memory/flush":
                self.runtime.flush()
                self.send_json(200, {"ok": True})
                return

            if self.path == "/v1/memory/reset":
                self.runtime.reset()
                self.send_json(200, {"ok": True})
                return

            if self.path == "/v1/memory/rebuild":
                count = self.runtime.rebuild()
                self.send_json(
                    200,
                    {"ok": True, "count": count},
                )
                return

            self.send_json(
                404,
                {"error": {"message": "Not found"}},
            )
        except Exception as error:
            self.runtime.last_error = str(error)
            traceback.print_exc()
            self.send_json(
                500,
                {
                    "error": {
                        "message": str(error),
                        "type": type(error).__name__,
                    }
                },
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument(
        "--model-id",
        default="IAAR-Shanghai/Metis-4B",
    )
    parser.add_argument("--profile", default="icaro")
    parser.add_argument(
        "--data-root",
        default=str(
            Path.home()
            / ".local/share/glaucoplastic/metis-external"
        ),
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=19192)
    parser.add_argument("--device", default="cuda:0")
    parser.add_argument(
        "--dtype",
        choices=["float16", "bfloat16", "float32"],
        default="float16",
    )
    parser.add_argument(
        "--gpu-max-mib",
        type=int,
        default=3300,
    )
    parser.add_argument(
        "--cpu-memory",
        default="48GiB",
    )
    parser.add_argument(
        "--cpu-threads",
        type=int,
        default=max(1, os.cpu_count() or 1),
    )
    parser.add_argument(
        "--query-tokens",
        type=int,
        default=96,
    )
    parser.add_argument(
        "--worker-max-tokens",
        type=int,
        default=128,
    )
    parser.add_argument(
        "--gemma-endpoint",
        default="http://127.0.0.1:19191/v1",
    )
    parser.add_argument(
        "--gemma-model",
        default="gemma-3-4b",
    )
    parser.add_argument(
        "--gemma-timeout",
        type=int,
        default=900,
    )

    args = parser.parse_args()

    runtime = MetisMemoryRuntime(args)
    Handler.runtime = runtime

    server = ThreadingHTTPServer(
        (args.host, args.port),
        Handler,
    )

    print(
        f"[Metis] HTTP: http://{args.host}:{args.port}/v1",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()

