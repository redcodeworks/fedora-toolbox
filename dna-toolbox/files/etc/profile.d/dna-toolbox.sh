# dna-toolbox environment: the pinned DNA_* versions (overridable) and where models are stored.
if [ -r /usr/share/dna-toolbox/versions.env ]; then
    . /usr/share/dna-toolbox/versions.env
fi
export DNA_DATA_DIR="${DNA_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/dna-toolbox}"
# Models are big: point them at a data volume by setting DNA_MODELS_DIR (for example in the box's
# shell profile) before the first pull
export DNA_MODELS_DIR="${DNA_MODELS_DIR:-$DNA_DATA_DIR/models}"
export OLLAMA_MODELS="${OLLAMA_MODELS:-$DNA_MODELS_DIR/ollama}"
export HF_HOME="${HF_HOME:-$DNA_MODELS_DIR/huggingface}"
export DNA_PORT_OFFSET="${DNA_PORT_OFFSET:-10000}"
