#!/usr/bin/env python3
"""
VLLM Semantic Router Decision Service
Serves Anup's fine-tuned Vela Decision/Commitment Classifier (TwilightTechie/vela-commitment-classifier-307m)
locally on Mac Mini for the Keepsake / Dream AI pendant.
"""

import os
import sys
import time
from typing import List, Dict, Any, Optional
from pydantic import BaseModel
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import torch
from transformers import AutoConfig, AutoModelForSequenceClassification, AutoTokenizer, logging

# Suppress noisy transformers warnings
logging.set_verbosity_error()

MODEL_NAME = os.environ.get("VELA_MODEL_NAME", "TwilightTechie/vela-commitment-classifier-307m")
MODEL_REVISION = os.environ.get("VELA_MODEL_REVISION", "f0e7192426d053573d09143ad1cc08e557eb15de")
MAX_TOKENS = 256
PORT = int(os.environ.get("PORT", "11435"))
HOST = os.environ.get("HOST", "127.0.0.1")

app = FastAPI(title="vLLM-SR Decision Classifier Service", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class ClassifyRequest(BaseModel):
    texts: List[str]
    threshold: Optional[float] = 0.5


class RoutePreviewRequest(BaseModel):
    prompt: Optional[str] = None
    messages: Optional[List[Dict[str, str]]] = None


class DecisionClassifierEngine:
    def __init__(self, model_name: str = MODEL_NAME, revision: str = MODEL_REVISION):
        print(f"[vLLM-SR] Loading decision model: {model_name} (rev: {revision[:8]})...")
        t0 = time.time()
        
        # Determine device: Apple Silicon MPS if available, else CPU
        if torch.backends.mps.is_available():
            self.device = torch.device("mps")
        else:
            self.device = torch.device("cpu")
            torch.set_num_threads(min(8, os.cpu_count() or 4))
            
        self.config = AutoConfig.from_pretrained(model_name, revision=revision)
        if hasattr(self.config, "reference_compile"):
            self.config.reference_compile = False
            
        self.tokenizer = AutoTokenizer.from_pretrained(model_name, revision=revision)
        self.model = AutoModelForSequenceClassification.from_pretrained(
            model_name,
            revision=revision,
            config=self.config,
            dtype=torch.float32,
        ).to(self.device).eval()
        
        self.labels = self.model.config.id2label
        print(f"[vLLM-SR] Model loaded on {self.device} in {round(time.time() - t0, 2)}s.")

    def classify_single(self, text: str) -> Dict[str, Any]:
        text = text.strip()
        if not text:
            return {
                "text": text,
                "label": "NO_DECISION_EXPRESSED",
                "decision_expressed": False,
                "score": 0.0,
                "scores": {}
            }
        
        inputs = self.tokenizer(
            text,
            return_tensors="pt",
            truncation=True,
            max_length=MAX_TOKENS
        ).to(self.device)
        
        with torch.inference_mode():
            logits = self.model(**inputs).logits
            scores = logits.softmax(dim=-1)[0].tolist()
            
        scores_by_label = {self.labels[i]: score for i, score in enumerate(scores)}
        dec_score = scores_by_label.get("DECISION_EXPRESSED", 0.0)
        no_dec_score = scores_by_label.get("NO_DECISION_EXPRESSED", 0.0)
        is_decision = dec_score > no_dec_score
        
        return {
            "text": text,
            "label": "DECISION_EXPRESSED" if is_decision else "NO_DECISION_EXPRESSED",
            "decision_expressed": is_decision,
            "confidence": round(dec_score if is_decision else no_dec_score, 5),
            "decision_score": round(dec_score, 5),
            "scores": {k: round(v, 5) for k, v in scores_by_label.items()}
        }

    def classify_batch(self, texts: List[str]) -> List[Dict[str, Any]]:
        return [self.classify_single(t) for t in texts]


engine: Optional[DecisionClassifierEngine] = None


@app.on_event("startup")
def startup_event():
    global engine
    engine = DecisionClassifierEngine()


@app.get("/health")
def health():
    return {
        "status": "healthy",
        "service": "vllm-sr-decision-classifier",
        "model": MODEL_NAME,
        "revision": MODEL_REVISION,
        "device": str(engine.device) if engine else "not_loaded",
        "host": "Mac Mini (M4)"
    }


@app.post("/classify")
def classify(req: ClassifyRequest):
    if not engine:
        raise HTTPException(status_code=503, detail="Model engine not initialized")
    results = engine.classify_batch(req.texts)
    decisions = [r for r in results if r["decision_expressed"]]
    return {
        "total_inputs": len(req.texts),
        "decisions_count": len(decisions),
        "results": results
    }


@app.post("/route/preview")
def route_preview(req: RoutePreviewRequest):
    """Semantic Router compatible preview endpoint."""
    if not engine:
        raise HTTPException(status_code=503, detail="Model engine not initialized")
    
    text_to_eval = req.prompt or ""
    if not text_to_eval and req.messages:
        # Concatenate user messages or evaluate last user message
        user_msgs = [m.get("content", "") for m in req.messages if m.get("role") == "user"]
        text_to_eval = " ".join(user_msgs)
        
    res = engine.classify_single(text_to_eval)
    return {
        "model": MODEL_NAME,
        "selected_route": "decision" if res["decision_expressed"] else "general",
        "signals": {
            "decision_expressed": res["decision_expressed"],
            "decision_score": res["decision_score"]
        },
        "details": res
    }


if __name__ == "__main__":
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
