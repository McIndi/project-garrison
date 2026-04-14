FROM python:3.14-slim

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
	&& useradd --create-home --uid 10001 appuser
COPY app ./app
RUN chown -R appuser:appuser /app

EXPOSE 8090
USER appuser
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8090"]
