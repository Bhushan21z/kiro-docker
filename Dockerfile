FROM ubuntu:24.04

LABEL org.opencontainers.image.title="kiro-docker" \
      org.opencontainers.image.description="Run Kiro CLI headless and autonomously inside an isolated Docker container" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root
ENV PATH="/root/.local/bin:${PATH}"
# Make non-interactive installs predictable for anything Kiro runs at runtime.
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV NEEDRESTART_MODE=a

# Base toolchain. This is a convenience baseline: Kiro can install anything
# else it needs at runtime via apt/pip/npm because the container runs as root
# with network access.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash ca-certificates curl wget git unzip zip tar gzip xz-utils \
        sudo build-essential pkg-config \
        python3 python3-pip python3-venv pipx \
        sqlite3 jq ripgrep && \
    rm -rf /var/lib/apt/lists/*

# Handy Python libs for scripting and validating JSON/YAML output.
RUN pip3 install --no-cache-dir jsonschema pyyaml

# Node.js LTS (includes npm) - the most common runtime, preinstalled for speed.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install Kiro CLI at build time. The API key is supplied at run time,
# never baked into the image. Installed globally (/usr/local/bin) rather than
# under /root so the non-root evaluator user can run it too; on PATH either
# way, so the default prompt mode is unaffected. Pin with
# --build-arg KIRO_CLI_VERSION=x.y.z for reproducible evaluator images.
ARG KIRO_CLI_VERSION=""
RUN curl -fsSL https://cli.kiro.dev/install -o /tmp/kiro-install.sh && \
    Q_INSTALL_GLOBAL=1 bash /tmp/kiro-install.sh --force ${KIRO_CLI_VERSION:+--version "$KIRO_CLI_VERSION"} && \
    rm -f /tmp/kiro-install.sh && \
    kiro-cli --version

# Evaluator mode (KIRO_MODE=evaluate, see eval/evaluate.sh). Runs as uid 1000
# so chmod on the evidence it reads is actually enforced. Ubuntu's stock
# `ubuntu` user holds uid 1000, so it is replaced rather than shadowed.
RUN userdel -r ubuntu 2>/dev/null || true; \
    useradd --uid 1000 --create-home --shell /bin/bash evaluator
COPY eval/ /opt/kiro-eval/
RUN chmod 0755 /opt/kiro-eval/evaluate.sh /opt/kiro-eval/*.py && \
    (cd /opt/kiro-eval/schema && sha256sum -c result.schema.v1.json.sha256)

# Entry wrapper: refreshes apt metadata once so runtime `apt-get install`
# works, then hands the prompt to Kiro in headless, trust-all-tools mode.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
