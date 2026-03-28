FROM python:3.12-slim
RUN pip install --no-cache-dir kafka-python-ng==2.2.3 \
 && groupadd -r app && useradd -r -g app app \
 && mkdir -p /app/data && chown app:app /app/data
USER app
