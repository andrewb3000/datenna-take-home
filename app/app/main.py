from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from . import db, storage


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.wait_for_db()
    storage.wait_for_bucket()
    yield


app = FastAPI(lifespan=lifespan)


class ItemIn(BaseModel):
    value: str


@app.post("/items")
def create_item(item: ItemIn):
    item_id = db.insert_item(item.value)
    try:
        storage.put_object(item_id, {"id": item_id, "value": item.value})
    except Exception:
        db.delete_item(item_id)
        raise HTTPException(
            status_code=500, detail="storage write failed, database write rolled back"
        )
    return {"id": item_id, "db": "ok", "storage": "ok"}


@app.get("/items/{item_id}")
def get_item(item_id: int):
    row = db.get_item(item_id)
    if row is None:
        raise HTTPException(status_code=404, detail="not found")
    obj = storage.get_object(item_id)
    return {"db": row, "storage": obj}


@app.get("/healthz")
def healthz():
    ok_db = db.ping()
    ok_storage = storage.ping()
    if not (ok_db and ok_storage):
        raise HTTPException(status_code=500, detail={"db": ok_db, "storage": ok_storage})
    return {"db": ok_db, "storage": ok_storage}
