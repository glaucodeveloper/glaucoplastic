#!/usr/bin/env python3
"""
Treinador LoRA opcional para o exemplo GlaucoPlastic.

Dependências:
  pip install torch transformers peft

Variáveis:
  GLAUCOPLASTIC_BASE_MODEL   modelo Transformers de origem
  GLAUCOPLASTIC_EPOCHS       padrão: 1
  GLAUCOPLASTIC_MAX_LENGTH   padrão: 2048
  GLAUCOPLASTIC_LR           padrão: 0.0002
  GLAUCOPLASTIC_TARGET_MODULES
                             padrão: q_proj,k_proj,v_proj,o_proj

O script recebe o JSONL conversacional produzido pelo framework e grava um
adapter PEFT no diretório de saída. Para modelos GGUF, converta o adapter com a
ferramenta correspondente do llama.cpp antes da ativação no llama-server.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def load_examples(path: Path) -> list[list[dict[str, Any]]]:
    examples: list[list[dict[str, Any]]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.strip()
            if not line:
                continue
            item = json.loads(line)
            messages = item.get("messages")
            if not isinstance(messages, list) or not messages:
                raise ValueError(f"Linha {line_number}: campo messages inválido")
            examples.append(messages)
    if not examples:
        raise ValueError("O dataset não contém exemplos")
    return examples


def main() -> None:
    args = parse_args()
    base_model = os.environ.get("GLAUCOPLASTIC_BASE_MODEL", "").strip()
    if not base_model:
        raise SystemExit("Defina GLAUCOPLASTIC_BASE_MODEL para o modelo Transformers de origem")

    try:
        import torch
        from peft import LoraConfig, get_peft_model
        from torch.utils.data import DataLoader, Dataset
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except ImportError as error:
        raise SystemExit(
            "Dependências ausentes. Instale: pip install torch transformers peft"
        ) from error

    dataset_path = Path(args.dataset).resolve()
    output_path = Path(args.output).resolve()
    output_path.mkdir(parents=True, exist_ok=True)

    examples = load_examples(dataset_path)
    max_length = int(os.environ.get("GLAUCOPLASTIC_MAX_LENGTH", "2048"))
    epochs = int(os.environ.get("GLAUCOPLASTIC_EPOCHS", "1"))
    learning_rate = float(os.environ.get("GLAUCOPLASTIC_LR", "0.0002"))
    target_modules = [
        value.strip()
        for value in os.environ.get(
            "GLAUCOPLASTIC_TARGET_MODULES",
            "q_proj,k_proj,v_proj,o_proj",
        ).split(",")
        if value.strip()
    ]

    tokenizer = AutoTokenizer.from_pretrained(base_model, use_fast=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        base_model,
        torch_dtype="auto",
        device_map="auto",
    )
    model.config.use_cache = False
    model = get_peft_model(
        model,
        LoraConfig(
            task_type="CAUSAL_LM",
            r=16,
            lora_alpha=32,
            lora_dropout=0.05,
            target_modules=target_modules,
        ),
    )

    class ConversationDataset(Dataset):
        def __len__(self) -> int:
            return len(examples)

        def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
            text = tokenizer.apply_chat_template(
                examples[index],
                tokenize=False,
                add_generation_prompt=False,
            )
            encoded = tokenizer(
                text,
                truncation=True,
                max_length=max_length,
                return_tensors="pt",
            )
            input_ids = encoded["input_ids"][0]
            attention_mask = encoded["attention_mask"][0]
            return {
                "input_ids": input_ids,
                "attention_mask": attention_mask,
                "labels": input_ids.clone(),
            }

    def collate(batch: list[dict[str, torch.Tensor]]) -> dict[str, torch.Tensor]:
        max_size = max(item["input_ids"].shape[0] for item in batch)
        input_ids: list[torch.Tensor] = []
        attention_masks: list[torch.Tensor] = []
        labels: list[torch.Tensor] = []

        for item in batch:
            pad_size = max_size - item["input_ids"].shape[0]
            input_ids.append(
                torch.nn.functional.pad(
                    item["input_ids"],
                    (0, pad_size),
                    value=tokenizer.pad_token_id,
                )
            )
            attention_masks.append(
                torch.nn.functional.pad(item["attention_mask"], (0, pad_size), value=0)
            )
            labels.append(
                torch.nn.functional.pad(item["labels"], (0, pad_size), value=-100)
            )

        return {
            "input_ids": torch.stack(input_ids),
            "attention_mask": torch.stack(attention_masks),
            "labels": torch.stack(labels),
        }

    loader = DataLoader(
        ConversationDataset(),
        batch_size=1,
        shuffle=True,
        collate_fn=collate,
    )
    optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate)
    model.train()

    for epoch in range(epochs):
        for step, batch in enumerate(loader, start=1):
            device = next(model.parameters()).device
            batch = {name: tensor.to(device) for name, tensor in batch.items()}
            output = model(**batch)
            output.loss.backward()
            optimizer.step()
            optimizer.zero_grad(set_to_none=True)
            print(
                json.dumps(
                    {
                        "epoch": epoch + 1,
                        "step": step,
                        "loss": float(output.loss.detach().cpu()),
                    }
                ),
                flush=True,
            )

    model.save_pretrained(output_path)
    tokenizer.save_pretrained(output_path)
    (output_path / "glaucoplastic-training.json").write_text(
        json.dumps(
            {
                "base_model": base_model,
                "dataset": str(dataset_path),
                "examples": len(examples),
                "epochs": epochs,
                "learning_rate": learning_rate,
                "target_modules": target_modules,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
