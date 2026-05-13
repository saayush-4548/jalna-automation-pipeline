import os
import time
import requests
import openeo

OPENEO_BACKEND = "https://openeo.dataspace.copernicus.eu"
CDSE_TOKEN_URL = "https://identity.dataspace.copernicus.eu/auth/realms/CDSE/protocol/openid-connect/token"

def fetch_token() -> str:
    username = os.environ.get("COPERNICUS_USERNAME")
    password = os.environ.get("COPERNICUS_PASSWORD")
    client_id = os.environ.get("COPERNICUS_CLIENT_ID", "cdse-public")
    if not username or not password:
        raise EnvironmentError("❌ COPERNICUS_USERNAME and COPERNICUS_PASSWORD must be set")
    
    for attempt in range(1, 4):
        try:
            resp = requests.post(CDSE_TOKEN_URL, data={
                "grant_type": "password", "username": username,
                "password": password, "client_id": client_id, "scope": "openid email",
            }, timeout=(5, 30))
            resp.raise_for_status()
            return resp.json()["access_token"]
        except Exception as e:
            if attempt == 3: raise e
            time.sleep(2)

def get_openeo_connection(force_refresh: bool = False):
    access_token = fetch_token()
    conn = openeo.connect(OPENEO_BACKEND)
    conn.authenticate_oidc_access_token(access_token)
    return conn