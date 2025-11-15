#!/bin/bash

set -euo pipefail

# Adapted from https://github.com/karpathy/nanochat/blob/9a71d1368899b7bfbb8e1fad966b683ec80a5760/dev/runcpu.sh

# Showing an example run for exercising some of the code paths on the CPU (or MPS on Macbooks)
# Run as:
# bash dev/cpu_demo_run.sh

# NOTE: Training LLMs requires GPU compute and $$$. You will not get far on your Macbook.
# Think of this run as educational/fun demo, not something you should expect to work well.
# This is also why I hide this script away in dev/

# all the setup stuff
export OMP_NUM_THREADS=1
export NANOCHAT_BASE_DIR="$HOME/.cache/nanochat"
export NANOCHAT_REPO_DIR="$PWD/../../nanochat"

echo "cd-ing into $NANOCHAT_REPO_DIR"
cd $NANOCHAT_REPO_DIR || exit 1

mkdir -p $NANOCHAT_BASE_DIR

uv sync --extra cpu
source .venv/bin/activate

WANDB_RUN=dummy

uv run maturin develop --release --manifest-path rustbpe/Cargo.toml

# # wipe the report
python -m nanochat.report reset

# # train tokenizer on ~1B characters
python -m nanochat.dataset -n 4
python -m scripts.tok_train --max_chars=1000000000
python -m scripts.tok_eval

echo "PRETRAINING"

# train a very small 4 layer model on the CPU
# each optimization step processes a single sequence of 1024 tokens
# we only run 50 steps of optimization (bump this to get better results)
# Reduced max_seq_len and eval_tokens to avoid OOM on MPS
# core_metric_max_per_task must be >= 11 for 10-shot tasks
python -m scripts.base_train \
    --depth=2 \
    --max_seq_len=512 \
    --device_batch_size=1 \
    --total_batch_size=512 \
    --eval_every=50 \
    --eval_tokens=2048 \
    --core_metric_every=50 \
    --core_metric_max_per_task=11 \
    --sample_every=50 \
    --num_iterations=50
python -m scripts.base_loss --device_batch_size=1 --split_tokens=4096
python -m scripts.base_eval --max-per-task=16

echo "MIDTRAINING"

# midtraining
python -m scripts.mid_train \
    --max_seq_len=512 \
    --device_batch_size=1 \
    --eval_every=50 \
    --eval_tokens=2048 \
    --total_batch_size=512 \
    --num_iterations=100
# eval results will be terrible, this is just to execute the code paths.
# note that we lower the execution memory limit to 1MB to avoid warnings on smaller systems
python -m scripts.chat_eval --source=mid --max-new-tokens=128 --max-problems=20


echo "SFT"

# SFT
python -m scripts.chat_sft \
    --device_batch_size=1 \
    --target_examples_per_step=4 \
    --num_iterations=30 \
    --eval_steps=4 \
    --eval_metrics_max_problems=16

# # Chat CLI
# # python -m scripts.chat_cli -p "Why is the sky blue?"

# # Chat Web
# # python -m scripts.chat_web

python -m nanochat.report generate
