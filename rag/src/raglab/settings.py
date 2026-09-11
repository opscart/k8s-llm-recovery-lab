"""Pinned models and bounded ingestion defaults."""

EMBEDDING_MODEL = "BAAI/bge-small-en-v1.5"
EMBEDDING_REVISION = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"

# BGE v1.5 uses a query instruction but does not require a document prefix.
QUERY_PREFIX = "Represent this sentence for searching relevant passages: "

MAX_FILE_BYTES = 1_000_000
MAX_CHUNK_CHARS = 3_200
OVERLAP_LINES = 10
EMBEDDING_BATCH_SIZE = 32

# Calibrated against the two-repository pilot. Queries below this dense
# similarity are treated as insufficient evidence unless explicitly overridden.
DEFAULT_ANSWERABILITY_THRESHOLD = 0.68

ALLOWED_FILENAMES = {
    "Dockerfile",
    "Jenkinsfile",
    "Makefile",
    "Taskfile.yml",
    "docker-compose.yml",
    "docker-compose.yaml",
}

ALLOWED_SUFFIXES = {
    ".bash",
    ".c",
    ".cc",
    ".cfg",
    ".conf",
    ".cpp",
    ".cs",
    ".css",
    ".go",
    ".h",
    ".hcl",
    ".helm",
    ".html",
    ".ini",
    ".java",
    ".js",
    ".json",
    ".jsx",
    ".kt",
    ".kts",
    ".md",
    ".properties",
    ".proto",
    ".ps1",
    ".py",
    ".rb",
    ".rs",
    ".sh",
    ".sql",
    ".tf",
    ".tfvars.example",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}

EXCLUDED_DIRECTORIES = {
    ".git",
    ".terraform",
    ".venv",
    ".venv-rag",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "target",
    "vendor",
}

EXCLUDED_FILENAMES = {
    "Cargo.lock",
    "go.sum",
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
}

SENSITIVE_FILENAMES = {
    ".env",
    ".npmrc",
    ".pypirc",
    "credentials",
    "credentials.json",
    "id_dsa",
    "id_ed25519",
    "id_rsa",
    "kubeconfig",
}

SENSITIVE_SUFFIXES = {
    ".jks",
    ".key",
    ".keystore",
    ".p12",
    ".pem",
    ".pfx",
    ".tfstate",
}
