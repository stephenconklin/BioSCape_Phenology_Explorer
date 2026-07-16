FROM python:3.11-slim

# Headless matplotlib backend — MplFigure/colorbar rendering never opens a
# GUI toolkit, but this removes any chance of a backend-selection failure.
ENV MPLBACKEND=Agg \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install dependencies first so this layer is cached across code-only rebuilds.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8050

CMD ["gunicorn", "app:server", \
     "--bind", "0.0.0.0:8050", \
     "--workers", "2", \
     "--threads", "2", \
     "--timeout", "120", \
     "--preload"]
