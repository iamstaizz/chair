CREATE TABLE clients (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    name        text NOT NULL,
    phone       text,
    telegram_id bigint,
    notes       text,                  -- "алергія на аміак", формула кольору...
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, phone),
    UNIQUE (tenant_id, telegram_id)
);

CREATE TABLE bookings (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    client_id       uuid NOT NULL,
    status          booking_status NOT NULL DEFAULT 'held',
    hold_expires_at timestamptz,       -- до якого моменту слот утримується під оплату
    total_minor     integer NOT NULL CHECK (total_minor >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CHECK (status <> 'held' OR hold_expires_at IS NOT NULL),
    FOREIGN KEY (tenant_id, client_id) REFERENCES clients (tenant_id, id)
);

-- Журнал зайнятості: "цей майстер / це крісло зайняті у цей проміжок".
CREATE TABLE booking_segments (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL DEFAULT current_tenant_id() REFERENCES tenants ON DELETE CASCADE,
    booking_id  uuid NOT NULL,
    service_id  uuid NOT NULL,
    master_id   uuid NOT NULL,
    resource_id uuid,
    kind        segment_kind NOT NULL,
    during      tstzrange NOT NULL,
    occupies    boolean NOT NULL DEFAULT true,   -- false, коли бронювання скасовано

    -- Проміжок напіввідкритий [початок, кінець): запис "10:00-11:00"
    -- і наступний "11:00-12:00" не конфліктують.
    CHECK (NOT isempty(during) AND lower_inc(during) AND NOT upper_inc(during)
           AND NOT lower_inf(during) AND NOT upper_inf(during)),

    FOREIGN KEY (tenant_id, booking_id)  REFERENCES bookings  (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, service_id)  REFERENCES services  (tenant_id, id),
    FOREIGN KEY (tenant_id, master_id)   REFERENCES masters   (tenant_id, id),
    FOREIGN KEY (tenant_id, resource_id) REFERENCES resources (tenant_id, id),

    -- Майстер не може робити дві активні речі одночасно.
    -- Сегменти 'waiting' не враховуються: поки фарба діє, він вільний.
    CONSTRAINT no_master_overlap EXCLUDE USING gist
        (master_id WITH =, during WITH &&) WHERE (occupies AND kind = 'active'),

    -- Крісло не може приймати двох клієнток одразу, включно з часом очікування.
    CONSTRAINT no_resource_overlap EXCLUDE USING gist
        (resource_id WITH =, during WITH &&) WHERE (occupies AND resource_id IS NOT NULL)
);

CREATE INDEX ON booking_segments (tenant_id, booking_id);
CREATE INDEX ON booking_segments USING gist (tenant_id, during);

-- Коли бронювання скасовано, його сегменти автоматично звільняють слот.
CREATE FUNCTION sync_segment_occupancy() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE booking_segments
       SET occupies = NEW.status IN ('held', 'confirmed', 'completed')
     WHERE booking_id = NEW.id AND tenant_id = NEW.tenant_id;
    RETURN NULL;
END $$;

CREATE TRIGGER bookings_sync_occupancy
AFTER UPDATE OF status ON bookings
FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION sync_segment_occupancy();

-- Скасовує неоплачені утримання, у яких вийшов час (викликатиме фоновий воркер).
CREATE FUNCTION release_expired_holds() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
    UPDATE bookings SET status = 'cancelled'
     WHERE status = 'held' AND hold_expires_at < now();
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

SELECT enable_tenant_rls('clients');
SELECT enable_tenant_rls('bookings');
SELECT enable_tenant_rls('booking_segments');