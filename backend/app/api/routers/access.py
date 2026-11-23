import hmac
import time

from fastapi import APIRouter, HTTPException, Request, Response

from ..app_state import app
from ...core import accounts
from ...core import security as auth
from ...core import settings as config
from ...schemas.models import (
    AccessStatusResponse,
    LoginRequest,
    RegisterRequest,
)


router = APIRouter()


def _status(request: Request) -> AccessStatusResponse:
    registered = accounts.is_registered()
    expires_at = auth.verify_access_token(
        request.cookies.get(config.ACCESS_KEY_COOKIE_NAME)
    )
    return AccessStatusResponse(
        authenticated=bool(expires_at) and registered,
        registered=registered,
        username=accounts.get_username() if registered else "",
        expires_at=expires_at.isoformat() if expires_at else None,
    )


@router.get("/api/access/status", response_model=AccessStatusResponse)
async def get_access_status(request: Request):
    return _status(request)


@router.post("/api/access/register", response_model=AccessStatusResponse)
async def register_admin(req: RegisterRequest, request: Request, response: Response):
    if accounts.is_registered():
        raise HTTPException(status_code=409, detail="Admin account already exists")

    username = (req.username or "").strip()
    password = req.password or ""
    if not username or not password:
        raise HTTPException(status_code=400, detail="Username and password are required")
    if len(password) < 6:
        raise HTTPException(status_code=400, detail="Password must be at least 6 characters")

    if not accounts.register(username, password):
        raise HTTPException(status_code=409, detail="Admin account already exists")

    token, expires_at = auth.create_access_token()
    _set_cookie(response, token)
    return AccessStatusResponse(
        authenticated=True,
        registered=True,
        username=username,
        expires_at=expires_at.isoformat(),
    )


@router.post("/api/access/login", response_model=AccessStatusResponse)
async def login(req: LoginRequest, request: Request, response: Response):
    if not accounts.is_registered():
        raise HTTPException(status_code=409, detail="No admin account yet. Please register first.")

    client_ip = auth.get_client_ip(request)
    failures = app.state.access_failures
    now = time.time()
    if client_ip in failures:
        count, first_failure_time = failures[client_ip]
        if now - first_failure_time < config.ACCESS_LOCKOUT_SECONDS:
            if count >= config.ACCESS_MAX_FAILURES:
                remaining = int(config.ACCESS_LOCKOUT_SECONDS - (now - first_failure_time))
                raise HTTPException(
                    status_code=429,
                    detail=f"Too many failed attempts. Try again in {remaining} seconds.",
                )
        else:
            del failures[client_ip]

    if not accounts.verify(req.username, req.password):
        if client_ip not in failures:
            failures[client_ip] = (1, now)
        else:
            failures[client_ip] = (failures[client_ip][0] + 1, now)
        raise HTTPException(status_code=401, detail="Invalid username or password")

    if client_ip in failures:
        del failures[client_ip]

    token, expires_at = auth.create_access_token()
    _set_cookie(response, token)
    return AccessStatusResponse(
        authenticated=True,
        registered=True,
        username=accounts.get_username(),
        expires_at=expires_at.isoformat(),
    )


@router.post("/api/access/logout", response_model=AccessStatusResponse)
async def logout(response: Response):
    response.delete_cookie(key=config.ACCESS_KEY_COOKIE_NAME)
    return _status_from_blank()


def _status_from_blank() -> AccessStatusResponse:
    registered = accounts.is_registered()
    return AccessStatusResponse(
        authenticated=False,
        registered=registered,
        username=accounts.get_username() if registered else "",
        expires_at=None,
    )


def _set_cookie(response: Response, token: str) -> None:
    max_age = auth.session_days() * 24 * 60 * 60
    response.set_cookie(
        key=config.ACCESS_KEY_COOKIE_NAME,
        value=token,
        max_age=max_age,
        expires=max_age,
        httponly=True,
        samesite="lax",
        secure=config.ACCESS_COOKIE_SECURE,
    )
