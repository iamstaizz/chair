"""
Database-level guarantees: no double booking, waiting segments, tenant isolation.

These tests talk to a real Postgres as the *application* role (chair_app),
the same way the API will, so RLS is actually exercised.
"""
from __future__ import annotations

import asyncio
import os
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import asyncpg
import pytest
import pytest_asyncio
from asyncpg import Range

ADMIN_DSN = os.getenv("ADMIN_DSN", "postgresql://chair:chair@localhost:5432/chair")
APP_DSN = os.getenv("APP_DSN", "postgresql://chair_app:chair_app@localhost:5432/chair")

T0 = datetime(2030, 1, 7, 10, 0, tzinfo=timezone.utc)


def span(start_min: int, end_min: int) -> Range:
    """Half-open [start, end) range, minutes after 10:00."""
    return Range(T0 + timedelta(minutes=start_min), T0 + timedelta(minutes=end_min))


# --------------------------------------------------------------------------- fixtures
async def _make_tenant(admin: asyncpg.Connection, label: str) -> SimpleNamespace:
    tid = await admin.fetchval(
        "INSERT INTO tenants (slug, name) VALUES ($1, $2) RETURNING id",
        f"{label}-{uuid.uuid4().hex[:8]}", label,
    )
    masters = [
        await admin.fetchval(
            "INSERT INTO masters (tenant_id, name) VALUES ($1, $2) RETURNING id", tid, name
        )
        for name in ("Olha", "Iryna")
    ]
    rtype = await admin.fetchval(
        "INSERT INTO resource_types (tenant_id, name) VALUES ($1, 'chair') RETURNING id", tid
    )
    chair = await admin.fetchval(
        "INSERT INTO resources (tenant_id, type_id, name) VALUES ($1, $2, 'Chair 1') RETURNING id",
        tid, rtype,
    )
    service = await admin.fetchval(
        "INSERT INTO services (tenant_id, name) VALUES ($1, 'Hair colouring') RETURNING id", tid
    )
    client = await admin.fetchval(
        "INSERT INTO clients (tenant_id, name, phone) VALUES ($1, 'Client', $2) RETURNING id",
        tid, f"+380{uuid.uuid4().int % 10**9:09d}",
    )
    return SimpleNamespace(
        id=tid, m1=masters[0], m2=masters[1], chair=chair, service=service, client=client
    )


@pytest_asyncio.fixture
async def world():
    admin = await asyncpg.connect(ADMIN_DSN)
    a = await _make_tenant(admin, "salon-a")
    b = await _make_tenant(admin, "salon-b")
    yield SimpleNamespace(a=a, b=b)
    await admin.execute("DELETE FROM tenants WHERE id = ANY($1::uuid[])", [a.id, b.id])
    await admin.close()


@pytest_asyncio.fixture
async def pool():
    p = await asyncpg.create_pool(APP_DSN, min_size=10, max_size=10)
    yield p
    await p.close()


async def book(pool, tenant, segments, client=None) -> uuid.UUID:
    """One transaction: create a held booking + its segments in tenant context.

    segments: [(master_id, resource_id | None, 'active' | 'waiting', Range)]
    """
    async with pool.acquire() as conn, conn.transaction():
        await conn.execute("SELECT set_config('app.tenant_id', $1, true)", str(tenant.id))
        booking_id = await conn.fetchval(
            """INSERT INTO bookings (client_id, hold_expires_at, total_minor)
               VALUES ($1, now() + interval '10 minutes', 0) RETURNING id""",
            client or tenant.client,
        )
        for master, resource, kind, during in segments:
            await conn.execute(
                """INSERT INTO booking_segments
                       (booking_id, service_id, master_id, resource_id, kind, during)
                   VALUES ($1, $2, $3, $4, $5, $6)""",
                booking_id, tenant.service, master, resource, kind, during,
            )
        return booking_id


async def in_tenant(pool, tenant_id, sql, *args):
    async with pool.acquire() as conn, conn.transaction():
        if tenant_id is not None:
            await conn.execute("SELECT set_config('app.tenant_id', $1, true)", str(tenant_id))
        return await conn.fetch(sql, *args)


# --------------------------------------------------------------------------- slots
async def test_concurrent_requests_for_same_slot_only_one_wins(pool, world):
    t = world.a
    attempts = [
        book(pool, t, [(t.m1, None, "active", span(0, 60))]) for _ in range(10)
    ]
    results = await asyncio.gather(*attempts, return_exceptions=True)

    winners = [r for r in results if isinstance(r, uuid.UUID)]
    losers = [r for r in results if isinstance(r, asyncpg.ExclusionViolationError)]
    assert len(winners) == 1
    assert len(losers) == 9
    assert all(e.constraint_name == "no_master_overlap" for e in losers)


async def test_back_to_back_appointments_do_not_conflict(pool, world):
    t = world.a
    await book(pool, t, [(t.m1, None, "active", span(0, 60))])
    await book(pool, t, [(t.m1, None, "active", span(60, 120))])  # starts exactly when the first ends


async def test_partial_overlap_is_rejected(pool, world):
    t = world.a
    await book(pool, t, [(t.m1, None, "active", span(0, 60))])
    with pytest.raises(asyncpg.ExclusionViolationError):
        await book(pool, t, [(t.m1, None, "active", span(30, 90))])


async def test_different_masters_can_work_in_parallel(pool, world):
    t = world.a
    await book(pool, t, [(t.m1, None, "active", span(0, 60))])
    await book(pool, t, [(t.m2, None, "active", span(0, 60))])


# --------------------------------------------------------------------------- waiting
async def test_master_is_free_while_dye_develops(pool, world):
    """apply (30) -> develop (40, master free) -> rinse + style (30)."""
    t = world.a
    colouring = [
        (t.m1, None, "active", span(0, 30)),
        (t.m1, None, "waiting", span(30, 70)),
        (t.m1, None, "active", span(70, 100)),
    ]
    await book(pool, t, colouring)

    # A 30-min haircut fits into the waiting window of the same master
    await book(pool, t, [(t.m1, None, "active", span(30, 60))])

    # ...but not on top of the active segments
    with pytest.raises(asyncpg.ExclusionViolationError):
        await book(pool, t, [(t.m1, None, "active", span(10, 40))])


async def test_chair_stays_busy_during_waiting_segment(pool, world):
    t = world.a
    await book(pool, t, [
        (t.m1, t.chair, "active", span(0, 30)),
        (t.m1, t.chair, "waiting", span(30, 70)),
    ])
    # Another master is free, but the client is still sitting in the chair
    with pytest.raises(asyncpg.ExclusionViolationError) as exc:
        await book(pool, t, [(t.m2, t.chair, "active", span(40, 70))])
    assert exc.value.constraint_name == "no_resource_overlap"


# --------------------------------------------------------------------------- lifecycle
async def test_cancelled_booking_frees_the_slot(pool, world):
    t = world.a
    booking_id = await book(pool, t, [(t.m1, None, "active", span(0, 60))])

    await in_tenant(pool, t.id, "UPDATE bookings SET status = 'cancelled' WHERE id = $1", booking_id)

    await book(pool, t, [(t.m1, None, "active", span(0, 60))])  # trigger released the slot


async def test_expired_holds_are_released(pool, world):
    t = world.a
    booking_id = await book(pool, t, [(t.m1, None, "active", span(0, 60))])
    await in_tenant(
        pool, t.id,
        "UPDATE bookings SET hold_expires_at = now() - interval '1 second' WHERE id = $1",
        booking_id,
    )
    released = await in_tenant(pool, t.id, "SELECT release_expired_holds() AS n")
    assert released[0]["n"] == 1

    await book(pool, t, [(t.m1, None, "active", span(0, 60))])


# --------------------------------------------------------------------------- tenancy
async def test_tenant_cannot_read_another_tenants_data(pool, world):
    await book(pool, world.a, [(world.a.m1, None, "active", span(0, 60))])

    as_a = await in_tenant(pool, world.a.id, "SELECT count(*) AS n FROM bookings")
    as_b = await in_tenant(pool, world.b.id, "SELECT count(*) AS n FROM bookings")
    no_ctx = await in_tenant(pool, None, "SELECT count(*) AS n FROM bookings")

    assert as_a[0]["n"] == 1
    assert as_b[0]["n"] == 0
    assert no_ctx[0]["n"] == 0  # forgetting to set the tenant fails closed


async def test_tenant_cannot_write_into_another_tenant(pool, world):
    with pytest.raises(asyncpg.InsufficientPrivilegeError):
        await in_tenant(
            pool, world.b.id,
            "INSERT INTO masters (tenant_id, name) VALUES ($1, 'Intruder')", world.a.id,
        )


async def test_cross_tenant_references_are_impossible(pool, world):
    """Tenant B tries to attach its booking to tenant A's client."""
    with pytest.raises(asyncpg.ForeignKeyViolationError):
        await in_tenant(
            pool, world.b.id,
            "INSERT INTO bookings (client_id, hold_expires_at, total_minor) "
            "VALUES ($1, now() + interval '10 minutes', 0)",
            world.a.client,
        )