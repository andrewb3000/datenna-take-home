FROM python:3.12-slim

RUN useradd --create-home --uid 10001 appuser
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

USER appuser
EXPOSE 8000

# /vault/secrets/env is rendered by the Vault Agent init container into a shared
# emptyDir before this container starts; python:3.12-slim is Debian-based so /bin/sh
# is always present.
CMD ["sh", "-c", "set -a && . /vault/secrets/env && set +a && exec python -m uvicorn app.main:app --host 0.0.0.0 --port 8000"]
