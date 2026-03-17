# KSeF XML Download - Docker image
# Author: IT TASK FORCE Piotr Mierzenski
#
# Stage 1: build virtualenv with all dependencies compiled
FROM python:3.13-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libxml2-dev \
    libxslt1-dev \
    libjpeg62-turbo-dev \
    zlib1g-dev \
    libfreetype6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /venv

RUN /venv/bin/pip install --no-cache-dir \
    "cryptography>=46.0.5" \
    "defusedxml>=0.7.1" \
    "lxml>=6.0.2" \
    "pillow>=12.1.1" \
    "qrcode>=7.4" \
    "reportlab>=4.0" \
    "requests>=2.32.5"


# Stage 2: minimal runtime image
FROM python:3.13-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    libxml2 \
    libxslt1.1 \
    libjpeg62-turbo \
    zlib1g \
    libfreetype6 \
    cron \
    tini \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled virtualenv from builder stage
COPY --from=builder /venv /venv

# Create non-root user for running python scripts
RUN groupadd -g 1000 ksef && useradd -u 1000 -g 1000 -s /bin/bash -d /home/ksef -m ksef

WORKDIR /app

COPY ksef_client.py ksef_pdf.py ./
COPY fonts/ ./fonts/
COPY test_faktura.xml ./
COPY docker/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

# Virtualenv bin takes precedence
ENV PATH="/venv/bin:$PATH"

# /data is the mount point for invoice output and NIP config
RUN mkdir -p /data && chown ksef:ksef /data
VOLUME /data

# cron requires root; entrypoint handles privilege separation
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
