import os
from flask import Flask, jsonify

app = Flask(__name__)


@app.route("/")
def index():
    return jsonify(
        message="Hello from AKS v2",
        version=os.getenv("APP_VERSION", "dev"),
        pod=os.getenv("HOSTNAME", "unknown"),
    )


@app.route("/healthz")
def healthz():
    return "ok", 200