from fastapi import FastAPI, Response, status
from datetime import datetime
import os
import time
from contextlib import asynccontextmanager
from prometheus_fastapi_instrumentator import Instrumentator
from fastapi import HTTPException, Query

startup_time = datetime.now()
ready = False

@asynccontextmanager
async def lifespan(app: FastAPI):
    global ready
    ready = True
    yield
    ready = False   

app = FastAPI(lifespan=lifespan)
Instrumentator().instrument(app).expose(app)

@app.get("/health", status_code=200)
def health_check():
    return {"status": "healthy"}

@app.get("/ready")
def readiness_check(response: Response):
    if not ready:
        # Return 503 to tell Kubernetes not to send traffic yet
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {
            "status": "not_ready",
            "reason": "Service is starting up"
        }

    # Application is ready to receive traffic
    return {
        "status": "ready",
        "uptime_seconds": (datetime.now() - startup_time).total_seconds(),
    }

@app.get("/version")
def version():
    return {
        "version":    os.getenv("APP_VERSION", "dev"),
        "git_sha":    os.getenv("GIT_SHA", "unknown"),
        "build_time": os.getenv("BUILD_TIME", "unknown"),
    }
    
@app.get("/simulate-error")
def simulate_error(kind: str = Query("500", pattern="^(500|crash|hang|oom)$")):
    if kind == "500":
        raise HTTPException(status_code=500, detail="simulated 500")
    if kind == "crash":
        os._exit(1)                  
    if kind == "hang":
        time.sleep(120)              
    if kind == "oom":
        _ = bytearray(10 * 1024**3) 