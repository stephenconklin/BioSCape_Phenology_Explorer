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

# --threads 8 (was 2): the concurrency budget is workers x threads, and at 2x2
# only four in-flight requests could starve the whole app — including the
# constant public-internet scanner traffic on port 80, which holds a slot per
# connection.  These threads are almost always blocked on I/O (netCDF/HDF5
# reads serialize on a global lock anyway), so extra threads cost memory for
# stacks, not CPU, and 2 cores stay adequate.
CMD ["gunicorn", "app:server", \
     "--bind", "0.0.0.0:8050", \
     "--workers", "2", \
     "--worker-class", "gthread", \
     "--threads", "8", \
     "--timeout", "120", \
     "--preload", \
     "--max-requests", "300", \
     "--max-requests-jitter", "30"]
