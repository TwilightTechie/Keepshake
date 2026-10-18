import io
import wave
from email.parser import BytesParser
from email.policy import default

import httpx
import pytest

from app.config import Settings
from app.providers import stt


@pytest.mark.parametrize("rate", [8000, 16000])
async def test_sarvam_preserves_wav_and_uses_v4(monkeypatch, rate):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(b"\x01\x02" * 100)
    audio = buf.getvalue()
    settings = Settings(_env_file=None, sarvam_api_key="test-key")
    monkeypatch.setattr(stt, "get_settings", lambda: settings)

    def handle(request):
        assert request.headers["Api-Subscription-Key"] == "test-key"
        message = BytesParser(policy=default).parsebytes(
            f'Content-Type: {request.headers["content-type"]}\r\n\r\n'.encode()
            + request.content
        )
        fields = {
            part.get_param("name", header="content-disposition"): part.get_payload(decode=True)
            for part in message.iter_parts()
        }
        assert fields["model"] == b"saaras:v4"
        assert fields["mode"] == b"transcribe"
        assert fields["language_code"] == b"unknown"
        assert fields["file"] == audio  # includes unchanged sample rate and sample bytes
        return httpx.Response(200, json={"transcript": "Hello from the pendant."})

    client_class = httpx.AsyncClient
    monkeypatch.setattr(
        stt.httpx, "AsyncClient",
        lambda **kwargs: client_class(transport=httpx.MockTransport(handle), **kwargs),
    )
    turns = await stt.SarvamStt().transcribe(audio, "wav")
    assert [t.text for t in turns] == ["Hello from the pendant."]
