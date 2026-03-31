FROM debian:bookworm-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3.11 \
    python3.11-dev \
    python3-pip \
    python3.11-venv \
    git \
    curl \
    ffmpeg \
    build-essential \
    libssl-dev \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# Make python3.11 the default
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1

# Install pip via get-pip
RUN curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11

# Clone hermes-agent
WORKDIR /opt/hermes
RUN git clone https://github.com/NousResearch/hermes-agent.git .

# Install Python dependencies
RUN pip install --no-cache-dir -e ".[all]" || pip install --no-cache-dir -e .

# Copy our entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Copy config template
COPY config.yaml.template /opt/config.yaml.template

ENV HERMES_HOME=/opt/data

ENTRYPOINT ["/entrypoint.sh"]
