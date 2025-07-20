FROM python:3.12-alpine
WORKDIR /app
COPY src/ /app
RUN pip install --no-cache-dir flask==3.0.3
EXPOSE 5000
CMD ["python", "/app/app.py"]
