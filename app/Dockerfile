# syntax=docker/dockerfile:1.7
# Multi-stage build: dependencies are installed in a throwaway stage, so pip,
# build caches and compilers never reach the runtime image.

ARG PYTHON_IMAGE=public.ecr.aws/docker/library/python:3.13-slim

FROM ${PYTHON_IMAGE} AS deps
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY requirements.txt /tmp/requirements.txt
RUN pip install --prefix=/install -r /tmp/requirements.txt

FROM ${PYTHON_IMAGE}
ARG APP_VERSION=dev
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION}

WORKDIR /app
COPY --from=deps /install /usr/local

# The runtime never installs packages: drop pip (and the ensurepip copy of it).
# pip vendors its own urllib3/msgpack/setuptools, which scanners rightly flag.
RUN python -m pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3.13/ensurepip

# RDS CA bundle, so the app can verify the database certificate (sslmode=verify-full).
ADD --chmod=644 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/rds-ca.pem

COPY main.py /app/main.py

# Never run as root. A numeric UID lets the platform verify it (runAsNonRoot).
USER 10001:10001

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--forwarded-allow-ips", "*"]
