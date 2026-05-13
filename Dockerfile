FROM python:3.10-slim

# Geospatial system libs
RUN apt-get update && apt-get install -y --no-install-recommends \
        awscli curl git \
        gdal-bin libgdal-dev \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Copy the static assets into the image
COPY Jalana_AOI.geojson /workspace/data/
COPY 10_parcels_clean.geojson         /workspace/data/
COPY sowing_dates.json                /workspace/data/

# Python deps
COPY requirements.txt /workspace/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Pipeline assets
COPY Jalna_Pipeline.ipynb   /workspace/Jalna_Pipeline.ipynb
COPY entrypoint.sh          /workspace/entrypoint.sh
# COPY ingest_rasters.py      /workspace/ingest_rasters.py
# COPY db_normalize.py        /workspace/db_normalize.py
COPY cdse_auth.py           /workspace/cdse_auth.py
RUN chmod +x /workspace/entrypoint.sh

# SageMaker Processing invokes ContainerEntrypoint from AppSpecification
CMD ["/bin/bash", "/workspace/entrypoint.sh"]