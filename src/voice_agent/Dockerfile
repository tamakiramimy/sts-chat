FROM mcr.microsoft.com/devcontainers/python:1-3.11-bookworm
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ARG PIP_INDEX_URL=https://pypi.org/simple
ENV PIP_INDEX_URL=${PIP_INDEX_URL}
COPY requirements.txt ./
RUN pip install --no-cache-dir --retries 2 --timeout 30 -r requirements.txt
COPY . ./
CMD ["python", "agent.py", "start"]
